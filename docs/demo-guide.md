# Demo Guide — Smart Doorbell (GUI)

Two **Linphone** windows are open on your desktop after `Start all`:

- **Window "visitor"** — the doorbell panel (`sip:visitor@127.0.0.1`, SIP port 5070)
- **Window "owner"** — the phone inside the house (`sip:owner@127.0.0.1`, SIP port 5080)

Both register automatically with the Asterisk container (`doorbell-device`) on
`127.0.0.1:5060`. The green dot next to the account name means "registered".

> The phones do **not** auto-answer — click the green call button to pick up.

---

## Demo 1 — Voice call + call recording

1. In the **visitor** window, click the search bar, type `owner`, press **Enter**.
2. The **owner** window rings and shows **Visitor** as the caller. Click **Answer**.
3. Talk; audio flows both ways. Recording starts automatically.
4. Hang up from either side.
5. Verify the recording:

   ```bash
   docker exec doorbell-device ls -la /var/spool/asterisk/monitor/
   ```
   → a new `.wav` file (PCM 8 kHz mono).

6. **Listen to it** on your speakers:

   ```bash
   ./scripts/play-recording.sh          # play the most recent recording
   ./scripts/play-recording.sh --info   # show codec / duration / size
   ./scripts/play-recording.sh --list   # list recordings
   ./scripts/play-recording.sh <name>.wav
   ```

   In the guided demo (`./demo.sh` → option 4), press **`p`** on step 1 or
   step 8 to play the latest recording.

---

## Demo 2 — IVR (greeting menu)

1. Dial `9999` and press Enter (or click the call button).
2. You hear the doorbell menu, then a pause to choose.
3. **Layer 1 — pick a person:** **1** Hadji · **2** Johnson · **3** Miora ·
   **4** Ulrich · **0** repeats the menu.
4. **Layer 2 — for that person:** **1** call them now · **2** leave them a
   message · **0** repeats this menu.
   With **1** the phone rings **4 times** (24 s); if nobody picks up, the caller
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
2. Their phone rings **4 times** (24 s). If nobody picks up you hear "Please
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
docker exec doorbell-device ls -l /var/spool/asterisk/monitor/
./scripts/play-recording.sh --list
```
→ the message is saved as `<number>-<timestamp>-<uniqueid>.wav`, e.g.
`1003-20261019-080816-...wav` if you chose Miora. The extension number comes
first, which is what puts the message in that person's panel in the TUI.

In the TUI the message also appears **by itself** in that person's panel
(`Messages (N)`), already selected, with `New message: …` in the status line.
Press **P** to hear it — there is nothing to refresh.

**Replay the message — from the command line**

```bash
./scripts/play-recording.sh            # play the most recent recording
./scripts/play-recording.sh --list     # list them all
./scripts/play-recording.sh --info     # codec / duration / size
```

**Replay the message — from the TUI**

Select the person's panel with Tab, use ↑/↓ on their `Messages (N)` list and
press **P**.

**Voicemail (dial `*97`)**

An unanswered call no longer goes to voicemail: it rings 4 times and then takes
a message, which lands in the person's panel like any other. The voicemail
boxes are still there if you want them:

```bash
./scripts/play-voicemail.sh --list        # every mailbox + message
./scripts/play-voicemail.sh               # newest message in any mailbox
./scripts/play-voicemail.sh --mailbox miora
```

Or dial `*97` from a phone and enter that person's PIN — `1234` Hadji, `2345`
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

## Demo 5 — One-to-one video

Asterisk relays video without transcoding, so both sides must offer a common
codec (**VP8** here).

1. In the **visitor** window, start a call to `owner` (search bar → `owner` → Enter).
2. Before/while ringing, click the **video camera** button in the call window to
   enable video (both windows have `capture=1` / `display=1`).
3. The **owner** answers; click the video button there too if needed.
4. Both windows show the live camera image.

> If the camera does not open, check the camera device in Linphone's
> *Settings → Video*.

---

## Stopping the demo

```bash
./scripts/stop-all.sh          # or menu option 2 in ./demo.sh
```

## Quick reference — dial codes

| Code | Action |
|---|---|
| `owner` | Call the owner (from the visitor window) |
| `visitor` | Call the visitor (from the owner window) |
| `9999` | IVR greeting menu |
| `*43` | Echo test (audio check) |
| `*44` | Playback test |
| `*97` | Check your own voicemail (PIN 5678 for owner, 1234 for visitor) |
| `1` (in IVR) | Reach Hadji (1001) |
| `2` (in IVR) | Reach Johnson (1002) |
| `3` (in IVR) | Reach Miora (1003) |
| `4` (in IVR) | Reach Ulrich (1004) |
| `0` (in IVR) | Repeat the menu |
| `1` (after picking) | Call that person now |
| `2` (after picking) | Leave that person a message |
