import 'dart:async';
import 'dart:math' as math;

import 'package:auraf/auraf_telemetry.dart';
import 'package:flutter/foundation.dart';

import 'benchmark_config.dart';
import 'inference_backends.dart';

/// Quality priors used until M3/M4 add real models and an answer judge.
/// They are constants on purpose: M2 validates the harness, not model quality.
const double kCloudQualityPrior = 0.95;
const double kDeviceQualityPrior = 0.85;

enum RunnerPhase { idle, running, cancelling, done, failed }

/// One finished matrix cell repetition.
class RunResult {
  const RunResult({
    required this.record,
    required this.telemetry,
    required this.promptId,
    required this.repetition,
    this.failureReason,
  });

  final BenchmarkRecord record;
  final RunTelemetrySummary telemetry;
  final String promptId;
  final int repetition;
  final String? failureReason;
}

/// Drives the 4 network x 3 context x 2 placement x N repetition matrix.
class BenchmarkRunner extends ChangeNotifier {
  BenchmarkRunner({
    required this.collector,
    required this.database,
    required this.prompts,
    BenchmarkConfig? config,
  }) : config = config ?? BenchmarkConfig.fromEnvironment();

  final DeviceStateCollector collector;
  final TelemetryDatabase database;
  final List<BenchmarkPrompt> prompts;
  BenchmarkConfig config;

  RunnerPhase phase = RunnerPhase.idle;
  int completed = 0;
  String status = 'Ready';
  String? currentCell;
  String? error;
  String? deviceModel;
  bool isEmulator = false;
  Duration elapsed = Duration.zero;
  final List<RunResult> results = <RunResult>[];

  bool get isRunning => phase == RunnerPhase.running || phase == RunnerPhase.cancelling;
  int get total => config.totalRuns;
  double get progress => total == 0 ? 0 : completed / total;

  void updateConfig(BenchmarkConfig next) {
    if (isRunning) return;
    config = next;
    notifyListeners();
  }

  void cancel() {
    if (phase == RunnerPhase.running) {
      phase = RunnerPhase.cancelling;
      status = 'Cancelling after the current run...';
      notifyListeners();
    }
  }

  BenchmarkPrompt _promptFor(int budget) {
    final tier = BenchmarkPrompt.filterByTokens(prompts, budget);
    final split = BenchmarkPrompt.filterBySplit(tier, config.promptSplit);
    final pool = split.isNotEmpty ? split : tier;
    if (pool.isEmpty) {
      throw StateError('No benchmark prompt for the $budget-token tier');
    }
    return pool.first;
  }

  static String _uuidV4(math.Random rng) {
    final b = List<int>.generate(16, (_) => rng.nextInt(256));
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    final hex = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  /// Runs the full matrix. Resolves when finished, cancelled or failed.
  Future<void> run() async {
    if (isRunning) return;
    phase = RunnerPhase.running;
    completed = 0;
    error = null;
    results.clear();
    status = 'Preparing...';
    notifyListeners();

    final clock = Stopwatch()..start();
    final ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      elapsed = clock.elapsed;
      notifyListeners();
    });
    try {
      final device = await collector.describeDevice();
      deviceModel = device.deviceModel;
      isEmulator = device.isEmulator;

      final rng = math.Random(config.seed);
      final ids = math.Random.secure();
      final cooldown = ThermalCooldown(
        collector,
        thresholdCelsius: config.cooldownThresholdCelsius,
        maxWait: config.cooldownMaxWait,
      );
      var spentUsd = 0.0;

      // Repetitions form the outer loop so slow drift (battery, heat) is
      // spread across all cells instead of biasing the last ones.
      outer:
      for (var rep = 1; rep <= config.repetitions; rep++) {
        for (final network in config.networks) {
          for (final budget in config.contextBudgets) {
            for (final placement in config.placements) {
              if (phase == RunnerPhase.cancelling) break outer;
              currentCell = '${network.wireName} · ${budget}t · '
                  '${placement.wireName} · rep $rep/${config.repetitions}';

              final cool = await cooldown.waitUntilCool(
                isCancelled: () => phase == RunnerPhase.cancelling,
                onWaiting: (t, w) {
                  status = 'Cooling down: ${t.toStringAsFixed(1)} °C '
                      '(${w.inSeconds}s)';
                  notifyListeners();
                },
              );
              if (cool.timedOut) {
                debugPrint('cool-down timed out at ${cool.finalTempCelsius} °C');
              }
              status = 'Running';
              notifyListeners();

              final result = await _runOne(
                network: network,
                budget: budget,
                placement: placement,
                repetition: rep,
                runId: _uuidV4(ids),
                rng: rng,
                remainingBudgetUsd: math.max(0, config.cloudBudgetUsd - spentUsd),
              );
              spentUsd += result.record.costUsd;
              results.add(result);
              completed++;
              notifyListeners();
              await Future<void>.delayed(config.interRunGap);
            }
          }
        }
      }
      phase = phase == RunnerPhase.cancelling ? RunnerPhase.idle : RunnerPhase.done;
      status = phase == RunnerPhase.done
          ? 'Finished $completed runs'
          : 'Cancelled after $completed runs';
    } catch (e, st) {
      debugPrint('benchmark failed: $e\n$st');
      phase = RunnerPhase.failed;
      error = e.toString();
      status = 'Failed';
    } finally {
      ticker.cancel();
      elapsed = clock.elapsed;
      currentCell = null;
      notifyListeners();
    }
  }

  Future<RunResult> _runOne({
    required NetworkCondition network,
    required int budget,
    required Placement placement,
    required int repetition,
    required String runId,
    required math.Random rng,
    required double remainingBudgetUsd,
  }) async {
    final prompt = _promptFor(budget);
    final outputTokens = math.min(prompt.expectedResponseTokens, config.maxOutputTokens);
    final InferenceBackend backend = switch (placement) {
      Placement.cloud => SimulatedCloudBackend(
          network: NetworkProfile.of(network),
          random: rng,
          offlineTimeoutMs: config.offlineTimeoutMs,
        ),
      Placement.device => SimulatedDeviceBackend(workScale: config.deviceWorkScale),
    };

    final recorder = RunTelemetryRecorder(collector);
    final startedAt = DateTime.now().millisecondsSinceEpoch;
    await recorder.start();
    late final InferenceResult inference;
    late final RunTelemetrySummary telemetry;
    try {
      inference = await backend.generate(
        prompt: prompt.prompt,
        contextTokens: budget,
        outputTokens: outputTokens,
      );
    } finally {
      // Always stop the sampling timer, even if the backend throws.
      telemetry = await recorder.stop();
    }

    final cost = placement == Placement.cloud && inference.succeeded
        ? budget * config.cloudInputUsdPerMTok / 1e6 +
            inference.outputTokens * config.cloudOutputUsdPerMTok / 1e6
        : 0.0;
    final quality = !inference.succeeded
        ? 0.0
        : placement == Placement.cloud
            ? kCloudQualityPrior
            : kDeviceQualityPrior;
    final violated = !inference.succeeded ||
        inference.totalLatencyMs > config.slaMs ||
        telemetry.energyMah > config.energyMaxMah ||
        telemetry.peakTempCelsius > config.thermalCriticalCelsius ||
        cost > remainingBudgetUsd;

    final record = BenchmarkRecord(
      runId: runId,
      timestamp: startedAt,
      deviceModel: deviceModel ?? 'unknown',
      networkCondition: network.wireName,
      contextBudget: budget,
      placement: placement.wireName,
      ttftMs: inference.ttftMs,
      totalLatencyMs: inference.totalLatencyMs,
      tokensPerSec: inference.tokensPerSec,
      energyMah: telemetry.energyMah,
      peakMemoryMb: telemetry.peakMemoryMb,
      tempCelsius: telemetry.peakTempCelsius,
      costUsd: cost,
      qualityScore: quality,
      constraintViolated: violated,
    );
    await database.logRun(
      record,
      samples: telemetry.samples,
      remainingBudgetUsd: remainingBudgetUsd,
    );
    return RunResult(
      record: record,
      telemetry: telemetry,
      promptId: prompt.id,
      repetition: repetition,
      failureReason: inference.failureReason,
    );
  }

  /// Aggregate figures for the run report.
  Map<String, Object?> summaryJson() {
    double mean(Iterable<double> xs) =>
        xs.isEmpty ? 0 : xs.reduce((a, b) => a + b) / xs.length;
    final t = results.map((r) => r.telemetry);
    return <String, Object?>{
      'device_model': deviceModel,
      'is_emulator': isEmulator,
      'phase': phase.name,
      'runs_completed': completed,
      'runs_expected': total,
      'elapsed_seconds': elapsed.inMilliseconds / 1000.0,
      'constraint_violations':
          results.where((r) => r.record.constraintViolated).length,
      'failed_requests': results.where((r) => r.failureReason != null).length,
      'telemetry_samples': t.fold<int>(0, (a, s) => a + s.samples.length),
      'telemetry_failed_samples': t.fold<int>(0, (a, s) => a + s.failedSamples),
      'mean_sample_latency_ms': mean(t.map((s) => s.meanSampleLatencyMs)),
      'mean_collector_overhead_fraction': mean(t.map((s) => s.collectorBusyFraction)),
      'energy_sources': {
        for (final src in EnergySource.values)
          src.name: t.where((s) => s.energySource == src).length,
      },
      'charging_during_runs': t.where((s) => s.chargingDuringRun).length,
      'config': config.toJson(),
    };
  }
}
