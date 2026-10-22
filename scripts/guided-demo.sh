#!/usr/bin/env bash
# Guided step-by-step manual demo (menu option 4 of ./demo.sh).
#
# Readability notes:
#   - Each step is a small function whose text lives in a quoted heredoc, so
#     the file reads top-to-bottom like the on-screen output.
#   - Every step prints the same layout: title, separator, body, then a blank
#     line before the navigation prompt.
#   - Navigation (Enter=next, b=back, q=quit) is handled in ONE place.
#
# The SIP clients are the TUI's baresip panels (see tui/README.md): hadji,
# johnson, miora and ulrich. Start it first with:  cd tui && cargo run --release

CONTAINER=doorbell-device
TOTAL=8
STEP=1

# ---------------------------------------------------------------- banner
header() {
    echo "============================================"
    echo "  GUIDED DEMO — SMART DOORBELL"
    echo "  Step $STEP of $TOTAL   (b=back, q=quit)"
    echo "============================================"
    echo
}

# ---------------------------------------------------------------- steps
step_1() {
    cat <<'EOF'
STEP 1: Voice Call (hadji -> miora)
============================================

  In the TUI (start it with: cd tui && cargo run --release):

  1. Press Tab until the Hadji panel is ACTIVE.
  2. Type: 1003
  3. Press Enter.

  Expected: the Miora panel starts ringing and the
            focus jumps to it (ringing follows the callee).
  4. Press Enter on the Miora panel to answer.
  5. Talk. Only the caller transmits (the callee answers
     receive-only), so Hadji is heard on Miora's panel.
     Recording starts automatically.
  6. Press H to hang up.

  Verify recording:
    docker exec doorbell-device ls /var/spool/asterisk/monitor/
  -> a new .wav file

  Listen to the recording:
    ./scripts/play-recording.sh
  or press "p" now to play the latest recording.
EOF
}

step_2() {
    cat <<'EOF'
STEP 2: IVR (Greeting Menu)
============================================

  1. On any TUI panel, type: 9999
  2. Press Enter.

  Expected: welcome greeting -> menu wait.

  3. Press a person:
       1 -> Hadji      2 -> Johnson
       3 -> Miora      4 -> Ulrich
     then:
       1 -> call that person now
       2 -> leave that person a message
       0 -> repeat the menu
       no input -> goodbye + hang up
       invalid digit -> retry, max 3 times

  Try each option and observe the behaviour.
EOF
}

step_3() {
    cat <<'EOF'
STEP 3: Leave a Message (IVR: person, then "2")
=============================================

  1. On any TUI panel, dial: 9999
  2. Press 3 (Miora), then 2 (leave a message).

  Expected: "leave your message after the beep" -> beep -> recording.
  3. Speak your message (at least 3 seconds).
  4. Press H to finish (hanging up is what saves it).

  Verify:
    ./scripts/play-recording.sh --list
  -> 1003-<timestamp>-<uniqueid>.wav, and it appears in Miora's TUI panel.
EOF
}

step_4() {
    cat <<'EOF'
STEP 4: Replay the Message
============================================

  From the TUI:
  1. Press Tab to reach the CONFIG panel.
  2. Use the up/down arrows to select the recording,
     then press P to play it through the speakers.

  From the command line (easiest):
    ./scripts/play-recording.sh            # play the most recent recording
    ./scripts/play-recording.sh --info     # codec / duration / size
    ./scripts/play-recording.sh --list     # list them all
    ./scripts/play-voicemail.sh --list     # the voicemail boxes (dial *97)

  Voicemail (from a panel): dial *97, then that person's PIN
  (1234 Hadji, 2345 Johnson, 3456 Miora, 4567 Ulrich).
EOF
}

step_5() {
    cat <<'EOF'
STEP 5: Echo Test (Audio Check)
============================================

  1. On any TUI panel, type: *43
  2. Press Enter.

  Expected: you hear your own voice played back.
  This confirms audio works in both directions.
EOF
}

step_6() {
    cat <<'EOF'
STEP 6: Playback Test
============================================

  1. On any TUI panel, type: *44
  2. Press Enter.

  Expected: plays the demo-congrats sound file.
EOF
}

step_7() {
    cat <<'EOF'
STEP 7: Verify Recordings & CDR
============================================

  Recordings:
EOF
    docker exec "$CONTAINER" sh -c "ls -la /var/spool/asterisk/monitor/ 2>/dev/null" || true

    cat <<'EOF'

  Last CDR line:
EOF
    docker exec "$CONTAINER" sh -c "tail -1 /var/log/asterisk/cdr-csv/Master.csv 2>/dev/null || echo '  (no CDR yet)'" || true

    cat <<'EOF'

  Inspect a recording:
    docker cp doorbell-device:/var/spool/asterisk/monitor/<file>.wav /tmp/rec.wav
    ffprobe -v error -show_entries format=duration,size \
      -of default=noprint_wrappers=1 /tmp/rec.wav

  Play the latest recording:
    ./scripts/play-recording.sh      (or press "p" now)
    ./scripts/play-recording.sh --info
EOF
}

step_8() {
    cat <<'EOF'
STEP 8: Cleanup
============================================

  Clean test data:
    ./scripts/reset-demo.sh

  Stop the PBX:
    ./scripts/stop-all.sh

============================================
  DEMO COMPLETE
============================================
EOF
}

# ---------------------------------------------------------------- loop
while :; do
    clear
    header
    "step_$STEP"
    echo

    if [ "$STEP" -eq "$TOTAL" ]; then
        read -rp "  [Enter=exit, b=back, q=quit]: " input
    elif [ "$STEP" -eq 1 ] || [ "$STEP" -eq 7 ]; then
        read -rp "  [Enter=next, p=play recording, b=back, q=quit]: " input
    else
        read -rp "  [Enter=next, b=back, q=quit]: " input
    fi

    case "$input" in
        b|B) [ "$STEP" -gt 1 ] && STEP=$((STEP - 1)) ;;
        p|P) ./scripts/play-recording.sh || true ;;
        q|Q) exit 0 ;;
        *)
            if [ "$STEP" -lt "$TOTAL" ]; then
                STEP=$((STEP + 1))
            else
                exit 0
            fi
            ;;
    esac
done
