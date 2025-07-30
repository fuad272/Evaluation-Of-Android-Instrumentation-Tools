#!/bin/bash

CATEGORIES=("small" "medium" "large" "popular")
BASE_INPUT="/home/fuad/apks_split"
BASE_OUTPUT="/home/fuad/results/wallmauer"
BASE_LOG="/home/fuad/logs/wallmauer"

# ----------------- emulator watchdog -----------------
monitor_emulators() {
  sleep 180
  while true; do
    for i in {0..19}; do
      PORT=$((5556 + i*2))
      EMU_ID="emulator-${PORT}"
      AVD="Rooted_API30_$((i+1))"
      STATE=$(adb -s "$EMU_ID" get-state 2>/dev/null || echo offline)
      if [[ "$STATE" != "device" ]]; then
        echo "$(date '+%F %T') - [$EMU_ID] not healthy ($STATE). Restarting..."
        adb -s "$EMU_ID" emu kill >/dev/null 2>&1
        sleep 5
        emulator -avd "$AVD" -port "$PORT" \
          -no-window -no-audio -memory 2048 \
          -wipe-data -no-snapshot-load -no-snapshot-save \
          >/dev/null 2>&1 &
      fi
    done
    sleep 180
  done
}

monitor_emulators & 
WATCHDOG_PID=$!
echo "Emulator watchdog started (PID $WATCHDOG_PID)"

# ----------------- fan-out workers -----------------
for CATEGORY in "${CATEGORIES[@]}"; do
  echo "=== Starting category: $CATEGORY ==="
  declare -a PIDS=()

  for i in {0..19}; do
    idx=$(printf "%02d" $i)
    INPUT_DIR="$BASE_INPUT/$CATEGORY/batch_${idx}.dir"
    OUTPUT_DIR="$BASE_OUTPUT/$CATEGORY/run_${idx}"
    LOG_FILE="$BASE_LOG/$CATEGORY/run_${idx}.log"
    EMULATOR_NAME="Rooted_API30_$((i+1))"
    PORT=$((5556 + i*2))

    mkdir -p "$(dirname "$LOG_FILE")" "$OUTPUT_DIR"
    nohup ./run_wallmauer_parallel.sh \
      "$INPUT_DIR" "$OUTPUT_DIR" "$EMULATOR_NAME" "$PORT" \
      > "$LOG_FILE" 2>&1 &
    PIDS+=($!)
  done

  echo "Waiting for all 20 $CATEGORY jobs to finish..."
  for pid in "${PIDS[@]}"; do
    wait "$pid"
  done
  echo "Category $CATEGORY completed."
done

kill "$WATCHDOG_PID"
echo "Emulator watchdog stopped."
