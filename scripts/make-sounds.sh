#!/usr/bin/env bash
# Convert the demo sounds into formats Asterisk can actually play.
#
# Why: Asterisk's format_wav.so only understands *signed-linear* PCM. A WAV
# that carries mu-law / A-law samples (`ffmpeg -c:a pcm_mulaw`) is found by
# Asterisk but rejected with "Unable to open ... (format (ulaw))", so nothing
# is heard. We therefore emit:
#   - <name>.ulaw : raw 8 kHz mu-law  (native for PCMU channels)
#   - <name>.alaw : raw 8 kHz A-law   (native for PCMA channels)
#   - <name>.wav  : signed-linear PCM (fallback via format_wav)
#
# Sources are the .wav files listed below; the raw files sit next to them.
set -euo pipefail
cd "$(dirname "$0")/.."

SOURCES=(
    sounds/custom/*.wav
    sounds/vm-theperson.wav
)

for src in "${SOURCES[@]}"; do
    [ -f "$src" ] || continue
    base="${src%.wav}"
    tmp=$(mktemp -d)
    ffmpeg -loglevel error -y -i "$src" -ar 8000 -ac 1 -c:a pcm_s16le "$tmp/o.wav"
    ffmpeg -loglevel error -y -i "$src" -ar 8000 -ac 1 -f mulaw       "$tmp/o.ulaw"
    ffmpeg -loglevel error -y -i "$src" -ar 8000 -ac 1 -f alaw        "$tmp/o.alaw"
    cp "$tmp/o.wav"  "${base}.wav"
    cp "$tmp/o.ulaw" "${base}.ulaw"
    cp "$tmp/o.alaw" "${base}.alaw"
    rm -rf "$tmp"
    echo "  ${base}.wav + .ulaw + .alaw"
done

echo "=== Sounds ready ==="
