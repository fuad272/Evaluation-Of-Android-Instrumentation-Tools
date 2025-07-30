#!/usr/bin/env bash
#
#  split_apks_evenly_20.sh
#
#  Evenly distributes APKs from each category into 20 directories.
#  All copies go to: /home/fuad/apks_split/{small,medium,large,popular}/batch_XX.dir
#

# Optional debug mode
[[ "$1" == "--debug" ]] && set -x
set -uo pipefail

# Configuration
SRC_BASE="/home/fuad/apks"
DST_BASE="/home/fuad/apks_split"
NUM_BATCHES=20
ERROR_LOG="$DST_BASE/copy_errors.log"
> "$ERROR_LOG"  # clear previous log

# Category mapping
declare -A MAP=(
  [healthSmallApks]=small
  [healthMediumApks]=medium
  [healthyLargeApks]=large
  [healthyPopularApks]=popular
)

echo "Re-creating $DST_BASE ..."
rm -rf "$DST_BASE"
mkdir -p "$DST_BASE"

for SRC_DIR_NAME in "${!MAP[@]}"; do
  CATEGORY="${MAP[$SRC_DIR_NAME]}"
  SRC_DIR="$SRC_BASE/$SRC_DIR_NAME"
  OUT_DIR="$DST_BASE/$CATEGORY"

  echo -e "Processing \e[1m$SRC_DIR_NAME\e[0m → $OUT_DIR"
  mkdir -p "$OUT_DIR"

  # Collect all APK paths safely
  mapfile -d '' -t APKS < <(find "$SRC_DIR" -type f -name '*.apk' -print0 | sort -z)
  TOTAL=${#APKS[@]}
  echo " Found $TOTAL APKs."

  if (( TOTAL == 0 )); then
    echo " No APKs found in $SRC_DIR. Skipping."
    continue
  fi

  # Compute even distribution
  PER_BATCH=$(( TOTAL / NUM_BATCHES ))
  REMAINDER=$(( TOTAL % NUM_BATCHES ))

  index=0
  for i in $(seq 0 $((NUM_BATCHES - 1))); do
    count=$PER_BATCH
    (( i < REMAINDER )) && ((count++))  # distribute remainder

    batch_dir="$OUT_DIR/batch_$(printf '%02d' "$i").dir"
    mkdir -p "$batch_dir"

    for ((j = 0; j < count; j++)); do
      if [[ -e "${APKS[$index]}" ]]; then
        cp -n "${APKS[$index]}" "$batch_dir/" 2>>"$ERROR_LOG" || {
          echo "❌ Failed to copy: ${APKS[$index]}" >> "$ERROR_LOG"
        }
        ((index++))
      fi
    done

    echo "$(basename "$batch_dir") → $count APKs"
  done
done

echo -e "Done. APKs copied into 20 even batches per category."

if [[ -s "$ERROR_LOG" ]]; then
  echo " Some copy errors occurred. Check log: $ERROR_LOG"
fi

