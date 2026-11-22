import 'dart:async';

import 'package:flutter/services.dart';

import '../models/device_state.dart';
import 'telemetry_sample.dart';

/// Thrown when live telemetry cannot be read (no Android plugin, sensor
/// error, malformed reply). The collector never substitutes made-up values.
class TelemetryUnavailableException implements Exception {
  const TelemetryUnavailableException(this.message, [this.cause]);

  final String message;
  final Object? cause;

  @override
  String toString() => 'TelemetryUnavailableException: $message'
      '${cause == null ? '' : ' ($cause)'}';
}

/// Where raw telemetry maps come from. The default reads the AURAF Android
/// plugin; tests inject a fake.
abstract interface class TelemetrySource {
  Future<Map<Object?, Object?>?> sampleState();
  Future<Map<Object?, Object?>?> describeDevice();
}

/// Reads the `com.auraf/state_collector` channel served by the native
/// `StateCollectorPlugin` (registered by the host app's MainActivity).
class MethodChannelTelemetrySource implements TelemetrySource {
  const MethodChannelTelemetrySource([
    this._channel = const MethodChannel('com.auraf/state_collector'),
  ]);

  final MethodChannel _channel;

  @override
  Future<Map<Object?, Object?>?> sampleState() =>
      _channel.invokeMethod<Map<Object?, Object?>>('sampleState');

  @override
  Future<Map<Object?, Object?>?> describeDevice() =>
      _channel.invokeMethod<Map<Object?, Object?>>('describeDevice');
}

/// The AURAF State Collector.
///
/// Samples battery, current, temperature, memory and network state from the
/// device and exposes them as [TelemetrySample]s or contract [DeviceState]s.
class DeviceStateCollector {
  DeviceStateCollector({TelemetrySource? source})
      : _source = source ?? const MethodChannelTelemetrySource();

  final TelemetrySource _source;
  DeviceDescriptor? _descriptor;

  /// Takes one reading. Throws [TelemetryUnavailableException] on failure.
  Future<TelemetrySample> sample() async {
    final watch = Stopwatch()..start();
    final Map<Object?, Object?>? raw;
    try {
      raw = await _source.sampleState();
    } on MissingPluginException catch (e) {
      throw TelemetryUnavailableException(
        'AURAF telemetry plugin is not registered on this platform',
        e,
      );
    } on PlatformException catch (e) {
      throw TelemetryUnavailableException('Native sampler failed', e);
    }
    watch.stop();
    if (raw == null) {
      throw const TelemetryUnavailableException('Native sampler returned null');
    }
    try {
      return TelemetrySample.fromPlatformMap(
        raw,
        sampleLatencyMs: watch.elapsedMicroseconds / 1000.0,
      );
    } on FormatException catch (e) {
      throw TelemetryUnavailableException('Malformed telemetry reply', e);
    }
  }

  /// Takes one reading and projects it onto the shared-contract [DeviceState].
  Future<DeviceState> sampleDeviceState({
    required int contextSizeTokens,
    required double remainingBudgetUsd,
  }) async {
    if (contextSizeTokens < 0) {
      throw ArgumentError.value(contextSizeTokens, 'contextSizeTokens', 'must be >= 0');
    }
    if (remainingBudgetUsd < 0) {
      throw ArgumentError.value(remainingBudgetUsd, 'remainingBudgetUsd', 'must be >= 0');
    }
    final reading = await sample();
    return reading.toDeviceState(
      contextSizeTokens: contextSizeTokens,
      remainingBudgetUsd: remainingBudgetUsd,
    );
  }

  /// Static device information; cached after the first call.
  Future<DeviceDescriptor> describeDevice() async {
    final cached = _descriptor;
    if (cached != null) return cached;
    final Map<Object?, Object?>? raw;
    try {
      raw = await _source.describeDevice();
    } on MissingPluginException catch (e) {
      throw TelemetryUnavailableException(
        'AURAF telemetry plugin is not registered on this platform',
        e,
      );
    } on PlatformException catch (e) {
      throw TelemetryUnavailableException('describeDevice failed', e);
    }
    if (raw == null) {
      throw const TelemetryUnavailableException('describeDevice returned null');
    }
    return _descriptor = DeviceDescriptor.fromPlatformMap(raw);
  }

  /// Emits a reading every [interval]. Failed readings are forwarded as
  /// stream errors and sampling continues. Ticks are skipped, never queued,
  /// if a previous reading is still in flight.
  Stream<TelemetrySample> watch({
    Duration interval = const Duration(seconds: 1),
  }) {
    late StreamController<TelemetrySample> controller;
    Timer? timer;
    var busy = false;

    Future<void> tick() async {
      if (busy || controller.isClosed) return;
      busy = true;
      try {
        final reading = await sample();
        if (!controller.isClosed) controller.add(reading);
      } catch (e, st) {
        if (!controller.isClosed) controller.addError(e, st);
      } finally {
        busy = false;
      }
    }

    controller = StreamController<TelemetrySample>(
      onListen: () {
        unawaited(tick());
        timer = Timer.periodic(interval, (_) => unawaited(tick()));
      },
      onPause: () => timer?.cancel(),
      onResume: () => timer = Timer.periodic(interval, (_) => unawaited(tick())),
      onCancel: () => timer?.cancel(),
    );
    return controller.stream;
  }
}
