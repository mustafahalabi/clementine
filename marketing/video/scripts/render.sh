#!/bin/bash
# Renders the launch film and masters its audio. Output: out/clementine-launch.mp4
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p out
npx remotion render src/index.ts Launch out/launch-raw.mkv --codec h264-mkv --crf 16 --x264-preset slow --pixel-format yuv420p --log=error
scripts/master.sh out/launch-raw.mkv out/clementine-launch.mp4
