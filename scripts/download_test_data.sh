#!/bin/bash

# This script downloads the test media files required for the VideoToSrt test suite.
# They are not included in the repository to keep the size small.

SAMPLES_DIR="Tests/VideoToSrtTests/samples"

mkdir -p "$SAMPLES_DIR"

# GWB Columbia OGG
GWB_URL="https://upload.wikimedia.org/wikipedia/commons/1/1f/George_W_Bush_Columbia_FINAL.ogg"
GWB_FILE="$SAMPLES_DIR/gwb_columbia.ogg"

# Micro Machines WAV
MM_URL="https://cdn.openai.com/whisper/draft-20220913a/micro-machines.wav"
MM_FILE="$SAMPLES_DIR/micro_machines.wav"

echo "Checking test samples..."

if [ ! -f "$GWB_FILE" ]; then
    echo "Downloading George W. Bush Columbia speech (OGG)..."
    curl -L "$GWB_URL" -o "$GWB_FILE"
else
    echo "gwb_columbia.ogg already exists."
fi

if [ ! -f "$MM_FILE" ]; then
    echo "Downloading Micro Machines commercial (WAV)..."
    curl -L "$MM_URL" -o "$MM_FILE"
else
    echo "micro_machines.wav already exists."
fi

echo "Done! Test data is ready in $SAMPLES_DIR."
