#!/usr/bin/env bash
# Generate one IVR prompt WAV from text, then convert it into the formats
# Asterisk can actually play (scripts/make-sounds.sh does the conversion).
#
# Engine, in order of preference:
#   1. Edge TTS - Microsoft's neural voices. Free, no API key, and it sounds
#      like a person. It is ONLINE: the text is sent to
#      speech.platform.bing.com and the audio comes back. Runs through
#      `edge-tts` if it is installed, otherwise `uvx edge-tts` or
#      `pipx run edge-tts`, which fetch it on the fly.
#   2. espeak-ng - offline, robotic. Used when there is no network / no Edge
#      TTS, or with ENGINE=espeak.
#
# This only ever runs while the prompts are being (re)generated: the resulting
# .wav / .ulaw / .alaw files are committed, so running the demo itself never
# needs the network or any TTS engine.
#
# Usage:
#   ./scripts/tts-greeting.sh "Text to speak"               -> sounds/custom/welcome.wav
#   OUT_NAME=choice-hadji ./scripts/tts-greeting.sh "..."   # name the prompt
#   VOICE=en-US-AriaNeural ./scripts/tts-greeting.sh "..."  # pick an Edge voice
#   RATE=+15% ./scripts/tts-greeting.sh "..."               # Edge speaking rate
#   ENGINE=espeak ./scripts/tts-greeting.sh "..."           # force the offline voice
#
# List the Edge voices with:   uvx edge-tts --list-voices
# Good picks: en-US-AvaNeural (warm), en-US-AriaNeural (newsreader),
# en-US-JennyNeural (friendly), en-US-AndrewNeural (male),
# en-US-BrianNeural (casual), en-GB-SoniaNeural (British).
set -euo pipefail
cd "$(dirname "$0")/.."

VOICE="${VOICE:-en-US-AvaNeural}"
RATE="${RATE:-+8%}"
# OUT_NAME selects the prompt: sounds/custom/<OUT_NAME>.wav
OUT_NAME="${OUT_NAME:-welcome}"
# OUT_PATH overrides the destination - used for Asterisk's own sound names,
# which have to sit at the top of sounds/, not under custom/.
OUT="${OUT_PATH:-sounds/custom/${OUT_NAME}.wav}"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/doorbell-tts"

TEXT="${*:-Welcome to the doorbell. To reach Hadji, press 1. To reach Johnson, press 2. To reach Miora, press 3. To reach Ulrich, press 4.}"

echo "=== Generating ${OUT} ==="
echo "  text: $TEXT"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# --- engine 1: Edge TTS (online, natural) ------------------------------------
# Pick whatever runner can execute edge-tts on this machine.
edge_runner() {
    if command -v edge-tts >/dev/null 2>&1; then printf '%s\n' "edge-tts";    return 0; fi
    if command -v uvx      >/dev/null 2>&1; then printf '%s\n' "uvx edge-tts"; return 0; fi
    if command -v pipx     >/dev/null 2>&1; then printf '%s\n' "pipx run edge-tts"; return 0; fi
    return 1
}

# The service occasionally drops a connection (or throttles a burst); retry a
# couple of times before giving up on the online engine.
synth_edge() {
    local runner="$1" try
    for try in 1 2 3; do
        # shellcheck disable=SC2086  # $runner is intentionally word-split
        if $runner --voice "$VOICE" --rate="$RATE" --text "$TEXT" \
                   --write-media "$TMP/tts.mp3" 2>"$TMP/err"; then
            return 0
        fi
        sleep 2
    done
    return 1
}

if [ "${ENGINE:-auto}" != "espeak" ] && RUNNER=$(edge_runner) && synth_edge "$RUNNER"; then
    echo "  engine: Edge TTS (voice: $VOICE, rate: $RATE)"
    # Edge TTS returns 24 kHz mono MP3; go straight to the 8 kHz signed-linear
    # PCM that make-sounds.sh (and Asterisk's format_wav) expects. ffmpeg's
    # resampler low-passes at the 4 kHz Nyquist, so 24k -> 8k stays clean.
    ffmpeg -loglevel error -y -i "$TMP/tts.mp3" -ar 8000 -ac 1 -c:a pcm_s16le "$OUT"
else
    if [ "${ENGINE:-auto}" != "espeak" ]; then
        echo "  Edge TTS unavailable (no edge-tts/uvx/pipx, or no network:" >&2
        sed 's/^/    /' "$TMP/err" 2>/dev/null >&2 || true
        echo "  ) - falling back to the offline espeak-ng voice." >&2
    fi

    # --- engine 2: espeak-ng (offline) ---------------------------------------
    # espeak-ng needs more than its own .deb: it also links against
    # libespeak-ng1, libpcaudio0 and libsonic0. Fetching only the espeak-ng
    # package leaves the binary unable to start ("error while loading shared
    # libraries"), which is why all four are pulled here.
    PKGS="espeak-ng espeak-ng-data libespeak-ng1 libpcaudio0 libsonic0"

    fetch_pkgs() {
        command -v apt-get >/dev/null 2>&1 || return 1
        command -v dpkg-deb >/dev/null 2>&1 || return 1
        echo "  espeak-ng not installed - fetching a private copy..." >&2
        mkdir -p "$CACHE/espeak-ng"
        for p in $PKGS; do
            if ! ls "$CACHE/espeak-ng/${p}"_*.deb >/dev/null 2>&1; then
                ( cd "$CACHE/espeak-ng" && apt-get download "$p" >/dev/null 2>&1 ) || true
            fi
        done
        for deb in "$CACHE"/espeak-ng/*.deb; do
            [ -f "$deb" ] || continue
            dpkg-deb -x "$deb" "$CACHE/espeak-ng" >/dev/null 2>&1 || true
        done
        [ -x "$CACHE/espeak-ng/usr/bin/espeak-ng" ]
    }

    find_engine() {
        if command -v espeak-ng >/dev/null 2>&1; then
            command -v espeak-ng; return 0
        fi
        if [ -x "$CACHE/espeak-ng/usr/bin/espeak-ng" ] || fetch_pkgs; then
            echo "$CACHE/espeak-ng/usr/bin/espeak-ng"; return 0
        fi
        return 1
    }

    find_libdir() {
        local d
        for d in "$CACHE"/espeak-ng/usr/lib/*/ "$CACHE"/espeak-ng/usr/lib/; do
            [ -e "$d/libespeak-ng.so.1" ] && { echo "${d%/}"; return 0; }
        done
        return 1
    }

    find_data() {
        local d
        for d in /usr/lib/*/espeak-ng-data /usr/lib/espeak-ng-data \
                 /usr/share/espeak-ng-data "$CACHE"/espeak-ng/usr/lib/*/espeak-ng-data \
                 "$CACHE"/espeak-ng/usr/share/espeak-ng-data; do
            [ -d "$d" ] && { echo "$d"; return 0; }
        done
        return 1
    }

    ESPEAK_VOICE="${ESPEAK_VOICE:-en-us}"
    ESPEAK_SPEED="${SPEED:-150}"

    ENGINE_PATH=$(find_engine) || {
        echo "No Edge TTS and no espeak-ng available." >&2
        echo "  install one:   sudo apt install espeak-ng" >&2
        echo "  or allow network access for Edge TTS (uvx edge-tts)" >&2
        echo "  or record your own voice:  ./scripts/record-greeting.sh" >&2
        exit 1
    }
    DATA=$(find_data) || {
        echo "Could not find espeak-ng voice data." >&2
        echo "Install it with:  sudo apt install espeak-ng-data" >&2
        exit 1
    }
    if LIBDIR=$(find_libdir); then
        export LD_LIBRARY_PATH="$LIBDIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    fi

    echo "  engine: espeak-ng (voice: $ESPEAK_VOICE, speed: $ESPEAK_SPEED)"
    ESPEAK_DATA_PATH="$DATA" "$ENGINE_PATH" -v "$ESPEAK_VOICE" -s "$ESPEAK_SPEED" \
        -w "$OUT" "$TEXT"
fi

./scripts/make-sounds.sh
echo "=== Prompt saved to $OUT (+ .ulaw / .alaw) ==="
