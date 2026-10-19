#!/usr/bin/env bash
# List and replay voicemail messages left for a mailbox.
#
# Messages live inside the container under
#   /var/spool/asterisk/voicemail/default/<mailbox>/INBOX/msg0000.wav
# and this script copies one out to the host and plays it on your speakers,
# exactly like scripts/play-recording.sh does for call recordings.
#
# Usage:
#   ./scripts/play-voicemail.sh                  # newest message in any mailbox
#   ./scripts/play-voicemail.sh --list           # list every mailbox + message
#   ./scripts/play-voicemail.sh --mailbox miora  # newest message for one person
#   ./scripts/play-voicemail.sh --info           # details of the newest message
#   ./scripts/play-voicemail.sh --path           # print host path only
#   ./scripts/play-voicemail.sh msg0001          # play a specific message
#   ./scripts/play-voicemail.sh --transcript     # show caller id / duration text
set -euo pipefail

CONTAINER=doorbell-device
# Empty = newest message across every mailbox. The demo no longer has a single
# "owner" box: each person (hadji/johnson/miora/ulrich) has their own.
MAILBOX="${MAILBOX:-}"
HOSTDIR="${TMPDIR:-/tmp}"
VM_ROOT=/var/spool/asterisk/voicemail/default

MODE=play
NAME=""

while [ $# -gt 0 ]; do
    case "$1" in
        --list|-l)      MODE=list ;;
        --info|-i)      MODE=info ;;
        --path|-p)      MODE=path ;;
        --transcript|-t) MODE=transcript ;;
        --mailbox|-m)   shift; MAILBOX="$1" ;;
        -*)             echo "Unknown option: $1" >&2; exit 2 ;;
        *)              NAME="$1" ;;
    esac
    shift
done

in_container() { docker exec "$CONTAINER" sh -c "$1"; }

# --- list every mailbox -----------------------------------------------------
if [ "$MODE" = list ]; then
    echo "=== Voicemail in $CONTAINER ==="
    in_container "for box in $VM_ROOT/*; do
        [ -d \"\$box\" ] || continue
        m=\$(basename \"\$box\")
        n=\$(find \"\$box/INBOX\" -name 'msg*.wav' 2>/dev/null | wc -l)
        echo \"  \$m: \$n message(s)\"
        find \"\$box/INBOX\" -name 'msg*.wav' 2>/dev/null | sort | while read -r f; do
            echo \"      \$(basename \"\$f\")  \$(stat -c%s \"\$f\") bytes\"
        done
    done" 2>/dev/null || echo "  (container not running)"
    exit 0
fi

# --- pick the message -------------------------------------------------------
if [ -n "$NAME" ]; then
    case "$NAME" in *.wav) ;; *) NAME="${NAME}.wav" ;; esac
    if [ -n "$MAILBOX" ]; then
        SRC="$VM_ROOT/$MAILBOX/INBOX/$NAME"
    else
        # A bare message name: look for it in every mailbox.
        SRC=$(in_container "ls -1 $VM_ROOT/*/INBOX/$NAME 2>/dev/null | head -1" || true)
    fi
elif [ -n "$MAILBOX" ]; then
    SRC=$(in_container "ls -1t $VM_ROOT/$MAILBOX/INBOX/msg*.wav 2>/dev/null | head -1" || true)
else
    # No mailbox named: take the newest message anywhere.
    SRC=$(in_container "ls -1t $VM_ROOT/*/INBOX/msg*.wav 2>/dev/null | head -1" || true)
fi

# If the mailbox was not given, derive it from the path we found: the INBOX's
# parent's parent is <context>/<mailbox>.
if [ -n "$SRC" ] && [ -z "$MAILBOX" ]; then
    MAILBOX=$(in_container "basename \$(dirname \$(dirname '$SRC'))" || true)
fi

if [ -z "$SRC" ]; then
    if [ -n "$MAILBOX" ]; then
        echo "No voicemail found for mailbox '$MAILBOX'." >&2
    else
        echo "No voicemail found in any mailbox." >&2
    fi
    echo "Leave one first: dial 9999, then press 3, and speak for at least 3 seconds." >&2
    exit 1
fi

DEST="$HOSTDIR/doorbell-vm-$(basename "$SRC")"
docker cp "$CONTAINER:$SRC" "$DEST" >/dev/null

case "$MODE" in
    --path|-p|path)
        echo "$DEST"
        exit 0
        ;;
    transcript)
        TXT="${SRC%.wav}.txt"
        echo "Message : $SRC"
        in_container "cat $TXT 2>/dev/null" || echo "(no transcript file)"
        exit 0
        ;;
    info)
        echo "Mailbox  : $MAILBOX"
        echo "Message  : $SRC"
        echo "Host copy: $DEST"
        TXT="${SRC%.wav}.txt"
        echo "Transcript:"
        in_container "sed 's/^/  /' $TXT 2>/dev/null" || true
        if command -v ffprobe >/dev/null 2>&1; then
            ffprobe -v error \
                -show_entries stream=codec_name,sample_rate,channels \
                -show_entries format=duration,size \
                -of default=noprint_wrappers=1 "$DEST"
        else
            ls -la "$DEST"
        fi
        exit 0
        ;;
esac

# --- play it ----------------------------------------------------------------
echo "Playing voicemail for '$MAILBOX': $(basename "$SRC")"
for player in "ffplay -nodisp -autoexit -loglevel error" "pw-play" "paplay" "aplay -q" "play -q"; do
    bin=${player%% *}
    if command -v "$bin" >/dev/null 2>&1; then
        # shellcheck disable=SC2086
        if $player "$DEST"; then
            exit 0
        fi
    fi
done

echo "Could not find a working audio player." >&2
echo "The message was copied to: $DEST" >&2
exit 1
