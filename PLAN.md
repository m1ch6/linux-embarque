# Embedded Asterisk Project — Plan

**Project name:** Smart Doorbell / Intercom
**OS:** Alpine Linux (lightweight)
**Emulation:** Docker on the host laptop (no real hardware needed)
**Features:** (1) Greeting menu (IVR), (2) Voicemail, (3) Call recording, (4) Simple one-to-one video call
**Host:** Pop!_OS 22.04, x86_64, Docker available, no passwordless sudo
**Author:** (you)
**Status:** Plan — not yet implemented

---

## 1. Project goal (in plain words)

Build a small "smart doorbell / intercom" device that:
- Greets visitors with a recorded message and a simple keypad menu.
- Lets visitors leave a voicemail if no one answers.
- Records every call so you can replay it later.
- Supports a simple one-to-one video call (see and talk to the visitor).

Everything runs on a tiny, lightweight Linux (Alpine) and is fully testable on your laptop using Docker — no real hardware required.

---

## 2. What we are building (components)

| Component | What it is | Tool/tech |
|---|---|---|
| Operating system | Lightweight Linux | Alpine Linux |
| Phone system | The "brain" that handles calls | Asterisk (from Alpine package) |
| SIP engine | Modern way phones talk to each other | PJSIP (built into Asterisk) |
| Emulation harness | Fake "device" running on your laptop | Docker container |
| Test phones | One fake phone per resident, in the TUI | baresip (driven by tui/) |
| Greeting audio | Recorded voice message | ffmpeg (you already have it) |

---

## 3. Why Alpine Linux

- Very small (~5 MB base), boots in seconds.
- Uses little RAM and CPU — good for embedded.
- Asterisk is available as a ready-to-install package (`apk add asterisk`).
- Works both in Docker (for testing) and on real embedded boards (for shipping).
- Simple package manager (`apk`).

---

## 4. Project folder layout

Create this structure under `/home/miora/Projets/Linux_Embarque/`:

```
Linux_Embarque/
├── README.md                 # How to build, run, test
├── docker/                   # Emulation harness
│   ├── Dockerfile            # Alpine + Asterisk + configs
│   ├── docker-compose.yml    # Container + optional mail catcher
│   └── entrypoint.sh         # Start Asterisk inside container
├── configs/                  # Asterisk config files (the "overlay")
│   ├── pjsip.conf            # Phones (extensions) and transports
│   ├── extensions.conf       # Dialplan: menus, routing, features
│   ├── voicemail.conf        # Voicemail mailboxes
│   ├── modules.conf          # Which Asterisk parts to load
│   ├── asterisk.conf         # General settings
│   ├── logger.conf           # Logging
│   └── rtp.conf              # Media port range
├── sounds/                   # Recorded greetings and prompts
│   └── custom/               # Your recorded audio (ulaw, 8 kHz, mono)
├── scripts/                  # Helper scripts
│   ├── build-image.sh        # Build Docker image
│   ├── run.sh                # Run the "device" container
│   ├── smoke-test.sh         # Automated basic checks
│   └── record-greeting.sh    # Record a greeting with ffmpeg
├── tests/                    # Test notes and checklists
│   └── test-plan.md
└── docs/                     # Notes, decisions, results
    └── notes.md
```

---

## 5. Phased implementation plan

### Phase 0 — Preparation (you, on host)
**Goal:** Have tools ready.
- [ ] Install **baresip** (the TUI drives it) and a Rust toolchain.
- [ ] Verify Docker works: `docker run --rm hello-world`.
- [ ] (Optional, needs sudo) `sudo apt install sox` — useful for audio conversion. ffmpeg already present.
- [ ] Create the project folder structure above.

**Done when:** folder structure exists, baresip installed, Docker works.

---

### Phase 1 — Base "device" container (Alpine + Asterisk)
**Goal:** A running Alpine container with Asterisk installed and starting automatically.

Tasks:
- [ ] Write `docker/Dockerfile`:
  - Base: `alpine:latest` (or a pinned version like `alpine:3.20`).
  - Install: `asterisk`, `asterisk-pjsip`, `asterisk-voicemail`, `asterisk-sounds-en` (or minimal), `bash`, `tcpdump` (for debugging).
  - Copy `configs/` into `/etc/asterisk/`.
  - Copy `sounds/` into `/var/lib/asterisk/sounds/`.
  - Expose ports: 5060/udp (SIP), 10000-10100/udp (media/RTP), 5061/tcp (optional TLS).
  - Entrypoint runs Asterisk in foreground (`asterisk -f`).
- [ ] Write `docker/docker-compose.yml` with the asterisk service and port mappings.
- [ ] Write `scripts/build-image.sh` and `scripts/run.sh`.
- [ ] Build and run; verify Asterisk starts: `docker logs <container>` and `asterisk -rx "core show version"` (via `docker exec`).

**Done when:** Container runs, Asterisk daemon is up, CLI responds.

---

### Phase 2 — Base Asterisk configuration
**Goal:** Two phones can register and call each other.

Tasks:
- [ ] `pjsip.conf`: UDP transport on 0.0.0.0:5060; two endpoints `100` and `101` with auth + aor; codecs ulaw/alaw (and VP8/H264 for video later).
- [ ] `extensions.conf`: `internal` context with:
  - `exten => 100,1,Dial(PJSIP/100)` and same for 101.
  - Echo test on `*43` (`Echo()`).
  - Playback sanity on `*44` (`Playback(demo-congrats)` or a custom sound).
- [ ] `modules.conf`: autoload on, with explicit `noload` for unused modules (chan_sip, heavy ones) to keep footprint small.
- [ ] `rtp.conf`: port range 10000–10100.
- [ ] `logger.conf`: console + rotating file log.
- [ ] `asterisk.conf`: basic paths.
- [ ] Configure the TUI endpoints to register as hadji..ulrich against `127.0.0.1:5060`.
- [ ] Test: call 100 → 101 and back; echo test; check no errors in logs.

**Done when:** the TUI panels register, voice call works, echo test passes.

---

### Phase 3 — Feature: Greeting menu (IVR)
**Goal:** A caller hears a greeting and a keypad menu, and pressing a digit routes the call.

Tasks:
- [ ] Record greeting with ffmpeg: `record-greeting.sh` records mic → ulaw 8 kHz mono WAV into `sounds/custom/welcome.wav` (and optionally `.ulaw`).
  - Alternative: use a text-to-speech or a sample file if no mic.
- [ ] Create menu context in `extensions.conf`:
  - `ivr-main`: `Answer()`, `Background(custom/welcome)`, `WaitExten(5)`.
  - Digit 1 → go to "leave message" (voicemail, Phase 4).
  - Digit 2 → dial the house phone (101).
  - Digit 0 → repeat greeting.
  - `i` (invalid) → play "invalid" and repeat (max 3 tries, then hang up).
  - `t` (timeout) → play "goodbye" and hang up.
- [ ] Add a "goodbye" / "invalid" prompt (use built-in sounds or record).
- [ ] Route inbound calls to `ivr-main` (e.g., extension `s` or a dedicated number like `9999`).
- [ ] Test: call in, hear greeting, press 1/2/0/invalid/timeout; verify routing.

**Done when:** Menu plays, all digits route correctly, invalid/timeout handled.

---

### Phase 4 — Feature: Voicemail
**Goal:** A caller can leave a message; the owner can listen to it.

Tasks:
- [ ] `voicemail.conf`: mailboxes 100 and 101 with PINs (e.g., 1234, 5678); format=wav; attach=no (keep it simple, on-device).
- [ ] Dialplan:
  - When 101 is busy/unavailable → `Voicemail(101,u)` (unavailable greeting) or `Voicemail(101,b)` (busy greeting).
  - Owner dials `*97` (or `*98`) → `VoicemailMain(101)` to check messages.
- [ ] Record unavailable/busy greetings (or use defaults).
- [ ] (Optional, recommended for "non-technical" feel) Wire voicemail-to-email via a local mail catcher in Docker (e.g., Mailhog) so you can see emails in a browser. If skipped, voicemail stays on-device and is checked by phone.
- [ ] Test: leave a message as visitor; check as owner via `*97`; delete message; verify empty mailbox.

**Done when:** Message can be left and retrieved; PIN works; delete works.

---

### Phase 5 — Feature: Call recording
**Goal:** Every call is saved as an audio file.

Tasks:
- [ ] In dialplan, add `MixMonitor()` at the start of calls (e.g., in `internal` context or in the IVR entry): `MixMonitor(/var/spool/asterisk/monitor/${STRFTIME(${EPOCH},,%Y%m%d-%H%M%S)}-${UNIQUEID}.wav)`.
- [ ] Ensure the monitor directory exists and is writable by the asterisk user.
- [ ] Add a simple size guard: document a cleanup rule (e.g., delete recordings older than 7 days) — implement as a cron or a manual script `scripts/cleanup-recordings.sh`.
- [ ] `cdr.conf` / CDR CSV: enable default CSV backend; verify `/var/log/asterisk/cdr-csv/Master.csv` gets a row per call.
- [ ] Test: make a call, check a WAV file appears in the monitor folder and plays back; check CDR row.

**Done when:** Recording file created per call, playable, CDR logged.

---

### Phase 6 — Feature: Simple one-to-one video call
**Goal:** Asterisk can relay a video call (needs a video-capable client).

Tasks:
- [ ] In `pjsip.conf`, ensure endpoints 100/101 allow video codecs (H264 and/or VP8) in addition to audio (ulaw/alaw). Set `allow=!all,ulaw,alaw,h264,vp8` (or similar).
- [ ] In `rtp.conf`, ensure video RTP ports are in the media range (same range is fine).
- [ ] Disable video transcoding (Asterisk relays video; both sides must use the same codec). Document this.
- [ ] Configure a video-capable client to enable video and use H264/VP8.
- [ ] Test: video call 100 ↔ 101; verify picture on both sides; check CPU/RAM usage during call.
- [ ] Test mixed call: voice-only phone ↔ video phone (should fall back to voice).
- [ ] Document bandwidth/CPU observations.

**Done when:** One-to-one video call works with acceptable quality on the test machine.

---

### Phase 7 — Emulation & integration testing
**Goal:** All 4 features work together reliably.

Tasks:
- [ ] Write `tests/test-plan.md` with a checklist:
  - Registration of both phones.
  - Voice call both directions.
  - Echo test.
  - IVR: each digit, invalid, timeout, repeat.
  - Voicemail: leave, retrieve, delete, PIN.
  - Recording: file exists, playable, CDR row.
  - Video: one-to-one call, mixed call.
- [ ] Write `scripts/smoke-test.sh`: runs `asterisk -rx` checks (endpoints registered, modules loaded, dialplan shows contexts) and reports pass/fail.
- [ ] Soak test: run 20–50 calls in a loop (using a script or sipp), check for zombie channels (`core show channels`), memory growth, log errors.
- [ ] Document results in `docs/notes.md`.

**Done when:** All checklist items pass; soak test shows no leaks/errors.

---

### Phase 8 — Packaging & documentation
**Goal:** Reproducible project anyone can rebuild.

Tasks:
- [ ] Finalize `README.md`: prerequisites, build steps, run steps, test steps, troubleshooting.
- [ ] Commit/pin Alpine version and Asterisk version in Dockerfile for reproducibility.
- [ ] Add a "reset to clean state" script (remove recordings, voicemail, logs).
- [ ] (Optional) If you later want real hardware: note the path to flash the Alpine image to a board (out of scope for emulation).

**Done when:** A fresh clone + `scripts/build-image.sh` + `scripts/run.sh` yields a working device.

---

## 6. Key configuration decisions (locked)

| Decision | Choice | Reason |
|---|---|---|
| OS | Alpine Linux | Lightest with Asterisk package |
| SIP stack | PJSIP | Modern default, supports video + WebRTC |
| Audio codec | ulaw (G.711) | Universal, no transcoding needed |
| Video codec | H264 (primary), VP8 (fallback) | Common, Asterisk relays without transcoding |
| Container | Docker (Alpine) | No sudo needed, fast iteration |
| Voicemail storage | On-device files | Simple, no mail server needed |
| Voicemail email | Optional (local mail catcher) | Nice-to-have, not core |
| Recording format | WAV (ulaw) | Playable anywhere |

---

## 7. Testing approach (simple)

- **Four TUI panels** on your laptop act as the four residents — hadji, johnson, miora and ulrich.
- **Docker container** acts as the "doorbell device."
- You call from one panel to another (or to the IVR number) and observe.
- Check files (recordings, voicemail, CDR) inside the container via `docker exec`.
- All tests are manual + a small automated smoke script.

---

## 8. Risks and mitigations

| Risk | Mitigation |
|---|---|
| Video too heavy for embedded | Keep it one-to-one, same codec both sides, relay only (no transcoding) |
| Audio quality issues in Docker | Use host networking or proper port mapping; test early |
| Voicemail storage fills disk | Add cleanup script; document retention policy |
| Config complexity | Start minimal (Phase 2) and add features one at a time |
| Forgetting steps after session ends | This plan file + README.md capture everything |

---

## 9. Definition of "done"

The project is complete when:
- [ ] Alpine Docker container builds and runs Asterisk.
- [ ] TUI panels register and make voice calls.
- [ ] IVR menu works (all digits, invalid, timeout).
- [ ] Voicemail: leave + retrieve + delete works.
- [ ] Call recording: file created and playable per call; CDR logged.
- [ ] One-to-one video call works.
- [ ] Smoke test script passes.
- [ ] README documents build/run/test.

---

## 10. Next action (when you switch to Build/implementation)

Start with **Phase 0** (preparation) and **Phase 1** (base container). Do not skip ahead — each phase builds on the previous one. If a phase fails, fix it before moving on.

---

*Plan saved at: `/home/miora/.opencode/plan/asterisk-embedded-plan.md`*
*This file persists across sessions. Open it anytime to resume.*