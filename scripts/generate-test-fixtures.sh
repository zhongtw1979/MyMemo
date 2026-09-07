#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
command -v ffmpeg >/dev/null || { echo "FFmpeg is required to regenerate fixtures." >&2; exit 1; }
output="Tests/MyMemoCoreTests/Fixtures"
mkdir -p "$output"
ffmpeg -hide_banner -loglevel error -f lavfi -i sine=frequency=440:duration=0.3 -c:a aac -y "$output/audio-only.mp4"
ffmpeg -hide_banner -loglevel error -f lavfi -i color=c=black:s=32x32:d=0.3 -f lavfi -i sine=frequency=440:duration=0.3 -c:v libx264 -c:a aac -shortest -y "$output/video-with-audio.mp4"
ffmpeg -hide_banner -loglevel error -f lavfi -i color=c=black:s=32x32:d=0.3 -an -c:v libx264 -y "$output/video-silent.mp4"
