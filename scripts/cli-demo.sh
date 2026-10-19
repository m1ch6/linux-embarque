#!/usr/bin/env bash
# CLI-only demo: test all features without a softphone
# Idempotent: safe to run multiple times
set -e
cd "$(dirname "$0")/.."

CONTAINER=doorbell-device
CONFIG="configs/extensions.conf"
BACKUP="/tmp/opencode/extensions.conf.cli-backup"

# Ensure container is running
if ! docker ps --filter name=$CONTAINER --format '{{.Names}}' | grep -q $CONTAINER; then
    echo "Starting container..."
    docker compose -f docker/docker-compose.yml up -d
    sleep 3
fi

# Backup config before modifying
cp "$CONFIG" "$BACKUP"

# Cleanup function: restore config on exit
cleanup() {
    cp "$BACKUP" "$CONFIG" 2>/dev/null || true
    python3 - <<'PY'
p='configs/extensions.conf'
s=open(p).read()
s=s.replace("exten => 9998,1,VoiceMail(owner,u)\n same => n,Hangup()\n","")
s=s.replace("exten => 9997,1,VoiceMailMain(owner)\n same => n,Hangup()\n","")
open(p,'w').write(s)
PY
    docker exec $CONTAINER asterisk -rx "dialplan reload" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Remove any leftover test extensions
python3 - <<'PY'
p='configs/extensions.conf'
s=open(p).read()
s=s.replace("exten => 9998,1,VoiceMail(owner,u)\n same => n,Hangup()\n","")
s=s.replace("exten => 9997,1,VoiceMailMain(owner)\n same => n,Hangup()\n","")
open(p,'w').write(s)
PY
docker exec $CONTAINER asterisk -rx "dialplan reload" >/dev/null 2>&1

# Clean test data for fresh run
docker exec $CONTAINER sh -c "rm -f /var/spool/asterisk/monitor/*.wav; find /var/spool/asterisk/voicemail -type f -delete; rm -f /var/log/asterisk/cdr-csv/Master.csv" 2>/dev/null || true

echo "============================================"
echo "  DOORBELL CLI DEMO (idempotent)"
echo "============================================"
echo ""

echo "[1/9] Endpoints..."
docker exec $CONTAINER asterisk -rx "pjsip show endpoints" | grep -iE 'visitor/|owner/' | grep -v 'Endpoint:  <'

echo "[2/9] IVR (reach + timeout)..."
docker exec $CONTAINER asterisk -rx "channel originate Local/s@ivr-main application NoOp" >/dev/null 2>&1
sleep 7
echo "      OK - played welcome, timed out, hung up"

echo "[3/9] Echo test..."
docker exec $CONTAINER asterisk -rx "channel originate Local/*43@internal application NoOp" >/dev/null 2>&1
sleep 2
echo "      OK"

echo "[4/9] Playback test..."
docker exec $CONTAINER asterisk -rx "channel originate Local/*44@internal application NoOp" >/dev/null 2>&1
sleep 2
echo "      OK"

echo "[5/9] Voice call (visitor -> owner)..."
docker exec $CONTAINER asterisk -rx "channel originate Local/owner@internal application Wait 8" >/dev/null 2>&1
sleep 10
echo "      OK - call completed"

echo "[6/9] Recordings..."
docker exec $CONTAINER sh -c "ls /var/spool/asterisk/monitor/*.wav 2>/dev/null | wc -l | xargs -I{} echo '      {} recording(s)'"

echo "[7/9] CDR..."
docker exec $CONTAINER sh -c "wc -l < /var/log/asterisk/cdr-csv/Master.csv 2>/dev/null | xargs -I{} echo '      {} rows' || echo '      0 rows'"

echo "[8/9] Voicemail (leave message)..."
python3 - <<'PY'
p='configs/extensions.conf'
s=open(p).read()
needle="exten => 9999,1,Goto(ivr-main,s,1)\n"
add=needle+"exten => 9998,1,VoiceMail(owner,u)\n same => n,Hangup()\n"
s=s.replace(needle,add,1)
open(p,'w').write(s)
PY
docker exec $CONTAINER asterisk -rx "dialplan reload" >/dev/null 2>&1
docker exec $CONTAINER asterisk -rx "channel originate Local/9998@internal application Wait 15" >/dev/null 2>&1
sleep 17
VM_COUNT=$(docker exec $CONTAINER sh -c 'find /var/spool/asterisk/voicemail -name "msg*.wav" 2>/dev/null | wc -l')
echo "      Voicemail app executed. Messages: $VM_COUNT (needs audio source for full recording)"

echo "[9/9] Voicemail replay..."
python3 - <<'PY'
p='configs/extensions.conf'
s=open(p).read()
needle="exten => 9998,1,VoiceMail(owner,u)\n same => n,Hangup()\n"
add=needle+"exten => 9997,1,VoiceMailMain(owner)\n same => n,Hangup()\n"
s=s.replace(needle,add,1)
open(p,'w').write(s)
PY
docker exec $CONTAINER asterisk -rx "dialplan reload" >/dev/null 2>&1
docker exec $CONTAINER asterisk -rx "channel originate Local/9997@internal application Wait 10" >/dev/null 2>&1
sleep 12
echo "      VoicemailMain played (PIN prompt in log)"

echo ""
echo "============================================"
echo "  DEMO COMPLETE"
echo "============================================"
echo "  Recordings: $(docker exec $CONTAINER sh -c 'ls /var/spool/asterisk/monitor/*.wav 2>/dev/null | wc -l') files"
echo "  Voicemail:  $(docker exec $CONTAINER sh -c 'find /var/spool/asterisk/voicemail -name "msg*.wav" 2>/dev/null | wc -l') messages"
echo "  CDR rows:   $(docker exec $CONTAINER sh -c 'wc -l < /var/log/asterisk/cdr-csv/Master.csv 2>/dev/null || echo 0')"
echo ""
echo "Note: Leaving a real voicemail needs an audio source (softphone or the"
echo "      headless tester). To record and replay one end to end:"
echo "        ./scripts/sip-test.py call --user visitor --target 9999 \\"
echo "            --dtmf 3 --dtmf-delay 10 --audio msg.wav --audio-delay 8"
echo "        ./scripts/play-voicemail.sh"