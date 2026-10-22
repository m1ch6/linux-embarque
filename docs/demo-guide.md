# Demo Guide — Smart Doorbell (TUI)

The SIP clients are the TUI's panels — one baresip endpoint per resident:

- **hadji** (1001) · **johnson** (1002) · **miora** (1003) · **ulrich** (1004)
- plus a **CONFIG** panel for the recordings

Start the PBX, then the TUI (in another terminal, from `tui/`):

```bash
docker compose -f docker/docker-compose.yml up -d --build
cd tui && cargo run --release
```

Each panel registers automatically with the Asterisk container
(`doorbell-device`) on `127.0.0.1:5060`. The panel shows `Registered: Yes`
once it is up.

> Panels do **not** auto-answer — press **Enter** on a ringing panel to pick up.

## Key bindings

| Key | Action |
|---|---|
| `0`–`9` then Enter | dial that extension |
| Enter (on a ringing panel) | answer |
| `4` (on a ringing panel) | decline |
| `H` | hang up |
| Backspace | delete the last dialled digit |
| `0`–`9`, `*`, `#` during a call | send DTMF |
| Tab / ← / → | switch panels |
| `Q` / Esc | quit |
| CONFIG panel: ↑/↓ select, `P` play, `D` delete, `R` refresh | manage recordings |

---

## Demo 1 — Voice call + call recording

1. Press **Tab** until the **hadji** panel is ACTIVE.
2. Type `1003` and press **Enter**.
3. The **miora** panel starts ringing and the focus jumps to it. Press
   **Enter** there to answer.
4. Talk. Only the caller transmits — the callee answers receive-only, so Hadji
   is heard on Miora's panel. Recording starts automatically.
5. Press **H** to hang up.
6. Verify the recording:

   ```bash
   docker exec doorbell-device ls -la /var/spool/asterisk/monitor/
   ```
   → a new `.wav` file (PCM 8 kHz mono).

7. **Listen to it** on your speakers:

   ```bash
   # list recordings (newest first)
   docker exec doorbell-device ls -lt /var/spool/asterisk/monitor

   # copy one out and play it
   docker cp doorbell-device:/var/spool/asterisk/monitor/<file>.wav /tmp/
   ffplay -autoexit /tmp/<file>.wav
   ```

---

## Demo 2 — IVR (greeting menu)

1. On any panel, dial `9999` and press Enter.
2. You hear the doorbell menu, then a pause to choose.
3. **Layer 1 — pick a person:** **1** Hadji · **2** Johnson · **3** Miora ·
   **4** Ulrich · **0** repeats the menu.
4. **Layer 2 — for that person:** **1** call them now · **2** leave them a
   message · **0** repeats this menu.
   With **1** the panel rings **4 times** (24 s); if nobody picks up, the caller
   hears "Please leave your message after the beep" and the message lands in
   that person's panel — the same flow as **2**.
5. no input → goodbye and hang up. invalid digit → "invalid" prompt, then
   repeats (max 3 tries).

---

## Demo 3 — Leave a message + replay

**Leave a message**

1. Dial `9999`.
2. Press the person (**1**–**4**), then press **2** to leave a message.
3. You hear "Please leave your message after the beep", then a beep, then
   recording starts.
4. Speak. Five seconds of silence ends the message and says goodbye — but
   hanging up straight after speaking works just as well: the dialplan passes
   `k` to `Record()` precisely so that a caller who hangs up while the
   recording is still running does not lose their message (without it,
   Asterisk deletes the file).

**Or leave a message after 4 rings**

1. Dial `9999`, press the person, then press **1** (call them now).
2. Their panel rings **4 times** (24 s). If nobody picks up you hear "Please
   leave your message after the beep" instead of Asterisk's own voicemail
   greeting, and the message is saved exactly like the one above: the silent
   recording of the ringing is dropped, so the panel gets one file, not two.
   The panel that is ringing comes to the front while it rings; when the call
   falls through to the voicemail the *caller's* panel comes back, microphone
   and all — speak, then press **H**. Hanging up is what saves the message.
3. Hanging up **while it is still ringing** (refusing the call) just ends it:
   no prompt, no recording, and the caller's panel comes back to the front.

**Verify the message**

```bash
docker exec doorbell-device ls -lt /var/spool/asterisk/monitor
docker cp doorbell-device:/var/spool/asterisk/monitor/<file>.wav /tmp/
```
→ the message is saved as `<number>-<timestamp>-<uniqueid>.wav`, e.g.
`1003-20261019-080816-...wav` if you chose Miora. The extension number comes
first, which is what puts the message in that person's panel in the TUI.

In the TUI the message also appears **by itself** in that person's panel
(`Messages (N)`), already selected, with `New message: …` in the status line.
Press **P** to hear it — there is nothing to refresh.

**Replay the message — from the TUI**

Select the person's panel with Tab, use ↑/↓ on their `Messages (N)` list and
press **P**.

**Replay the message — from the command line**

```bash
docker exec doorbell-device ls -lt /var/spool/asterisk/monitor
docker cp doorbell-device:/var/spool/asterisk/monitor/<file>.wav /tmp/
ffplay -autoexit /tmp/<file>.wav
```

**Voicemail (dial `*97`)**

An unanswered call no longer goes to voicemail: it rings 4 times and then takes
a message, which lands in the person's panel like any other. The voicemail
boxes are still there if you want them:

```bash
# list every voicemail file
docker exec doorbell-device find /var/spool/asterisk/voicemail -type f

# copy one out and play it
docker cp doorbell-device:/var/spool/asterisk/voicemail/<path> /tmp/
ffplay -autoexit /tmp/<file>
```

Or dial `*97` from a panel and enter that person's PIN — `1234` Hadji, `2345`
Johnson, `3456` Miora, `4567` Ulrich (see `configs/voicemail.conf`).
Keypad: `1` new messages, `2` old, `3` advanced, `4` folders, `0` options,
`*` help, `#` exit.

---

## Demo 4 — Call recording + CDR

After any call:

```bash
# Recordings
docker exec doorbell-device ls -la /var/spool/asterisk/monitor/

# CDR log
docker exec doorbell-device cat /var/log/asterisk/cdr-csv/Master.csv

# Inspect a recording
docker cp doorbell-device:/var/spool/asterisk/monitor/<file>.wav /tmp/
ffprobe -v error -show_entries format=duration,size -of default=noprint_wrappers=1 /tmp/<file>.wav
```

---

## Video

Asterisk can relay video without transcoding (H264/VP8), but the bundled TUI
loads no video module and dials audio-only, so a video call is not part of the
TUI demo. To exercise video you would need a video-capable client pointed at the
container.

---

## Stopping the demo

```bash
docker compose -f docker/docker-compose.yml down
```

## Quick reference — dial codes

| Code | Action |
|---|---|
| `1001` / `hadji` | Call Hadji |
| `1002` / `johnson` | Call Johnson |
| `1003` / `miora` | Call Miora |
| `1004` / `ulrich` | Call Ulrich |
| `9999` | IVR greeting menu |
| `*43` | Echo test (audio check) |
| `*44` | Playback test |
| `*97` | Check your own voicemail (PIN 1234 Hadji, 2345 Johnson, 3456 Miora, 4567 Ulrich) |
| `1` (in IVR) | Reach Hadji (1001) |
| `2` (in IVR) | Reach Johnson (1002) |
| `3` (in IVR) | Reach Miora (1003) |
| `4` (in IVR) | Reach Ulrich (1004) |
| `0` (in IVR) | Repeat the menu |
| `1` (after picking) | Call that person now |
| `2` (after picking) | Leave that person a message |
