/// AURAF State Collector and SQLite telemetry logging (Milestone 2).
///
/// Separate entry point from `auraf.dart` so the collector/logging layer can
/// be imported on its own (e.g. by the benchmark harness).
library auraf_telemetry;

export 'src/collector/device_state_collector.dart';
export 'src/collector/run_telemetry_recorder.dart';
export 'src/collector/telemetry_sample.dart';
export 'src/logging/telemetry_database.dart';
export 'src/models/benchmark_prompt.dart';
export 'src/models/benchmark_record.dart';
export 'src/models/device_state.dart';
