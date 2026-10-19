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
# The window labels match the deterministic Linphone profiles created by
# scripts/setup-linphone.sh: "visitor" (doorbell) and "owner" (house phone).

CONTAINER=doorbell-device
TOTAL=9
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
STEP 1: Voice Call (visitor -> owner)
============================================

  1. In the visitor window, click the search bar.
  2. Type: owner
  3. Press Enter.

  Expected: the owner window rings and shows
            "Visitor" as the caller.
  4. Click the green Answer button in the owner window.
  5. Talk — audio flows both ways.
     Recording starts automatically.
  6. Hang up from either window.

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

  1. In the visitor window, dial: 9999
  2. Press Enter.

  Expected: welcome greeting -> menu wait.

  3. Press a digit:
       1 -> call the owner (rings the house phone)
       2 -> repeat the greeting
       3 -> leave a message for the owner
       0 -> repeat the greeting
       no input -> goodbye + hang up
       invalid digit -> retry, max 3 times

  Try each option and observe the behaviour.
EOF
}

step_3() {
    cat <<'EOF'
STEP 3: Leave a Message (IVR choice 3)
============================================

  1. In the visitor window, dial: 9999
  2. Press 3 during the menu.

  Expected: voicemail greeting -> beep -> recording.
  3. Speak your message (at least 3 seconds).
  4. Hang up to finish.

  Verify:
    ./scripts/play-voicemail.sh --list
  -> msg0000.wav + msg0000.txt in default/owner/INBOX/
EOF
}

step_4() {
    cat <<'EOF'
STEP 4: Replay the Message
============================================

  From the command line (easiest):
    ./scripts/play-voicemail.sh            # play the newest message
    ./scripts/play-voicemail.sh --info     # caller id + duration
    ./scripts/play-voicemail.sh --list     # every mailbox + message
    ./scripts/play-voicemail.sh msg0000    # a specific message

  Or from the phone (owner window):
  1. Dial: *97
  2. Press Enter.

  Expected: VoiceMailMain asks for the mailbox PIN.
  3. Type PIN: 5678
  4. Press Enter.

  Expected: message count, then your message.
  Press # to exit, or hang up.
EOF
}

step_5() {
    cat <<'EOF'
STEP 5: Echo Test (Audio Check)
============================================

  1. In the visitor window, dial: *43
  2. Press Enter.

  Expected: you hear your own voice played back.
  This confirms audio works in both directions.
EOF
}

step_6() {
    cat <<'EOF'
STEP 6: Playback Test
============================================

  1. In the visitor window, dial: *44
  2. Press Enter.

  Expected: plays the demo-congrats sound file.
EOF
}

step_7() {
    cat <<'EOF'
STEP 7: One-to-one Video
============================================

  1. In the visitor window, start a call to: owner
  2. Click the video-camera button to enable video.
  3. In the owner window, click Answer, then also
     enable its video-camera button.

  Expected: both windows show the live camera image.
  Asterisk relays video without transcoding (VP8 codec).

  If the camera does not open, check Settings -> Video.
EOF
}

step_8() {
    cat <<'EOF'
STEP 8: Verify Recordings & CDR
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

step_9() {
    cat <<'EOF'
STEP 9: Cleanup
============================================

  Clean test data:
    ./scripts/reset-demo.sh

  Stop everything:
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
    elif [ "$STEP" -eq 1 ] || [ "$STEP" -eq 8 ]; then
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
