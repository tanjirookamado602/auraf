import 'package:auraf/auraf_telemetry.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

void main() {
  group('DeviceStateCollector', () {
    test('parses a native reading and measures call latency', () async {
      final collector = DeviceStateCollector(source: FakeTelemetrySource());
      final s = await collector.sample();
      expect(s.batteryCurrentMa, -400);
      expect(s.networkCondition, NetworkCondition.stable);
      expect(s.peakRssMb, 170);
      expect(s.sampleLatencyMs, greaterThanOrEqualTo(0));
    });

    test('projects onto the shared-contract DeviceState', () async {
      final collector = DeviceStateCollector(
        source: FakeTelemetrySource(reading: () => fakeReading(network: 'high_latency')),
      );
      final state = await collector.sampleDeviceState(
        contextSizeTokens: 2048,
        remainingBudgetUsd: 7.5,
      );
      expect(state.contextSizeTokens, 2048);
      expect(state.remainingBudgetUsd, 7.5);
      expect(state.networkCondition, NetworkCondition.highLatency);
      expect(state.toMap().keys, containsAll(<String>[
        'timestamp', 'battery_level_percent', 'battery_current_ma',
        'temperature_celsius', 'available_ram_mb', 'peak_memory_mb',
        'network_condition', 'context_size_tokens', 'remaining_budget_usd',
      ]));
    });

    test('rejects negative inputs', () {
      final collector = DeviceStateCollector(source: FakeTelemetrySource());
      expect(
        () => collector.sampleDeviceState(contextSizeTokens: -1, remainingBudgetUsd: 1),
        throwsArgumentError,
      );
    });

    test('never fabricates values when the plugin is missing', () async {
      final collector = DeviceStateCollector(
        source: FakeTelemetrySource(error: MissingPluginException('none')),
      );
      expect(collector.sample(), throwsA(isA<TelemetryUnavailableException>()));
    });

    test('reports malformed replies as unavailable', () async {
      final collector = DeviceStateCollector(
        source: FakeTelemetrySource(
          reading: () => fakeReading()..remove('temperature_celsius'),
        ),
      );
      expect(collector.sample(), throwsA(isA<TelemetryUnavailableException>()));
    });

    test('watch() streams readings and forwards errors', () async {
      final source = FakeTelemetrySource();
      final collector = DeviceStateCollector(source: source);
      final first = await collector.watch(interval: const Duration(milliseconds: 10)).first;
      expect(first.batteryLevelPercent, 80);

      source.error = PlatformException(code: 'X');
      await expectLater(
        collector.watch(interval: const Duration(milliseconds: 10)),
        emitsError(isA<TelemetryUnavailableException>()),
      );
    });

    test('describeDevice is cached', () async {
      final collector = DeviceStateCollector(source: FakeTelemetrySource());
      final a = await collector.describeDevice();
      final b = await collector.describeDevice();
      expect(identical(a, b), isTrue);
      expect(a.deviceModel, 'Test_Phone_Android_15');
    });
  });

  group('EnergyEstimator', () {
    test('integrates |I| over time: 360 mA for 10 s = 1 mAh', () {
      final samples = [for (var t = 0; t <= 10000; t += 100) sampleAt(t, currentMa: -360)];
      expect(EnergyEstimator.integrateCurrentMah(samples), closeTo(1.0, 1e-9));
    });

    test('uses the trapezoid rule between unequal readings', () {
      final samples = [sampleAt(0, currentMa: -100), sampleAt(3600, currentMa: -300)];
      // mean 200 mA for 3.6 s = 0.2 mAh
      expect(EnergyEstimator.integrateCurrentMah(samples), closeTo(0.2, 1e-9));
    });

    test('falls back to the charge counter, then to unavailable', () {
      final counter = [
        sampleAt(0, available: false, counter: 3000000),
        sampleAt(1000, available: false, counter: 2999500),
      ];
      final (mah, src) = EnergyEstimator.estimate(counter);
      expect(src, EnergySource.chargeCounter);
      expect(mah, closeTo(0.5, 1e-9));

      final none = [sampleAt(0, available: false), sampleAt(1000, available: false)];
      expect(EnergyEstimator.estimate(none), (0.0, EnergySource.unavailable));
    });
  });

  group('RunTelemetryRecorder', () {
    test('samples a window and summarises peaks', () async {
      var rss = 100.0;
      var temp = 30.0;
      final source = FakeTelemetrySource(
        reading: () => fakeReading(rssMb: rss += 10, tempC: temp += 0.5),
      );
      final recorder = RunTelemetryRecorder(
        DeviceStateCollector(source: source),
        interval: const Duration(milliseconds: 10),
      );
      await recorder.start();
      await Future<void>.delayed(const Duration(milliseconds: 80));
      final summary = await recorder.stop();

      expect(summary.samples.length, greaterThanOrEqualTo(3));
      expect(summary.peakMemoryMb, summary.samples.last.rssMb);
      expect(summary.thermalDeltaCelsius, greaterThan(0));
      expect(summary.energySource, EnergySource.currentIntegration);
      expect(recorder.isRecording, isFalse);
    });

    test('stop without start is an error', () {
      final recorder = RunTelemetryRecorder(DeviceStateCollector(source: FakeTelemetrySource()));
      expect(recorder.stop, throwsStateError);
    });
  });

  group('ThermalCooldown', () {
    test('returns immediately when cool', () async {
      final r = await ThermalCooldown(
        DeviceStateCollector(source: FakeTelemetrySource(reading: () => fakeReading(tempC: 30))),
      ).waitUntilCool();
      expect(r.timedOut, isFalse);
    });

    test('waits until the device cools below the threshold', () async {
      var temp = 37.0;
      final cooldown = ThermalCooldown(
        DeviceStateCollector(source: FakeTelemetrySource(reading: () => fakeReading(tempC: temp -= 1))),
        pollInterval: const Duration(milliseconds: 5),
      );
      final r = await cooldown.waitUntilCool();
      expect(r.finalTempCelsius, 35);
      expect(r.timedOut, isFalse);
    });

    test('gives up after maxWait', () async {
      final r = await ThermalCooldown(
        DeviceStateCollector(source: FakeTelemetrySource(reading: () => fakeReading(tempC: 45))),
        maxWait: const Duration(milliseconds: 20),
        pollInterval: const Duration(milliseconds: 5),
      ).waitUntilCool();
      expect(r.timedOut, isTrue);
    });
  });
}
