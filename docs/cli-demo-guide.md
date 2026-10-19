# CLI Demo Guide — Smart Doorbell

All features can be tested via the Asterisk CLI without a softphone.

## Prerequisites
```bash
cd /home/miora/Projets/Linux_Embarque
./scripts/start-all.sh   # starts container + Linphone windows
```

## Quick commands

### Check system status
```bash
docker exec doorbell-device asterisk -rx "pjsip show endpoints" | grep -iE 'visitor/|owner/' | grep -v 'Endpoint:'
docker exec doorbell-device asterisk -rx "core show channels" | tail -2
```

### Test IVR (reach + timeout)
```bash
docker exec doorbell-device asterisk -rx "channel originate Local/s@ivr-main application NoOp"
```
→ Plays welcome tone, waits 5s, plays goodbye, hangs up.

### Test echo
```bash
docker exec doorbell-device asterisk -rx "channel originate Local/*43@internal application NoOp"
```

### Test playback
```bash
docker exec doorbell-device asterisk -rx "channel originate Local/*44@internal application NoOp"
```

### Test voice call (visitor → owner)
```bash
docker exec doorbell-device asterisk -rx "channel originate Local/owner@internal application Wait 10"
```
→ Rings owner (auto-answers), holds 10s, records the call.

### Leave a message (IVR layer 2, option 2)
The IVR has a real "leave a message" option, and the headless tester can drive
it end to end — including streaming real audio so the message is saved:
```bash
# 9999 -> 3 (Miora) -> 2 (leave a message), then stream msg.wav as the message
./scripts/sip-test.py call --user hadji --target 9999 \
    --dtmf 32 --dtmf-delay 12 --audio msg.wav --audio-delay 6 --duration 34
```
The message is written to `/var/spool/asterisk/monitor/1003-<timestamp>-<uniqueid>.wav`.
`--dtmf-delay` has to outlast the welcome menu (~10 s) and `--duration` has to
cover menu + message + the 5 s of silence that ends the recording. The tester
uses its own local port (5099), so it can run while the TUI is up.

### Leave a message after 4 rings (nobody picks up)
The same flow runs when a call is not answered: the phone rings 4 times (24 s)
and the caller is then offered the message.
```bash
# 1003 rings 4 times, then takes the message
./scripts/sip-test.py call --user hadji --target 1003 \
    --audio msg.wav --audio-delay 3.5 --duration 1
```
`--audio-delay` counts from the *answer*, and an unanswered call only answers
once the message prompt starts, so keep it short here. `--answer-timeout`
(default 60 s) is what lets the tester wait out the ringing — the doorbell rings
for 24 s before it says anything. The recording of the ringing itself is thrown
away, so the panel gets one file: the message.

### Replay the message
```bash
./scripts/play-recording.sh            # play the most recent recording
./scripts/play-recording.sh --list     # list them all
./scripts/play-voicemail.sh --list     # the voicemail boxes (dial *97)
```

### Verify results
```bash
# Recordings
docker exec doorbell-device ls -la /var/spool/asterisk/monitor/

# Voicemail messages
docker exec doorbell-device find /var/spool/asterisk/voicemail -type f

# CDR log
docker exec doorbell-device cat /var/log/asterisk/cdr-csv/Master.csv

# Inspect a recording
docker cp doorbell-device:/var/spool/asterisk/monitor/<file>.wav /tmp/rec.wav
ffprobe -v error -show_entries format=duration,size -of default=noprint_wrappers=1 /tmp/rec.wav
```

### Automated demo
```bash
./scripts/cli-demo.sh
```
Runs all tests automatically and reports results.

### IVR DTMF navigation
Dial `9999`.

Layer 1 — pick a person:
- `1` → Hadji (1001)
- `2` → Johnson (1002)
- `3` → Miora (1003)
- `4` → Ulrich (1004)
- `0` → repeat the menu
- (no input) → goodbye + hangup
- (invalid digit) → invalid + repeat (max 3)

Layer 2 — for the person you picked:
- `1` → call them now
- `2` → leave them a message (prompt, beep, record)
- `0` → repeat this menu
- (no input) → goodbye + hangup
- (invalid digit) → invalid + repeat (max 3)