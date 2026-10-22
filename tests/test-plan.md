# Test Plan

## Phase 2 — Base calls
- [ ] Softphone A registers as hadji (status: Registered).
- [ ] Softphone B registers as miora.
- [ ] Call hadji -> miora: audio both ways.
- [ ] Call miora -> hadji: audio both ways.
- [ ] Echo test *43 works.
- [ ] Playback test *44 works.

## Phase 3 — IVR
- [ ] Dial 9999: hear the layer-1 menu.
- [ ] Press 1–4: hear the layer-2 menu for that person ("Press 1 to call X now…").
- [ ] Press 0: repeats the menu.
- [ ] Press an invalid digit: "invalid" + repeat (max 3 then hangup).
- [ ] No input: "goodbye" + hangup.
- [ ] Layer 2 press 1: rings that person.
- [ ] Not answered after **4 rings** (24 s): the caller is offered the message
      flow, the ring-time recording is discarded, and the panel ends up with
      exactly one file — the message. (`call-person` in `extensions.conf`.)
- [ ] **Refused** while ringing (hang up on the ringing call): the call simply
      ends — no prompt, no recording, no leftover file — and the caller's panel
      comes back to the front with its state back to `Idle`.
- [ ] Extension not registered: the message is offered immediately.
- [ ] The focus follows the call: the **callee's** panel comes to the front while
      it rings, then the **caller's** panel (microphone and all) the moment the
      call falls into the voicemail. `H` then ends the call and the message is
      saved in the recipient's panel.
- [ ] Answered: the call is recorded and no message prompt follows it.
- [ ] Layer 2 press 2: beep, then records a message as `<number>-<timestamp>-<uniqueid>.wav`.
- [ ] Hang up *immediately* after speaking (without waiting out the 5s of
      silence): the message is still kept and playable. `Record()` deletes its
      file on hangup unless the dialplan passes `k`, so this is the regression
      test for a caller losing the message they just left.
- [ ] The message appears in that person's TUI panel **without a keypress**
      (`Messages (N)`, already selected, `New message: …` in CONFIG), and `P` plays it.

## Phase 4 — Voicemail
- [ ] Leave a message when a call is unanswered (busy/unavail falls through to voicemail).
- [ ] Mailboxes are `hadji`, `johnson`, `miora`, `ulrich`; `*97` opens the caller's own mailbox.
- [ ] Listen, delete, verify empty (`docker exec doorbell-device find /var/spool/asterisk/voicemail -type f`).
- [ ] PIN required to access.

## Phase 5 — Recording
- [ ] After a call, a WAV appears in /var/spool/asterisk/monitor.
- [ ] WAV plays back correctly.
- [ ] CDR row present in /var/log/asterisk/cdr-csv/Master.csv.

## Phase 6 — Video
- [ ] Video call hadji <-> miora: picture on both sides.
- [ ] Mixed (voice-only <-> video): falls back to voice.
- [ ] CPU/RAM acceptable during video call.

## Phase 7 — Soak
- [ ] 50 calls in a loop: no zombie channels.
- [ ] No memory growth beyond baseline.
- [ ] No errors in full log.