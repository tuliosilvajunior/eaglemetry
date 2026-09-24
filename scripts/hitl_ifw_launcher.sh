#!/usr/bin/env bash
# Human-in-the-loop repro for: "the IFW rules block the manual launcher open".
#
# The bug: with the CarPlay / Android Auto option and the charging option on,
# the launcher tiles for CarPlay, Android Auto and Auto Energy do nothing.
#
# The loop is red when a tile fails to open its app AND the event log shows an
# ifw_intent_matched line for the tap. That line names the intent the launcher
# really sends, which is the fact this whole diagnosis is missing.
#
# Needs: the car on adb. Run from the repo root.
#   bash scripts/hitl_ifw_launcher.sh

set -uo pipefail

IFW_DIR=/data/system/ifw

step() { printf '\n>>> %s\n' "$1"; read -r -p "    [Enter when done] " _; }
capture() {
  local var="$1" question="$2" answer
  printf '\n>>> %s\n' "$question"
  read -r -p "    > " answer
  printf -v "$var" '%s' "$answer"
}

if ! adb get-state >/dev/null 2>&1; then
  echo "No device on adb. Connect the head unit first."; exit 1
fi

printf '\n--- Rules now on the car ---\n'
adb shell "ls -l $IFW_DIR" 2>&1

probe() { # probe <label> <tile name>
  local label="$1" tile="$2" opened matched
  adb logcat -b events -c
  step "On the head unit, tap the $tile tile in the launcher."
  capture opened "Did $tile open? (y/n)"
  matched=$(adb logcat -b events -d 2>/dev/null | grep ifw_intent_matched || true)
  printf '\n%s_OPENED=%s\n' "$label" "$opened"
  printf '%s_IFW_MATCHED<<\n%s\n>>\n' "$label" "${matched:-none}"
}

echo "=== PHASE A: rules installed (both settings ON) ==="
step "In Capy Energy settings, turn ON the CarPlay/Android Auto option and the open-on-charge option. Then close the app."
adb shell "ls $IFW_DIR" 2>&1
probe A_CARPLAY "CarPlay"
probe A_AAUTO   "Android Auto"
probe A_ENERGY  "Auto Energy"

echo "=== PHASE B: rules removed (control) ==="
adb shell "su -c 'rm -f $IFW_DIR/ifw_block_autoenergy.xml $IFW_DIR/ifw_block_projection.xml'" 2>&1
adb shell "ls $IFW_DIR" 2>&1
probe B_CARPLAY "CarPlay"
probe B_AAUTO   "Android Auto"
probe B_ENERGY  "Auto Energy"

printf '\nDone. Phase A red + Phase B green isolates the rules as the cause.\n'
printf 'The ifw_intent_matched lines name the intent to stop blocking.\n'
