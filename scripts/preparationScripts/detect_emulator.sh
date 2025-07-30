#!/usr/bin/env bash
set -u  
shopt -s lastpipe

APK_DIR=${1:-}                      # required
OUT_DIR=${2:-results}               # optional
[[ -z "$APK_DIR" ]] && { echo "Usage: $0 <apk_dir> [output_dir]"; exit 1; }

EMULATOR_CMD="emulator -avd Android11_API30_Play -no-window -no-audio \
-memory 2048 -wipe-data -no-snapshot-load -no-snapshot-save \
> /tmp/emulator_stdout.log 2>&1 &"
RESTART_EVERY=25
WAIT_SEC=10
CSV="$OUT_DIR/emulator_detection.csv"

log(){ printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }

emulator_running(){
  adb devices | awk '$1 ~ /^emulator-[0-9]+$/ && $2=="device"{exit 0} END{exit 1}'
}

wait_for_boot(){
  adb wait-for-device
  until [[ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == "1" ]]; do
    sleep 4
  done
}

start_or_reuse_emulator(){
  if emulator_running; then
    log "Emulator already running – re-using it."
    wait_for_boot
  else
    log "Starting fresh emulator…"
    eval "$EMULATOR_CMD"
    wait_for_boot
  fi
}

restart_emulator(){
  log "Rebooting emulator after $PROCESSED APKs…"
  adb emu kill >/dev/null 2>&1 || true
  sleep 8
  start_or_reuse_emulator
}

mkdir -p "$OUT_DIR"
echo "apk_path,package_name,result" > "$CSV"
trap 'log "Interrupted – shutting down"; adb emu kill || true; exit 130' INT TERM

start_or_reuse_emulator

# Build list of APKs with `find` (handles deep trees, weird chars, etc.)
mapfile -t APK_LIST < <(find "$APK_DIR" -type f -iname '*.apk' | sort)
TOTAL=${#APK_LIST[@]}
log "Found $TOTAL APKs – starting loop..."

PROCESSED=0
SUSPECT=0

for APK in "${APK_LIST[@]}"; do
  ((PROCESSED++))
  [[ $((PROCESSED % RESTART_EVERY)) == 0 ]] && restart_emulator

  PKG=$(aapt dump badging "$APK" 2>/dev/null | awk -F"'" '/package: name=/{print $2}')
  if [[ -z "$PKG" ]]; then
    log "[$PROCESSED/$TOTAL] $(basename "$APK") – cannot read package"
    echo "\"$APK\",<unknown>,AAPT_FAIL" >> "$CSV"
    continue
  fi

  log "[$PROCESSED/$TOTAL] ▶  $(basename "$APK")  (pkg: $PKG)"
  BEFORE=$(adb shell dumpsys window windows || true)

  if adb install -r -g "$APK" >/dev/null 2>&1; then
    adb shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
    sleep "$WAIT_SEC"
    AFTER=$(adb shell dumpsys window windows || true)

    if grep -q "$PKG" <<< "$AFTER" && ! grep -q "$PKG" <<< "$BEFORE"; then
      RESULT="OK"
      log "[$PROCESSED/$TOTAL]  $PKG – UI visible"
    else
      RESULT="SUSPECT"
      ((SUSPECT++))
      log "[$PROCESSED/$TOTAL]  $PKG – possible emulator detection"
    fi
  else
    RESULT="INSTALL_FAIL"
    log "[$PROCESSED/$TOTAL]  $PKG – install failed"
  fi

  echo "\"$APK\",\"$PKG\",$RESULT" >> "$CSV"
  adb uninstall "$PKG" >/dev/null 2>&1 || true
done

log "Finished. Total processed: $PROCESSED, Suspect: $SUSPECT"
log "CSV written to: $CSV"

