#!/usr/bin/env python3

import argparse
import json
import os
import sys

import huggingface_hub
from pyannote.audio import Pipeline
import torch


def main():
    parser = argparse.ArgumentParser(description="Run pyannote speaker diarization.")
    parser.add_argument("audio_path", help="Path to the input 16kHz WAV file.")
    parser.add_argument("output_path", help="Path to write the output JSON.")
    args = parser.parse_args()

    # We expect HF_TOKEN to be set in the environment.
    hf_token = os.environ.get("HF_TOKEN")
    if not hf_token:
        print("Error: HF_TOKEN environment variable is not set.", file=sys.stderr)
        sys.exit(1)
    try:
        # huggingface_hub >= 0.27.0 removed use_auth_token. Pyannote still passes it.
        # We monkey-patch it to avoid the crash.
        _orig_hf_hub_download = huggingface_hub.hf_hub_download
        def _patched_hf_hub_download(*args, **kwargs):
            if 'use_auth_token' in kwargs:
                token = kwargs.pop('use_auth_token')
                if token is not False and token is not None:
                    kwargs['token'] = token
            return _orig_hf_hub_download(*args, **kwargs)
        huggingface_hub.hf_hub_download = _patched_hf_hub_download

        # PyTorch 2.6+ defaults to weights_only=True which can break pyannote loading
        if hasattr(torch.serialization, 'add_safe_globals'):
            safe_globals = []
            if hasattr(torch, 'torch_version'):
                safe_globals.append(torch.torch_version.TorchVersion)
            
            try:
                from pyannote.audio.core.task import Specifications, Problem, Resolution
                safe_globals.extend([Specifications, Problem, Resolution])
            except ImportError:
                pass

            try:
                from pyannote.core import Annotation, Segment, Timeline
                safe_globals.extend([Annotation, Segment, Timeline])
            except ImportError:
                pass

            try:
                import numpy
                # Common numpy types found in torch checkpoints
                multiarray = getattr(numpy, '_core', getattr(numpy, 'core', None)).multiarray
                safe_globals.extend([
                    numpy.dtype,
                    multiarray._reconstruct,
                    numpy.ndarray
                ])
            except (ImportError, AttributeError):
                pass
                
            if safe_globals:
                torch.serialization.add_safe_globals(safe_globals)
            
    except ImportError:
        print("Error: pyannote.audio or torch or huggingface_hub is not installed.", file=sys.stderr)
        sys.exit(1)

    print(f"Loading pyannote pipeline...", file=sys.stderr)
    try:
        pipeline = Pipeline.from_pretrained("pyannote/speaker-diarization-3.1", use_auth_token=hf_token)
        
        # Use MPS or CUDA if available
        if torch.cuda.is_available():
            pipeline.to(torch.device("cuda"))
        elif hasattr(torch.backends, "mps") and torch.backends.mps.is_available():
            pipeline.to(torch.device("mps"))
    except Exception as e:
        print(f"Error initializing pipeline: {e}", file=sys.stderr)
        sys.exit(1)

    print(f"Running diarization on {args.audio_path}...", file=sys.stderr)
    try:
        diarization = pipeline(args.audio_path)
    except Exception as e:
        print(f"Error during diarization: {e}", file=sys.stderr)
        sys.exit(1)

    segments = []
    for turn, _, speaker in diarization.itertracks(yield_label=True):
        segments.append({
            "start": turn.start,
            "end": turn.end,
            "speaker": speaker
        })

    print(f"Writing {len(segments)} segments to {args.output_path}...", file=sys.stderr)
    try:
        with open(args.output_path, 'w') as f:
            json.dump(segments, f, indent=2)
    except Exception as e:
        print(f"Error writing output JSON: {e}", file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    main()
