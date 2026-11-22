# AURAF Benchmark Harness (Milestone 2)

**Owner:** Muhammad Hammas Rasheed (23-CS-98). This covers proposal tasks 5, 11 and 12: the State Collector and logging, unit tests, and the automated benchmark harness.

The milestone asks for three things:

* the State Collector module (which later becomes part of `auraf`);
* SQLite logging;
* one command that runs a scripted benchmark on a phone and writes the results to a CSV file.

This folder is the Flutter app that demonstrates all three. It runs on a physical Android phone and on the Android emulator.

## What is where

| Piece | Location |
| :--- | :--- |
| Native sampler (battery, current, charge counter, temperature, thermal status, RAM, process RSS, network) | `packages/auraf/android/.../StateCollectorSampler.kt` (`StateCollectorPlugin`, channel `com.auraf/state_collector`) |
| State Collector (Dart) | `packages/auraf/lib/src/collector/device_state_collector.dart` |
| 10 Hz run recorder, energy integration, thermal cool-down | `packages/auraf/lib/src/collector/run_telemetry_recorder.dart` |
| SQLite logger and CSV export | `packages/auraf/lib/src/logging/telemetry_database.dart` |
| Public entry point | `package:auraf/auraf_telemetry.dart` |
| Harness app (Live / Benchmark / Results tabs) | `benchmark_harness/lib/` |
| Unit tests (host) | `benchmark_harness/test/` |
| Automated on-device benchmark | `benchmark_harness/integration_test/m2_benchmark_test.dart` |
| One-command runner | `scripts/run_m2_benchmark.sh` |

The collector uses Assad's shared models (`DeviceState`, `BenchmarkRecord`, `BenchmarkPrompt`) unchanged. The benchmark prompts come from `packages/auraf/assets/prompts.json`.

## Run the app

```bash
flutter emulators --launch Pixel_4a     # or plug in a phone with USB debugging
cd benchmark_harness
flutter run
```

The app has three tabs:

* **Live** shows the State Collector at 1 Hz, with sparklines. A switch logs each reading to SQLite.
* **Benchmark** lets you pick the matrix (network × context × placement × repetitions). Press **Run benchmark** to watch each run finish.
* **Results** shows the SQLite log averaged per matrix cell. **Export CSV** writes the CSV to `/sdcard/Android/data/com.auraf.benchmark/files/`.

## One-command benchmark

```bash
./scripts/run_m2_benchmark.sh                      # 5 repetitions = 120 runs (protocol default)
./scripts/run_m2_benchmark.sh --reps 1             # quick demo, 24 runs
./scripts/run_m2_benchmark.sh --emulator Pixel_4a  # boots the AVD first if nothing is connected
```

The script installs the app and drives its UI. The test switches to the Benchmark tab, presses Run, waits for the matrix to finish, and checks the SQLite log. The output files come back to this computer through `flutter drive` (no `adb run-as`, which fails on some phones):

| File | Content |
| :--- | :--- |
| `results/m2_benchmark_results.csv` | Contract CSV: the 15 columns from `docs/SHARED_DATA_CONTRACT.md` §5, one row per run |
| `results/m2_device_state_samples.csv` | Every State Collector reading taken during the runs |
| `results/m2_run_summary.json` | Device, violations, collector overhead, energy source, config |
| `results/auraf_telemetry.db` | The SQLite database from the phone |

The script fails if any of these checks fails:

* the CSV header differs from the contract;
* the row count is not 24 × reps;
* any row does not have 15 columns.

## How each column is measured

| Column | How |
| :--- | :--- |
| `ttft_ms`, `total_latency_ms` | Wall clock on the UI isolate, from dispatch to the first token and to the last token |
| `tokens_per_sec` | (N − 1) / (t_eos − t_first), protocol §2.A.3 |
| `energy_mah` | Trapezoidal integral of \|I_batt\| at 10 Hz, protocol §2.B.1. If the current sensor is missing, the charge-counter drop is used. If neither exists (emulator), the value is 0 and `m2_run_summary.json` says so. |
| `peak_memory_mb` | Highest process RSS seen during the run |
| `temp_celsius` | Highest battery temperature seen during the run |
| `cost_usd` | Input and output tokens × the price table in `BenchmarkConfig`; 0 for on-device runs |
| `constraint_violated` | Any of: request failed, latency > T_SLA (5 s), energy > E_max (5 mAh), temperature > Θ_crit (42 °C), or cloud budget exceeded |

Before each run the harness waits until the device is at or below 35 °C (the protocol §3 cool-down). Repetitions are the outer loop, so slow drift in battery and heat is spread over every cell.

**Collector overhead:** the summary reports the mean platform-channel round trip, and the share of each run spent waiting on the collector. The target is under 10 % (protocol §2.D).

## What is simulated in M2

The cloud models and on-device runtimes are chosen in M3, so M2 uses placeholder backends that share the interface the real ones will use (`InferenceBackend`):

* **Cloud.** Real wall-clock waits drawn from the protocol's network table:
  * stable: 20–50 ms RTT;
  * high latency: 200–500 ms RTT;
  * intermittent: 100–800 ms RTT with 10 % loss and retransmission stalls;
  * offline: unreachable, so the request fails after a 2 s timeout.
* **Device.** Real floating-point work on a background isolate: prefill scales with the context size, and each generated token includes an attention term. Because the work is real, a phone's CPU, battery current and temperature respond to it.
* **`quality_score`.** A fixed placeholder for M2: 0.95 for cloud, 0.85 for device, and 0 when a request fails. Real scoring needs real model output (M3/M4).

The `network_condition` column holds the emulated matrix level. The network the phone actually has is logged separately in `device_state_samples`.

**Emulator limits:** the emulator's battery is virtual. It reports a constant current (for example −900 mA) and a fixed 25 °C, so on an emulator `energy_mah` only reflects run duration and the temperature never changes. Latency, throughput, memory and the whole pipeline are measured normally. Energy and thermal figures for the report need a physical phone.

**Collector overhead on the emulator:** in a debug build on the emulator, one collector call took about 44 ms on average, so the collector-wait share came out at about 26 %, above the 10 % target. That figure counts every millisecond spent waiting on the platform channel, so it is an upper bound and not CPU time. Re-measure it on a physical phone in profile mode (`flutter run --profile`) before quoting it.

## Unit tests

```bash
cd benchmark_harness && flutter test
```

These cover:

* collector parsing, and the error paths (it never substitutes made-up values);
* `watch()` streaming;
* energy integration, including the trapezoid rule and the charge-counter fallback;
* the run recorder and the thermal cool-down;
* the SQLite log (an atomic run-plus-samples write, CSV header and order, the v1 → v2 schema upgrade);
* the network and device backends;
* a full 24-run matrix against an in-memory database.
