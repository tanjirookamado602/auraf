import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:auraf/auraf_telemetry.dart';
import 'package:auraf_benchmark_harness/src/benchmark/benchmark_config.dart';
import 'package:auraf_benchmark_harness/src/benchmark/benchmark_runner.dart';
import 'package:auraf_benchmark_harness/src/benchmark/inference_backends.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'fakes.dart';

BenchmarkRecord record(String id, {int ts = 1, String placement = 'device'}) => BenchmarkRecord(
      runId: id,
      timestamp: ts,
      deviceModel: 'Test_Phone',
      networkCondition: 'stable',
      contextBudget: 512,
      placement: placement,
      ttftMs: 10,
      totalLatencyMs: 100,
      tokensPerSec: 20,
      energyMah: 0.1,
      peakMemoryMb: 200,
      tempCelsius: 31,
      costUsd: 0,
      qualityScore: 0.85,
      constraintViolated: false,
    );

void main() {
  sqfliteFfiInit();
  TelemetryDatabase memoryDb() =>
      TelemetryDatabase(databasePath: inMemoryDatabasePath, factory: databaseFactoryFfi);

  group('TelemetryDatabase', () {
    test('logs a run with its samples atomically and reads it back', () async {
      final db = memoryDb();
      await db.logRun(record('a'), samples: [sampleAt(0), sampleAt(100)]);
      expect(await db.recordCount(), 1);
      expect(await db.sampleCount(), 2);
      expect((await db.records()).single, record('a'));
      await db.close();
    });

    test('exports CSV with the exact contract header', () async {
      final db = memoryDb();
      await db.logRun(record('b', ts: 2));
      await db.logRun(record('a', ts: 1));
      final lines = const LineSplitter().convert(await db.recordsCsv());
      expect(lines.first, BenchmarkRecord.csvHeader);
      expect(lines, hasLength(3));
      expect(lines[1], startsWith('a,1,'), reason: 'ordered by timestamp');
      expect(BenchmarkRecord.fromCsvRow(lines[1]).runId, 'a');

      final samples = await db.samplesCsv();
      expect(samples.split('\n').first, TelemetryDatabase.samplesCsvHeader);
      await db.close();
    });

    test('live samples, clear()', () async {
      final db = memoryDb();
      await db.logSamples([sampleAt(0)], runId: 'live');
      await db.logRun(record('x'));
      await db.clear();
      expect(await db.recordCount(), 0);
      expect(await db.sampleCount(), 0);
      await db.close();
    });

    test('upgrades a v1 database (records table only) to v2', () async {
      final dir = await Directory.systemTemp.createTemp('auraf_db');
      final file = '${dir.path}/old.db';
      final v1 = await databaseFactoryFfi.openDatabase(file,
          options: OpenDatabaseOptions(
            version: 1,
            onCreate: (d, _) => d.execute(
                'CREATE TABLE benchmark_records (run_id TEXT PRIMARY KEY, timestamp INTEGER NOT NULL, '
                'device_model TEXT NOT NULL, network_condition TEXT NOT NULL, context_budget INTEGER NOT NULL, '
                'placement TEXT NOT NULL, ttft_ms REAL NOT NULL, total_latency_ms REAL NOT NULL, '
                'tokens_per_sec REAL NOT NULL, energy_mah REAL NOT NULL, peak_memory_mb REAL NOT NULL, '
                'temp_celsius REAL NOT NULL, cost_usd REAL NOT NULL, quality_score REAL NOT NULL, '
                'constraint_violated INTEGER NOT NULL)'),
          ));
      await v1.close();
      final db = TelemetryDatabase(databasePath: file, factory: databaseFactoryFfi);
      await db.logRun(record('u'), samples: [sampleAt(0)]);
      expect(await db.sampleCount(), 1);
      await db.close();
      await dir.delete(recursive: true);
    });
  });

  group('Inference backends', () {
    test('offline cloud requests fail after the timeout', () async {
      final r = await SimulatedCloudBackend(
        network: NetworkProfile.of(NetworkCondition.offline),
        random: math.Random(1),
        offlineTimeoutMs: 20,
      ).generate(prompt: 'p', contextTokens: 512, outputTokens: 8);
      expect(r.succeeded, isFalse);
      expect(r.totalLatencyMs, greaterThanOrEqualTo(20));
      expect(r.tokensPerSec, 0);
    });

    test('high-latency TTFT includes at least two round trips', () async {
      final r = await SimulatedCloudBackend(
        network: NetworkProfile.of(NetworkCondition.highLatency),
        random: math.Random(1),
        offlineTimeoutMs: 20,
      ).generate(prompt: 'p', contextTokens: 512, outputTokens: 4);
      expect(r.succeeded, isTrue);
      expect(r.ttftMs, greaterThanOrEqualTo(400));
      expect(r.outputTokens, 4);
    });

    test('device backend streams a first token before finishing', () async {
      final r = await SimulatedDeviceBackend(workScale: 0.05)
          .generate(prompt: 'p', contextTokens: 512, outputTokens: 8);
      expect(r.succeeded, isTrue);
      expect(r.outputTokens, 8);
      expect(r.ttftMs, lessThanOrEqualTo(r.totalLatencyMs));
    });

    test('decode throughput follows the protocol formula', () {
      const r = InferenceResult(ttftMs: 100, totalLatencyMs: 1100, outputTokens: 11, succeeded: true);
      expect(r.tokensPerSec, closeTo(10, 1e-9)); // (11-1) tokens / 1 s
    });
  });

  test('BenchmarkRunner completes a full matrix and logs every run', () async {
    final db = memoryDb();
    final runner = BenchmarkRunner(
      collector: DeviceStateCollector(source: FakeTelemetrySource()),
      database: db,
      prompts: BenchmarkPrompt.parseList(
        File('../packages/auraf/assets/prompts.json').readAsStringSync(),
      ),
      config: const BenchmarkConfig(
        repetitions: 1,
        maxOutputTokens: 4,
        offlineTimeoutMs: 10,
        interRunGap: Duration.zero,
        deviceWorkScale: 0.01,
      ),
    );
    await runner.run();

    expect(runner.phase, RunnerPhase.done, reason: runner.error);
    expect(runner.completed, 24);
    expect(await db.recordCount(), 24);
    final records = await db.records();
    final offlineCloud = records.where((r) => r.networkCondition == 'offline' && r.placement == 'cloud');
    expect(offlineCloud, hasLength(3));
    expect(offlineCloud.every((r) => r.constraintViolated && r.qualityScore == 0), isTrue);
    expect(records.where((r) => r.placement == 'device').every((r) => r.costUsd == 0), isTrue);
    expect(records.map((r) => r.runId).toSet(), hasLength(24));

    final summary = runner.summaryJson();
    expect(summary['failed_requests'], 3);
    expect(summary['runs_completed'], 24);
    await db.close();
  });
}
