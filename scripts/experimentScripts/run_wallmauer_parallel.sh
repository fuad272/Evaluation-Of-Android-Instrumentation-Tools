#!/bin/bash
INPUT_DIR="$1";       shift
OUTPUT_DIR="$1";      shift
EMULATOR_NAME="$1";   shift
EMULATOR_PORT="$1";   shift

# ——— Constants & Paths ———
WORK_DIR="/home/fuad/tools/wallmauer/workDir"
LOG_DIR="$OUTPUT_DIR/logs"
CSV_FILE="$OUTPUT_DIR/coverage_results.csv"

KEYSTORE="/home/fuad/tools/wallmauer/my-release-key.jks"
KEY_ALIAS="my-key-alias"
KEY_PASS="my-store-password"

INSTR_JAR="/home/fuad/tools/wallmauer/basicBlockCoverage/build/libs/basicBlockCoverage.jar"
BLOCKS_FILE="/home/fuad/tools/wallmauer/basicBlockCoverage/build/libs/blocks.txt"
EVAL_JAR="/home/fuad/tools/wallmauer/basicBlockCoverageEvaluation/build/libs/basicBlockCoverageEvaluation.jar"
MONKEY_SEED=12345
INSTR_TIMEOUT=3600   # seconds for instrumentation
export ANDROID_SERIAL="emulator-${EMULATOR_PORT}"
# ——— Usage Check ———
if [ -z "$INPUT_DIR" ] || [ -z "$OUTPUT_DIR" ] \
   || [ -z "$EMULATOR_NAME" ] || [ -z "$EMULATOR_PORT" ]; then
  echo "Usage: $0 <input_apk_dir> <output_dir> <emulator_name> <emulator_port>"
  exit 1
fi

mkdir -p "$OUTPUT_DIR" "$LOG_DIR"
echo "APK,Coverage (%),Initially Healthy,Instrumented Successfully,Healthy After Instrumentation,Instrumentation Time (s)" \
  > "$CSV_FILE"

# ——— Emulator Helpers ———
wait_for_boot() {
  adb -s "$ANDROID_SERIAL" wait-for-device
  until [[ "$(adb -s "$ANDROID_SERIAL" shell getprop sys.boot_completed | tr -d '\r')" == "1" ]]; do
    sleep 5
  done
  sleep 5
}

start_emulator() {
  if ! adb -s "$ANDROID_SERIAL" get-state >/dev/null 2>&1; then
    emulator -avd "$EMULATOR_NAME" -port "$EMULATOR_PORT" \
      -no-window -no-audio -memory 2048 \
      -wipe-data -no-snapshot-load -no-snapshot-save \
      >/dev/null 2>&1 &
    wait_for_boot
  fi
}

restart_emulator() {
  adb -s "$ANDROID_SERIAL" emu kill
  sleep 10
  start_emulator
}

start_emulator
adb -s "$ANDROID_SERIAL" shell mkdir -p /sdcard/Download

# ——— Counters ———
instrumented_successful=0
healthy_after_instr=0
total_apps=$(ls "$INPUT_DIR"/*.apk 2>/dev/null | wc -l)
apk_counter=0

# ——— Main Loop ———
for apk in "$INPUT_DIR"/*.apk; do
  find "$INPUT_DIR" -type f -name "*-instrumented.apk" -delete
  ((apk_counter++))

  # Reset flags
  initially_healthy_flag=1
  instrumented_success_flag=0
  healthy_after_instr_flag=0

  # Periodic emulator restart
  if (( apk_counter % 10 == 0 && apk_counter < total_apps )); then
    restart_emulator
  fi

  apk_filename=$(basename "$apk")
  echo "[$EMULATOR_NAME] ($apk_counter/$total_apps) → $apk_filename"

  # Clear logs
  adb -s "$ANDROID_SERIAL" logcat -c

  # === Health check before instrumentation ===
  # (e.g. verify device responds)
  if ! adb -s "$ANDROID_SERIAL" shell pm list packages >/dev/null 2>&1; then
    initially_healthy_flag=0
  fi

  # === Instrumentation ===
  start_ts=$(date +%s)
  instr_log="$LOG_DIR/${apk_filename%.apk}-instrument.log"
  instrument_output=$(timeout ${INSTR_TIMEOUT}s \
    java -Xms1G -Xmx8G -XX:+UseG1GC -XX:MaxGCPauseMillis=200 -jar "$INSTR_JAR" "$apk" 2>&1 | tee "$instr_log")
  end_ts=$(date +%s)
  instr_duration=$((end_ts - start_ts))

  # OOM or timeout?
  if grep -q "OutOfMemoryError" <<<"$instrument_output" \
     || grep -q "^timeout" <<<"$instrument_output"; then
    echo " instrumentation failed (OOM/timeout)"
  else
    if grep -q "Instrumenting the app took" <<<"$instrument_output"; then
      instrumented_success_flag=1
      ((instrumented_successful++))
      echo " instrumentation succeeded in ${instr_duration}s"
    else
      echo " instrumentation reported failure"
    fi
  fi

  # If instrumentation failed, write CSV and continue
  if [ $instrumented_success_flag -eq 0 ]; then
    echo "$apk_filename,0.0,$initially_healthy_flag,0,0,$instr_duration" \
      >> "$CSV_FILE"
    continue
  fi

  # Determine package name
  package_name=$(aapt dump badging "$apk" \
    | awk -F"'" '/package: name=/{print $2}')

  # Uninstall any existing
  if adb -s "$ANDROID_SERIAL" shell pm list packages | grep -q "$package_name"; then
    adb -s "$ANDROID_SERIAL" uninstall "$package_name" >/dev/null 2>&1
  fi

  # Move & sign instrumented APK
  inst_src="$(dirname "$apk")/${package_name}-instrumented.apk"
  inst_apk="$WORK_DIR/${package_name}-instrumented.apk"
  if [ -f "$inst_src" ]; then
    mv "$inst_src" "$WORK_DIR/"
  else
    echo " ERROR: instrumented APK missing"
    echo "$apk_filename,0.0,$initially_healthy_flag,1,0,$instr_duration" \
      >> "$CSV_FILE"
    continue
  fi

  signed_apk="$WORK_DIR/${package_name}-signed.apk"
  apksigner sign \
    --ks "$KEYSTORE" --ks-key-alias "$KEY_ALIAS" \
    --ks-pass pass:"$KEY_PASS" \
    --out "$signed_apk" "$inst_apk"

  # === Post-instrumentation health + UI check ===
  if ! timeout 60s adb -s "$ANDROID_SERIAL" install -g "$signed_apk" \
      >/dev/null 2>&1; then
    echo " install failed"
  else
    # capture window state
    before_windows=$(adb -s "$ANDROID_SERIAL" shell dumpsys window windows || true)
    adb -s "$ANDROID_SERIAL" shell monkey \
      -p "$package_name" --pct-syskeys 0 \
      -s "$MONKEY_SEED" -v 1 >/dev/null 2>&1
    sleep 6
    after_windows=$(adb -s "$ANDROID_SERIAL" shell dumpsys window windows || true)

    if adb -s "$ANDROID_SERIAL" logcat -d \
         | grep -qE "FATAL EXCEPTION|VerifyError"; then
      echo "  post-instr crash"
    elif grep -q "$package_name" <<<"$after_windows" \
         && ! grep -q "$package_name" <<<"$before_windows"; then
      healthy_after_instr_flag=1
      ((healthy_after_instr++))
      echo " post-instr healthy + UI visible"
    else
      echo " post-instr UI not visible"
    fi
  fi

  # Cleanup install
  adb -s "$ANDROID_SERIAL" uninstall "$package_name" \
    >/dev/null 2>&1
  adb -s "$ANDROID_SERIAL" logcat -c

  # === Coverage run & trace pull ===
  adb -s "$ANDROID_SERIAL" install "$signed_apk" >/dev/null 2>&1
  adb -s "$ANDROID_SERIAL" shell monkey \
    -p "$package_name" --pct-syskeys 0 \
    -s "$MONKEY_SEED" -v 400 >/dev/null 2>&1
  sleep 5

  adb -s "$ANDROID_SERIAL" shell am broadcast \
    -a STORE_TRACES \
    -n "${package_name}/de.uni_passau.fim.auermich.tracer.Tracer"

  adb -s "$ANDROID_SERIAL" pull /storage/emulated/0/traces.txt  "$WORK_DIR/traces.txt"
  adb -s "$ANDROID_SERIAL" pull /storage/emulated/0/info.txt    "$WORK_DIR/info.txt"

  # === Evaluate coverage ===
  eval_log="$LOG_DIR/${apk_filename%.apk}-eval.log"
  java -Xms1G -Xmx8G -XX:+UseG1GC -XX:MaxGCPauseMillis=200 -jar "$EVAL_JAR" "$BLOCKS_FILE" "$WORK_DIR/traces.txt" \
    2>&1 | tee "$eval_log"

  total_line=$(grep "Total line coverage" "$eval_log" \
    | awk -F: '{print $2}' | tr -d '% ')
  total_line="${total_line:-0.0}"

  # Final CSV write for this APK
  echo "$apk_filename,$total_line,$initially_healthy_flag,$instrumented_success_flag,$healthy_after_instr_flag,$instr_duration" \
    >> "$CSV_FILE"

  # Cleanup
  rm -f "$WORK_DIR"/*.{apk,txt}
done

# Summary file
SUMMARY="$OUTPUT_DIR/summary.txt"
{
  echo "==== $EMULATOR_NAME SUMMARY ===="
  echo "Total Apps: $total_apps"
  echo "Instrumented Successfully: $instrumented_successful"
  echo "Healthy After Instrumentation: $healthy_after_instr"
  echo "CSV: $CSV_FILE"
} > "$SUMMARY"
