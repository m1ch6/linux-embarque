#!/usr/bin/env bash
# Regenerate every IVR prompt in one go.
#
# The wording here mirrors configs/extensions.conf: if you change a prompt's
# text in the dialplan, change it here too. Prompts are committed to
# sounds/custom/, so this is only needed when the wording or the voice changes.
#
# Usage:
#   ./scripts/make-prompts.sh                            # default Edge voice
#   VOICE=en-US-AriaNeural ./scripts/make-prompts.sh     # a different voice
#   ENGINE=espeak ./scripts/make-prompts.sh              # offline fallback voice
set -euo pipefail
cd "$(dirname "$0")/.."

gen() { OUT_NAME="$1" ./scripts/tts-greeting.sh "$2"; }

# IVR layer 1 - who do you want to reach?
gen welcome "Welcome to the doorbell. To reach Hadji, press 1. To reach Johnson, press 2. To reach Miora, press 3. To reach Ulrich, press 4."

# IVR layer 2 - call now, or leave a message?
gen choice-hadji   "Press 1 to call Hadji now. Press 2 to leave a message."
gen choice-johnson "Press 1 to call Johnson now. Press 2 to leave a message."
gen choice-miora   "Press 1 to call Miora now. Press 2 to leave a message."
gen choice-ulrich  "Press 1 to call Ulrich now. Press 2 to leave a message."

# Shared prompts
gen leave-msg "Please leave your message after the beep."
gen invalid   "Sorry, that was not a valid choice."
gen goodbye   "Thank you. Goodbye."

# Asterisk builds its voicemail greeting from this fragment followed by the
# extension digits. We ship our own so it uses the demo's voice - it sits at
# the top of sounds/ (not custom/) because that is where Asterisk looks for
# the plain name `vm-theperson`.
OUT_PATH=sounds/vm-theperson.wav ./scripts/tts-greeting.sh "The person at extension"

echo "=== All IVR prompts regenerated ==="
