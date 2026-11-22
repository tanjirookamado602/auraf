import 'dart:async';
import 'dart:math' as math;

import 'package:meta/meta.dart';

import 'device_state_collector.dart';
import 'telemetry_sample.dart';

/// How [RunTelemetrySummary.energyMah] was obtained.
enum EnergySource {
  /// Trapezoidal integration of |I_batt| over the run window (protocol §2.B.1).
  currentIntegration,

  /// Drop in `BATTERY_PROPERTY_CHARGE_COUNTER` across the run (coarse fallback).
  chargeCounter,

  /// The device exposes neither sensor (e.g. emulator); energy is reported as 0.
  unavailable,
}

/// Aggregated telemetry for one benchmark run window.
@immutable
class RunTelemetrySummary {
  const RunTelemetrySummary({
    required this.samples,
    required this.failedSamples,
    required this.durationMs,
    required this.energyMah,
    required this.energySource,
    required this.peakMemoryMb,
    required this.baselineTempCelsius,
    required this.peakTempCelsius,
    required this.meanSampleLatencyMs,
    required this.collectorBusyFraction,
    required this.chargingDuringRun,
  });

  final List<TelemetrySample> samples;
  final int failedSamples;
  final double durationMs;
  final double energyMah;
  final EnergySource energySource;

  /// Maximum process RSS observed in the window (protocol M_peak).
  final double peakMemoryMb;
  final double baselineTempCelsius;
  final double peakTempCelsius;
  double get thermalDeltaCelsius => peakTempCelsius - baselineTempCelsius;

  /// Mean platform-channel round trip of one collector reading.
  final double meanSampleLatencyMs;

  /// Fraction of the run the main isolate spent waiting on the collector.
  /// Used to check the < 10 % telemetry-overhead target (protocol §2.D).
  final double collectorBusyFraction;

  /// True if the battery was charging at any point: energy is then unreliable.
  final bool chargingDuringRun;
}

/// Energy maths, kept pure so it can be unit tested.
abstract final class EnergyEstimator {
  /// E = (1 / 3.6e6) * ∫ |I(t)| dt, with I in mA and t in ms → mAh.
  static double integrateCurrentMah(List<TelemetrySample> samples) {
    if (samples.length < 2) return 0;
    var total = 0.0;
    for (var i = 1; i < samples.length; i++) {
      final a = samples[i - 1];
      final b = samples[i];
      final dtMs = (b.timestamp - a.timestamp).toDouble();
      if (dtMs <= 0) continue;
      total += (a.batteryCurrentMa.abs() + b.batteryCurrentMa.abs()) / 2 * dtMs;
    }
    return total / 3.6e6;
  }

  /// Charge consumed according to the charge counter (µAh → mAh), or null.
  static double? chargeCounterDeltaMah(List<TelemetrySample> samples) {
    final counters = samples
        .map((s) => s.chargeCounterUah)
        .whereType<int>()
        .toList(growable: false);
    if (counters.length < 2) return null;
    final delta = (counters.first - counters.last) / 1000.0;
    return delta > 0 ? delta : null;
  }

  static (double, EnergySource) estimate(List<TelemetrySample> samples) {
    if (samples.any((s) => s.currentAvailable)) {
      return (integrateCurrentMah(samples), EnergySource.currentIntegration);
    }
    final counter = chargeCounterDeltaMah(samples);
    if (counter != null) return (counter, EnergySource.chargeCounter);
    return (0.0, EnergySource.unavailable);
  }
}

/// Samples the [DeviceStateCollector] at a fixed rate (default 10 Hz, as the
/// measurement protocol requires) between [start] and [stop].
class RunTelemetryRecorder {
  RunTelemetryRecorder(
    this._collector, {
    this.interval = const Duration(milliseconds: 100),
  });

  final DeviceStateCollector _collector;
  final Duration interval;

  final List<TelemetrySample> _samples = <TelemetrySample>[];
  Timer? _timer;
  Future<void>? _inFlight;
  int _failed = 0;
  final Stopwatch _clock = Stopwatch();

  bool get isRecording => _timer != null;

  /// Takes a baseline reading, then starts periodic sampling.
  Future<void> start() async {
    if (isRecording) throw StateError('Recorder already started');
    _samples.clear();
    _failed = 0;
    _clock
      ..reset()
      ..start();
    await _take();
    _timer = Timer.periodic(interval, (_) {
      // Skip a tick rather than queue calls if the previous one is slow.
      _inFlight ??= _take().whenComplete(() => _inFlight = null);
    });
  }

  /// Stops sampling, takes a final reading and summarises the window.
  Future<RunTelemetrySummary> stop() async {
    final timer = _timer;
    if (timer == null) throw StateError('Recorder was not started');
    timer.cancel();
    _timer = null;
    await _inFlight;
    await _take();
    _clock.stop();

    final samples = List<TelemetrySample>.unmodifiable(_samples);
    if (samples.isEmpty) {
      throw TelemetryUnavailableException(
        'No telemetry samples captured during run ($_failed failed)',
      );
    }
    final (energy, source) = EnergyEstimator.estimate(samples);
    final latencies = samples.map((s) => s.sampleLatencyMs);
    final totalLatency = latencies.fold<double>(0, (a, b) => a + b);
    final durationMs = _clock.elapsedMicroseconds / 1000.0;

    return RunTelemetrySummary(
      samples: samples,
      failedSamples: _failed,
      durationMs: durationMs,
      energyMah: energy,
      energySource: source,
      peakMemoryMb: samples.map((s) => s.rssMb).reduce(math.max),
      baselineTempCelsius: samples.first.temperatureCelsius,
      peakTempCelsius: samples.map((s) => s.temperatureCelsius).reduce(math.max),
      meanSampleLatencyMs: totalLatency / samples.length,
      collectorBusyFraction: durationMs > 0 ? totalLatency / durationMs : 0,
      chargingDuringRun: samples.any((s) => s.isCharging),
    );
  }

  Future<void> _take() async {
    try {
      _samples.add(await _collector.sample());
    } on TelemetryUnavailableException {
      _failed++;
    }
  }
}

/// Result of a thermal cool-down wait.
@immutable
class CooldownResult {
  const CooldownResult({
    required this.waited,
    required this.finalTempCelsius,
    required this.timedOut,
  });

  final Duration waited;
  final double finalTempCelsius;
  final bool timedOut;
}

/// Thermal cool-down rule from the measurement protocol (§3): before each
/// repetition, idle until the device is at or below [thresholdCelsius].
class ThermalCooldown {
  const ThermalCooldown(
    this._collector, {
    this.thresholdCelsius = 35.0,
    this.maxWait = const Duration(seconds: 60),
    this.pollInterval = const Duration(seconds: 2),
  });

  final DeviceStateCollector _collector;
  final double thresholdCelsius;
  final Duration maxWait;
  final Duration pollInterval;

  Future<CooldownResult> waitUntilCool({
    void Function(double tempCelsius, Duration waited)? onWaiting,
    bool Function()? isCancelled,
  }) async {
    final clock = Stopwatch()..start();
    while (true) {
      final reading = await _collector.sample();
      final temp = reading.temperatureCelsius;
      if (!reading.temperatureAvailable || temp <= thresholdCelsius) {
        return CooldownResult(
          waited: clock.elapsed,
          finalTempCelsius: temp,
          timedOut: false,
        );
      }
      if (clock.elapsed >= maxWait || (isCancelled?.call() ?? false)) {
        return CooldownResult(
          waited: clock.elapsed,
          finalTempCelsius: temp,
          timedOut: true,
        );
      }
      onWaiting?.call(temp, clock.elapsed);
      await Future<void>.delayed(pollInterval);
    }
  }
}
