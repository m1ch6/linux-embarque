# Smart Doorbell / Intercom (Embedded Asterisk Project)

A lightweight embedded doorbell/intercom built on **Alpine Linux + Asterisk**, fully testable on your laptop with Docker.

## Features
1. **Greeting menu (IVR)** — a two-layer keypad menu: pick a person, then call them or leave them a message.
2. **Voicemail / messages** — spoken messages are saved and can be replayed.
3. **Call recording** — every call saved as a WAV file + CDR log.
4. **Simple one-to-one video** — H264/VP8 relayed by Asterisk (no transcoding).
   Relaying only: it needs a video-capable client; the bundled TUI is audio-only.

### The IVR menu (dial `9999`)

**Layer 1 — who do you want to reach?**

| Key | Action |
|---|---|
| `1` | Hadji (1001) |
| `2` | Johnson (1002) |
| `3` | Miora (1003) |
| `4` | Ulrich (1004) |
| `0` | Repeat the menu |
| *no input* | goodbye + hang up |
| *invalid* | retry, max 3 times |

**Layer 2 — for the person you picked:**

| Key | Action |
|---|---|
| `1` | Call them now — rings 4 times, then takes a message |
| `2` | **Leave them a message** — prompt, beep, then record |
| `0` | Repeat this menu |

Both choices end up in the same place: `/var/spool/asterisk/monitor/`. A call
becomes `<person>-<timestamp>-<uniqueid>.wav`, and so does a message, so the
recipient finds either one in their own panel of the TUI. Messages stay
available there (`P` to play) and can also be played with
`./scripts/play-recording.sh`.

"Call them now" rings for **4 rings (24 s)** and then offers the same "leave
your message after the beep" flow if nobody picks up — so a missed call leaves
a message in that person's panel too. The ring-time recording is dropped in
that case, so every call leaves exactly one file.

Only a **full** four-ring wait offers a message. If the call is refused (the
callee hangs up on the ringing call) or cut short, it simply ends — nothing is
recorded and no prompt is played. If the extension is not registered at all,
there is nobody to ring, so the message is offered straight away. Dialling
`*97` still reaches the voicemail box (`./scripts/play-voicemail.sh`).

## Quick start

### Prerequisites
- Docker (with your user in the `docker` group)
- For the TUI: **baresip** and a **Rust** toolchain
  (`sudo apt install baresip`; get Rust from <https://rustup.rs>)

### Run it
The easiest way is the unified menu:

```bash
./demo.sh
```

Options: `1) Start all` · `2) Stop all` · `3) Reset demo` · `4) Guided demo`.

Or drive the scripts directly:

```bash
./scripts/build-image.sh    # build the Asterisk image (first time)
./scripts/start-all.sh      # start the PBX container
./scripts/stop-all.sh       # stop the PBX
./scripts/reset-demo.sh     # wipe recordings/voicemail/CDR
```

Then start the SIP clients — the TUI, which runs one baresip endpoint per
resident (**hadji**, **johnson**, **miora**, **ulrich**):

```bash
cd tui && cargo run --release
```

### Test
```bash
./scripts/smoke-test.sh
```

### Make a call
The TUI shows one panel per resident:
- **hadji** · **johnson** · **miora** · **ulrich**

Panels do **not** auto-answer. Press Tab to focus a panel, type a number and
press Enter to dial; the callee's panel rings and you press Enter there to
answer. Press `H` to hang up.
Dial `1003` (or `miora`) to call Miora, `9999` for the IVR, `*43` for echo
test, `*44` for playback, `*97` for voicemail.

See `tui/README.md` for the key bindings and behaviour, and
`docs/demo-guide.md` for a step-by-step walkthrough (voice, IVR, voicemail,
recording).

### Replay a voicemail message
```bash
./scripts/play-voicemail.sh                   # newest message in any mailbox
./scripts/play-voicemail.sh --info            # caller id, duration, size
./scripts/play-voicemail.sh --list            # every mailbox + message
./scripts/play-voicemail.sh --mailbox miora   # newest message for one person
./scripts/play-voicemail.sh msg0000           # a specific message
```

### Test headless (no TUI)
The same IVR/message flow can be driven from the command line — this registers
as a real SIP endpoint, sends DTMF and can stream a WAV as the caller's audio:
```bash
# 9999 -> 3 (Miora) -> 2 (leave a message), then speak for msg.wav
./scripts/sip-test.py call --user hadji --target 9999 \
    --dtmf 32 --dtmf-delay 12 --audio msg.wav --audio-delay 6 --duration 34
./scripts/play-recording.sh
```
`--dtmf-delay` has to outlast the welcome menu (~10 s), and `--duration` has to
cover the whole call: menu, message, and the 5 s of silence that ends the
recording. The tester binds its own port (`--local-port`, 5099), so it can run
while the TUI is up.

### Inspect
```bash
docker exec -it doorbell-device asterisk -r                       # Asterisk CLI
docker logs -f doorbell-device                                   # logs
docker exec doorbell-device ls /var/spool/asterisk/monitor       # recordings
docker exec doorbell-device ls /var/spool/asterisk/voicemail/default  # voicemail
```

### Listen to a recording
```bash
./scripts/play-recording.sh          # play the most recent call recording
./scripts/play-recording.sh --info   # show its codec / duration / size
./scripts/play-recording.sh --list   # list all recordings
```

### Change the greeting
```bash
./scripts/record-greeting.sh 5   # record 5 seconds from your mic
```
or regenerate every prompt from text with a neural voice:
```bash
./scripts/make-prompts.sh                          # all IVR prompts, default voice
VOICE=en-US-AriaNeural ./scripts/make-prompts.sh   # a different voice
```
`make-prompts.sh` keeps the wording in one place; a single prompt can also be
regenerated on its own:
```bash
OUT_NAME=leave-msg ./scripts/tts-greeting.sh "Please leave your message after the beep."
```
TTS is **online by default** (Microsoft Edge neural voices — free, no API key):
`tts-greeting.sh` uses `edge-tts` if installed, otherwise `uvx edge-tts` or
`pipx run edge-tts`. With no network it falls back to the offline `espeak-ng`
voice, and `ENGINE=espeak` forces that. Only *generation* needs the network: the
resulting `.wav`/`.ulaw`/`.alaw` files are committed, so running the demo never
does. List the voices with `uvx edge-tts --list-voices`.

The prompts the IVR uses are: `welcome`, `choice-<person>`, `leave-msg`,
`invalid` and `goodbye`.
The sounds directory is live-mounted, so the IVR picks up the new greeting on
the next call — no rebuild needed.

### Apply a config change
`configs/` is live-mounted too, but Asterisk keeps parsed configs in memory, so
reload whatever you changed:
```bash
docker exec doorbell-device asterisk -rx "dialplan reload"                 # extensions.conf
docker exec doorbell-device asterisk -rx "module reload res_pjsip.so"      # pjsip.conf
docker exec doorbell-device asterisk -rx "module reload app_voicemail.so"  # voicemail.conf
```
Sounds need no reload: they are read from disk on every playback.

### Cleanup old recordings
```bash
./scripts/cleanup-recordings.sh 7   # delete older than 7 days
```

## Project layout
| Path | Contents |
|---|---|
| `configs/` | Asterisk configuration (dialplan, PJSIP, voicemail, logging) |
| `docker/` | Container image and compose setup |
| `scripts/` | Build, demo, recording and test helpers |
| `sounds/` | Greeting and IVR prompts (live-mounted into the container) |
| `tests/` | Test plan |
| `tui/` | baresip-driven terminal UI |
| `docs/` | Demo guides |
| `PLAN.md` | Full project plan and phases |

## Notes
- The container runs with **host networking** (`network_mode: host`). This is
  required: on a rootless podman bridge, inbound SIP source addresses are
  rewritten to the container's own IP, so Asterisk sends all RTP back to
  itself and calls connect with no audio. Publishing 5060/10000-10100 does not
  fix it. With host networking, SIP clients on this machine use `127.0.0.1:5060`.
- Video is relayed only (no transcoding). Both sides must use the same codec (H264 or VP8).
- Voicemail is stored on-device; no email delivery in base setup.
- Container runs as the `asterisk` user (non-root).
