import 'dart:convert';
import 'dart:io';

import 'package:auraf/auraf_telemetry.dart';
import 'package:auraf_benchmark_harness/src/benchmark/benchmark_config.dart';
import 'package:auraf_benchmark_harness/src/benchmark/benchmark_runner.dart';
import 'package:auraf_benchmark_harness/src/harness_services.dart';
import 'package:auraf_benchmark_harness/src/ui/harness_app.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// M2 automated benchmark: drives the real app UI on a phone or emulator,
/// runs the full matrix, verifies the SQLite log, and hands the CSV/SQLite
/// files to the host via `reportData` (written by test_driver/).
///
/// Run with `scripts/run_m2_benchmark.sh`, or directly:
///   flutter drive --driver=test_driver/integration_test.dart \
///     --target=integration_test/m2_benchmark_test.dart --dart-define=AURAF_REPS=1
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('M2 benchmark matrix (network x context x placement x reps)',
      (tester) async {
    final config = BenchmarkConfig.fromEnvironment();
    final database = TelemetryDatabase();
    await database.clear(); // Each scripted run starts from an empty log.
    final services = await HarnessServices.create(database: database, config: config);
    final runner = services.runner;

    // Telemetry must be live on the device: no fabricated fallback values.
    final probe = await services.collector.sample();
    expect(probe.availableRamMb, greaterThan(0));
    expect(probe.batteryLevelPercent, inInclusiveRange(0, 100));

    await tester.pumpWidget(HarnessApp(services: services));
    await tester.pump(const Duration(milliseconds: 500));

    // Visible in the demo: switch to the Benchmark tab and press Run.
    await tester.tap(find.byKey(const Key('nav-benchmark')));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.byKey(const Key('start-benchmark')));
    await tester.pump();

    final deadline = DateTime.now().add(Duration(seconds: 30 + config.totalRuns * 20));
    while (runner.isRunning || runner.phase == RunnerPhase.idle) {
      if (DateTime.now().isAfter(deadline)) fail('benchmark timed out');
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await tester.pump();
    }

    expect(runner.phase, RunnerPhase.done, reason: runner.error);
    expect(runner.completed, config.totalRuns);
    expect(await database.recordCount(), config.totalRuns);

    final records = await database.records();
    for (final r in records) {
      expect(r.totalLatencyMs, greaterThan(0));
      expect(r.ttftMs, lessThanOrEqualTo(r.totalLatencyMs));
      expect(r.peakMemoryMb, greaterThan(0));
      expect(r.qualityScore, inInclusiveRange(0, 1));
      if (r.placement == 'device') expect(r.costUsd, 0);
      if (r.placement == 'cloud' && r.networkCondition == 'offline') {
        expect(r.constraintViolated, isTrue);
      }
    }
    // >= 2 samples per run (baseline + final) at the 10 Hz protocol rate.
    expect(await database.sampleCount(), greaterThanOrEqualTo(config.totalRuns * 2));

    final csv = await database.recordsCsv();
    expect(csv.split('\n').first, BenchmarkRecord.csvHeader);

    // Show the results screen at the end of the demo run.
    await tester.tap(find.byKey(const Key('nav-results')));
    await tester.pump(const Duration(seconds: 1));

    final summary = runner.summaryJson();
    await database.close();
    final sqliteBytes = await File(database.path!).readAsBytes();
    binding.reportData = <String, Object?>{
      'records_csv': csv,
      'samples_csv': await TelemetryDatabase(databasePath: database.path).samplesCsv(),
      'summary_json': const JsonEncoder.withIndent('  ').convert(summary),
      'sqlite_base64': base64Encode(sqliteBytes),
    };
    await tester.pump(const Duration(seconds: 2));
  }, timeout: Timeout.none);
}
