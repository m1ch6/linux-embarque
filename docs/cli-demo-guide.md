# CLI Demo Guide — Smart Doorbell

All features can be tested via the Asterisk CLI without the TUI.

## Prerequisites
```bash
cd /home/miora/Projets/baresip
docker compose -f docker/docker-compose.yml up -d --build   # starts the PBX container
```

## Quick commands

### Check system status
```bash
docker exec doorbell-device asterisk -rx "pjsip show endpoints" | grep -iE 'hadji/|johnson/|miora/|ulrich/' | grep -v 'Endpoint:'
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

### Test voice call (hadji → miora)
```bash
docker exec doorbell-device asterisk -rx "channel originate Local/1003@internal application Wait 20"
```
→ Rings Miora, holds, and (if unanswered) moves on to the message flow.
A registered baresip endpoint (a TUI panel) is needed for it to actually ring.

### Leave a message (IVR layer 2, option 2)
Driving the IVR end to end needs a SIP client that can send DTMF and audio — use a
TUI panel (see `docs/demo-guide.md`). The message is written to
`/var/spool/asterisk/monitor/1003-<timestamp>-<uniqueid>.wav`.

### Leave a message after 4 rings (nobody picks up)
The same flow runs when a call is not answered: the phone rings 4 times (24 s)
and the caller is then offered the message. The recording of the ringing itself
is thrown away, so the panel gets one file: the message.

### Replay the message
```bash
# list recordings (newest first)
docker exec doorbell-device ls -lt /var/spool/asterisk/monitor

# copy one out and play it
docker cp doorbell-device:/var/spool/asterisk/monitor/<file>.wav /tmp/
ffplay -autoexit /tmp/<file>.wav

# voicemail boxes (dial *97)
docker exec doorbell-device find /var/spool/asterisk/voicemail -type f
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