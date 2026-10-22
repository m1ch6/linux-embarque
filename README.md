# Smart Doorbell / Intercom

A small embedded doorbell and intercom built on **Alpine Linux + Asterisk**, with a
terminal UI (TUI) that turns one computer into four SIP endpoints. Everything runs
locally and can be tested on a laptop with Docker.

## What it does

- **Two-layer greeting menu (IVR).** A caller dials `9999`, picks a resident, then
  chooses to call them or leave them a message.
- **Calls between residents.** Any of the four extensions can call another one.
- **Messages when nobody answers.** A call rings four times (24 s), then offers the
  caller the same "leave a message after the beep" flow.
- **Call recording.** Every call and message is stored as a WAV file, with a CDR log.
- **Voicemail boxes.** The classic `*97` mailbox flow is still available.
- **A TUI with one panel per resident.** Registration, dialling, answering, playback
  and message management all happen in the terminal.
- **Video relay (optional).** Asterisk can relay H264/VP8 without transcoding, but the
  bundled TUI is audio-only and needs a video-capable client to exercise it.

## How it works

```
 +--------------------------- host ----------------------------+
 |                                                             |
 |  TUI (Rust/ratatui)                                         |
 |    panel 1001 ── baresip ─┐                                 |
 |    panel 1002 ── baresip ─┤   SIP / RTP                     |
 |    panel 1003 ── baresip ─┤   127.0.0.1:5060                |
 |    panel 1004 ── baresip ─┘                                 |
 |                               │                             |
 |  Docker container: doorbell-device (host networking)        |
 |    Asterisk + PJSIP                                         |
 |      ├─ dialplan: IVR 9999, extension-to-extension calls    |
 |      ├─ MixMonitor → /var/spool/asterisk/monitor            |
 |      └─ voicemail  → /var/spool/asterisk/voicemail          |
 +-------------------------------------------------------------+
```

### Components

| Component | Role |
|---|---|
| `docker/` | Alpine + Asterisk image, Compose file and container entrypoint |
| `configs/` | Asterisk configuration: PJSIP endpoints, dialplan, voicemail, logging |
| `sounds/` | Greeting and IVR prompts, live-mounted into the container |
| `tui/` | Rust TUI that supervises one baresip process per resident |
| `docs/` | Step-by-step demo guides |
| `PLAN.md` | Project plan and phases |

### Call flow

1. A resident dials `9999` from their TUI panel.
2. Asterisk plays the welcome prompt and waits for a digit.
3. Layer 1 selects the resident to reach; layer 2 selects **call now** or
   **leave a message**.
4. **Call now** rings the selected endpoint four times. If it is answered, the call
   is recorded. If not, the caller hears the message prompt and the recording is
   saved as a message for that resident.
5. Recordings are written as `<extension>-<timestamp>-<uniqueid>.wav`, so each
   resident's TUI panel can list, play and delete its own files.
6. The TUI refreshes the message list every few seconds, so a new message appears
   without restarting anything.

The Rust code does no SIP plumbing. It starts baresip, sends commands over a pty,
parses the replies, and renders the panels. All SIP, RTP and DTMF work is done by
baresip.

## Install

### Requirements

- **Docker Engine** with the Compose plugin
- **Rust** toolchain (to build the TUI)
- **baresip** (the TUI drives it)
- Optional: **PipeWire** with `pipewire-pulse` and `pipewire-alsa` for echo
  cancellation; without it the TUI falls back to plain ALSA

On Debian/Ubuntu:

```bash
sudo apt install docker.io docker-compose-v2 baresip
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
sudo usermod -aG docker "$USER"   # log out and back in afterwards
```

### Get the code

```bash
git clone <repository-url>
cd linux-embarque
```

## Run

### 1. Start the PBX

From the repository root:

```bash
docker compose -f docker/docker-compose.yml up -d --build
```

The first build downloads Alpine and Asterisk. Check that it is up:

```bash
docker ps
docker logs -f doorbell-device
```

### 2. Start the TUI

In a second terminal:

```bash
cd tui
cargo run --release
```

The TUI **must** be started from `tui/`: baresip resolves its audio path, and the TUI
resolves `asound.conf` and each panel's configuration relative to the working
directory.

### 3. Stop everything

```bash
docker compose -f docker/docker-compose.yml down
```

To also wipe recordings, voicemail and logs stored in the container volumes:

```bash
docker compose -f docker/docker-compose.yml down -v
```

## Using the TUI

Each panel is one resident endpoint. The four extensions are `1001`–`1004`.

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

Panels do **not** auto-answer. Dial a number, then press Enter on the ringing panel
to pick up.

### The IVR menu (`9999`)

**Layer 1 — who do you want to reach?**

| Key | Action |
|---|---|
| `1` | Resident 1 (1001) |
| `2` | Resident 2 (1002) |
| `3` | Resident 3 (1003) |
| `4` | Resident 4 (1004) |
| `0` | Repeat the menu |
| *no input* | goodbye + hang up |
| *invalid* | retry, max 3 times |

**Layer 2 — for the resident you picked:**

| Key | Action |
|---|---|
| `1` | Call them now — rings 4 times, then takes a message |
| `2` | Leave them a message — prompt, beep, then record |
| `0` | Repeat this menu |

Dial `*43` for the echo test, `*44` for playback, `*97` for voicemail.

### Replay and inspect

List recordings:

```bash
docker exec doorbell-device ls -lt /var/spool/asterisk/monitor
```

Copy one out and play it:

```bash
docker cp doorbell-device:/var/spool/asterisk/monitor/<file>.wav /tmp/
ffplay -autoexit /tmp/<file>.wav
```

List voicemail files:

```bash
docker exec doorbell-device find /var/spool/asterisk/voicemail -type f
```

Open the Asterisk CLI:

```bash
docker exec -it doorbell-device asterisk -r
```

Useful CLI commands:

```text
pjsip show endpoints
core show channels
dialplan show internal
voicemail show users
```

## Configuration

`configs/` and `sounds/` are live-mounted into the container, so changes do not
require an image rebuild. Asterisk keeps parsed configuration in memory, so reload
the part you changed:

```bash
docker exec doorbell-device asterisk -rx "dialplan reload"
docker exec doorbell-device asterisk -rx "module reload res_pjsip.so"
docker exec doorbell-device asterisk -rx "module reload app_voicemail.so"
```

Sounds are read from disk on every playback and need no reload.

### Endpoints

The four PJSIP endpoints and their credentials live in `configs/pjsip.conf`; the
matching TUI configurations live under `tui/conf/`. Keep the extension numbers and
credentials in sync when changing them.

### Greeting prompts

The prompts used by the IVR are `welcome`, `choice-*`, `leave-msg`, `invalid` and
`goodbye` under `sounds/`. Replace the files with the same names (`.wav`, `.ulaw`,
`.alaw`) to change the greeting; the running container picks them up on the next
call.

### Recordings and CDR

- Recordings: `/var/spool/asterisk/monitor`
- Voicemail: `/var/spool/asterisk/voicemail`
- CDR: `/var/log/asterisk/cdr-csv/Master.csv`

These live in the `doorbell-spool` and `doorbell-logs` Docker volumes.

## Notes and troubleshooting

- **Host networking is required.** On a rootless podman bridge, inbound SIP source
  addresses are rewritten to the container's own address, so Asterisk sends RTP back
  to itself and calls connect with no audio. With host networking, SIP clients on
  this machine use `127.0.0.1:5060`.
- **One-way audio is intentional.** The caller transmits; the callee answers and
  mutes its microphone, so only the visitor is heard.
- **Echo cancellation.** The TUI loads PipeWire's echo canceller when available and
  falls back to plain ALSA otherwise.
- **Microphone level.** Startup trims an over-hot capture chain; adjust the target in
  `tui/src/sip.rs` or live with `pactl set-source-volume @DEFAULT_SOURCE@ 40%`.
- **Video is relayed only.** Both sides must use the same codec (H264 or VP8). The
  bundled TUI does not load a video module.

## Further documentation

- `tui/README.md` — TUI behaviour, key bindings, audio setup
- `docs/demo-guide.md` — step-by-step walkthrough
- `docs/cli-demo-guide.md` — driving the PBX from the Asterisk CLI
- `PLAN.md` — project plan and phases
