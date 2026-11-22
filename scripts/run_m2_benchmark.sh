#!/usr/bin/env bash
# AURAF Milestone 2: one-command automated benchmark.
#
# Launches the harness app on a connected Android phone or emulator, runs the
# network x context x placement x repetition matrix, and writes the results to
# results/ on this computer:
#   m2_benchmark_results.csv      contract CSV (15 columns, one row per run)
#   m2_device_state_samples.csv   every 10 Hz State Collector reading
#   m2_run_summary.json           overhead, violations, energy source, config
#   auraf_telemetry.db            the SQLite database pulled from the device
#
# Usage: scripts/run_m2_benchmark.sh [--reps N] [--device SERIAL] [--emulator AVD]
#                                    [--cooldown CELSIUS] [--seed N]
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESULTS_DIR="${ROOT_DIR}/results"
RESULT_FILE="${RESULTS_DIR}/m2_benchmark_results.csv"
REPS=5
COOLDOWN=35
SEED=42
DEVICE="${ANDROID_SERIAL:-}"
AVD=""

usage() { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --reps) REPS="$2"; shift 2 ;;
    --device|-d) DEVICE="$2"; shift 2 ;;
    --emulator) AVD="$2"; shift 2 ;;
    --cooldown) COOLDOWN="$2"; shift 2 ;;
    --seed) SEED="$2"; shift 2 ;;
    -h|--help) usage 0 ;;
    *) echo "error: unknown option $1" >&2; usage 1 ;;
  esac
done
[[ "${REPS}" =~ ^[1-9][0-9]*$ ]] || { echo "error: --reps must be a positive integer" >&2; exit 1; }

# adb ships with the Android SDK but is often not on PATH.
SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Android/Sdk}}"
export PATH="${SDK}/platform-tools:${SDK}/emulator:${PATH}"
command -v adb >/dev/null || { echo "error: adb not found (set ANDROID_HOME)" >&2; exit 1; }
command -v flutter >/dev/null || { echo "error: flutter not found in PATH" >&2; exit 1; }

ready_devices() { adb devices | awk 'NR > 1 && $2 == "device" {print $1}'; }

if [[ -n "${AVD}" ]] && [[ -z "$(ready_devices)" ]]; then
  echo "==> Booting emulator ${AVD}"
  nohup emulator -avd "${AVD}" -no-snapshot-save -no-audio >/dev/null 2>&1 &
  adb wait-for-device
  until [[ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == "1" ]]; do sleep 2; done
fi

mapfile -t DEVICES < <(ready_devices)
if [[ -z "${DEVICE}" ]]; then
  if [[ "${#DEVICES[@]}" -eq 0 ]]; then
    echo "error: no Android device or emulator is ready (adb devices)." >&2
    echo "       Plug in a phone with USB debugging, or pass --emulator <AVD> (see: flutter emulators)." >&2
    exit 1
  elif [[ "${#DEVICES[@]}" -gt 1 ]]; then
    echo "error: several devices are connected (${DEVICES[*]}); choose one with --device SERIAL" >&2
    exit 1
  fi
  DEVICE="${DEVICES[0]}"
fi
export ANDROID_SERIAL="${DEVICE}"

EXPECTED_ROWS=$((24 * REPS))
MODEL="$(adb shell getprop ro.product.model | tr -d '\r')"
echo "==> Device ${DEVICE} (${MODEL}) · ${REPS} repetition(s) · ${EXPECTED_ROWS} runs"

mkdir -p "${RESULTS_DIR}"
rm -f "${RESULTS_DIR}"/m2_benchmark_results.csv "${RESULTS_DIR}"/m2_device_state_samples.csv \
      "${RESULTS_DIR}"/m2_run_summary.json "${RESULTS_DIR}"/auraf_telemetry.db

cd "${ROOT_DIR}/benchmark_harness"
flutter pub get >/dev/null
AURAF_RESULTS_DIR="${RESULTS_DIR}" flutter drive \
  -d "${DEVICE}" \
  --driver=test_driver/integration_test.dart \
  --target=integration_test/m2_benchmark_test.dart \
  --dart-define=AURAF_REPS="${REPS}" \
  --dart-define=AURAF_COOLDOWN_C="${COOLDOWN}" \
  --dart-define=AURAF_SEED="${SEED}"

# ---- Validate the exported CSV against the shared data contract ----------
[[ -f "${RESULT_FILE}" ]] || { echo "error: benchmark did not produce ${RESULT_FILE}" >&2; exit 1; }
EXPECTED_HEADER='run_id,timestamp,device_model,network_condition,context_budget,placement,ttft_ms,total_latency_ms,tokens_per_sec,energy_mah,peak_memory_mb,temp_celsius,cost_usd,quality_score,constraint_violated'
[[ "$(head -n 1 "${RESULT_FILE}")" == "${EXPECTED_HEADER}" ]] ||
  { echo "error: CSV header does not match docs/SHARED_DATA_CONTRACT.md" >&2; exit 1; }

row_count="$(tail -n +2 "${RESULT_FILE}" | sed '/^[[:space:]]*$/d' | wc -l)"
[[ "${row_count}" -eq "${EXPECTED_ROWS}" ]] ||
  { echo "error: expected ${EXPECTED_ROWS} rows, found ${row_count}" >&2; exit 1; }

bad_cols="$(tail -n +2 "${RESULT_FILE}" | awk -F, 'NF && NF != 15' | wc -l)"
[[ "${bad_cols}" -eq 0 ]] || { echo "error: ${bad_cols} rows do not have 15 columns" >&2; exit 1; }

echo
echo "==> Mean per cell (network, context, placement)"
tail -n +2 "${RESULT_FILE}" | awk -F, '
  { k=$4" "$5" "$6; n[k]++; ttft[k]+=$7; tot[k]+=$8; e[k]+=$10; v[k]+=$15 }
  END {
    printf "%-13s %5s %-7s %3s %9s %9s %8s %5s\n", "network","ctx","place","n","ttft_ms","total_ms","mAh","viol"
    for (k in n) { split(k, a, " ");
      printf "%-13s %5s %-7s %3d %9.1f %9.1f %8.3f %5d\n", a[1], a[2], a[3], n[k], ttft[k]/n[k], tot[k]/n[k], e[k]/n[k], v[k] }
  }' | sort -k1,1 -k2,2n -k3,3

echo
echo "M2 benchmark complete: ${row_count} records validated"
for f in m2_benchmark_results.csv m2_device_state_samples.csv m2_run_summary.json auraf_telemetry.db; do
  [[ -f "${RESULTS_DIR}/${f}" ]] && echo "  results/${f}"
done
