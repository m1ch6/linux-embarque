# Doorbell TUI

A ratatui terminal UI with one panel per user (`1001` Hadji, `1002` Johnson,
`1003` Miora, `1004` Ulrich) plus a `CONFIG` panel. Each panel is a real SIP
endpoint driven by **baresip** against the Asterisk container: real
registration, real calls in both directions, real recorded audio.

Rust does **no** SIP plumbing — it only supervises the baresip processes, feeds
them commands over a pty, parses their logs, and renders the panels. All
SIP/RTP/DTMF is handled by baresip.

## Run

```bash
# 1. PBX (from the repo root)
./scripts/start-all.sh          # or ./demo.sh

# 2. TUI
cd tui
cargo run --release
```

> The TUI must be started **from `tui/`**: baresip resolves `audio_path sounds`
> and the TUI resolves `./asound.conf` and `./conf/<user>/` relative to the
> working directory. Everything it needs is already in this directory.

## Keys

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

## Behaviour

* **Ringing happens only on the callee.** The host ringtone was removed, the
  dialplan's `Dial()` has no `r`, and every baresip config sets
  `ringback_disabled yes`. The callee still rings using baresip's own
  `ring_aufile` (`sounds/ring.wav`).
* **The focus follows the call.** When a panel rings the TUI switches to it, so
  the operator can answer with Enter. If the call is not answered, then the
  moment Asterisk moves on to the message flow the TUI switches back to the
  *caller* and turns its microphone on, so the visitor can speak and then press
  `H`. Hanging up is what ends the call, and the message is only saved once the
  call ends — the dialplan's `Record(…,k)` is what keeps it. When the call ends
  (either way) the focus comes back to the panel that placed it. A panel that
  *answered* is never treated this way: its microphone stays off (one-way
  audio).
* **The call state is self-correcting.** Besides reading baresip's output, the
  TUI asks it for its call list once a second (`/listcalls`). That is the
  authoritative answer, and it is what stops a panel getting stuck: a rejected
  ringing call prints "call: rejecting incoming call …", which matches none of
  the end-of-call phrases, and without the reconciliation the panel would sit on
  "Ringing (incoming)" for ever.
* **One-way audio between people.** The callee answers with
  `/acceptdir audio=recvonly video=inactive` and then switches its microphone
  to the silent ALSA device, so it never transmits. Only the caller talks.
* **The caller always dials full duplex.** `audio=sendrecv` on every call,
  because Asterisk talks to the caller: the doorbell menu, and "please leave
  your message after the beep" when a call is not answered. A send-only caller
  is played to by Asterisk but never hears any of it — which is exactly how the
  message prompt used to go missing. Making the caller able to listen changes
  nothing about who can be heard, since the callee is receive-only.
* **The receiver saves the audio.** Asterisk's `[record-call]` dialplan writes
  `MixMonitor(<receiver>-<timestamp>-<uniqueid>.wav)` into
  `/var/spool/asterisk/monitor/`. Each panel lists the files named after it and
  can replay (`P`) or delete (`D`) them.
* **The message list is live.** The directory is re-read every 3 s while the
  TUI runs, because a message left on the IVR is written by Asterisk behind our
  back. A new file appears in its recipient's panel on its own, becomes that
  panel's selected entry, and a `New message: …` line names it in CONFIG — no
  keypress, no restart. `R` still forces an immediate refresh.

## Microphone level

The default ALSA capture chain is usually far too hot. On this machine it was
`Internal Mic Boost` at **+20 dB** stacked on `Capture` at **+30 dB**, which
pinned the ADC at full scale: a quiet room measured 0.99 RMS with **94 % of all
samples clipped**. A saturated input does not sound "loud", it sounds harsh and
unintelligible.

At startup the TUI therefore trims the capture chain (`ensure_mic_gain()` in
`src/sip.rs`):

* drops the extra `*Mic Boost` preamp to 0 dB (hardware specific, best effort),
* sets the source volume to `TARGET` (30 %) — `pactl` maps this onto the
  hardware `Capture` control, so it works without naming a codec-specific control,
* never *raises* a level the user deliberately lowered.

After the trim the same measurement is 0.03 RMS with zero clipped samples, and a
test voice sent through a real call is recorded at ‑16 dBFS peak / ‑29 dBFS RMS.

If the far end is too quiet or too loud for your taste, adjust `TARGET` in
`src/sip.rs`, or override it live with e.g.:

```bash
pactl set-source-volume @DEFAULT_SOURCE@ 40%   # louder
pactl set-source-volume @DEFAULT_SOURCE@ 20%   # quieter
```

## Echo cancellation

Both softphones share one sound card, so without help the caller's microphone
re-captures the callee's speaker output and sends it back — an echo.

The TUI fixes this with PipeWire's echo canceller:

* On startup it loads `module-echo-cancel`, which creates `doorbell_mic` (the
  real mic *minus* whatever plays on `doorbell_speaker`) and `doorbell_speaker`.
* `asound.conf` defines a `doorbell` PCM that maps capture → `doorbell_mic` and
  playback → `doorbell_speaker`.
* Every baresip is started with `ALSA_CONFIG_PATH=asound.conf` and
  `audio_source/audio_player/audio_alert = alsa,doorbell`.

Measured on this machine: a test tone played to the speaker drops from RMS
`0.356` (raw mic) to `0.003` on the echo-cancelled mic — about 40 dB of
suppression.

If PipeWire or the module is unavailable, the TUI falls back to the plain
`alsa,default` device (and rewrites the configs accordingly), so it still runs.

Requirements for the AEC path: PipeWire with `pipewire-pulse` and the PipeWire
ALSA plugin (`pipewire-alsa`). On Ubuntu these are the default packages.
