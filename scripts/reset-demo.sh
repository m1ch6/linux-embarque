#!/usr/bin/env bash
# Reset demo: clean recordings, voicemail, CDR and restore the dialplan.
# Leaves the PBX stopped — run "Start all" afterwards.
cd "$(dirname "$0")/.."

echo "=== Resetting demo ==="

# 1. Clean Asterisk test data
docker exec doorbell-device sh -c "rm -f /var/spool/asterisk/monitor/*.wav; find /var/spool/asterisk/voicemail -type f -delete; rm -f /var/log/asterisk/cdr-csv/Master.csv" 2>/dev/null || true

# 2. Restore dialplan from backup if exists, otherwise just reload
if [ -f /tmp/opencode/extensions.conf.cli-backup ]; then
    cp /tmp/opencode/extensions.conf.cli-backup configs/extensions.conf
fi

# 3. Remove any leftover test extensions
python3 - <<'PY'
p='configs/extensions.conf'
s=open(p).read()
s=s.replace("exten => 9998,1,VoiceMail(miora,u)\n same => n,Hangup()\n","")
s=s.replace("exten => 9997,1,VoiceMailMain(miora)\n same => n,Hangup()\n","")
open(p,'w').write(s)
PY

# 4. Reload the dialplan
docker exec doorbell-device asterisk -rx "dialplan reload" 2>&1 | tail -1

echo "=== Reset complete ==="
echo "    Run \"Start all\" to relaunch a clean demo."
