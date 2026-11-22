import 'package:meta/meta.dart';

import '../models/device_state.dart';

/// One raw reading from the native State Collector.
///
/// It carries every [DeviceState] contract field plus the extra signals the
/// benchmark harness needs to measure a run honestly (whether the current
/// sensor exists, the charge counter, process RSS, thermal status).
@immutable
class TelemetrySample {
  const TelemetrySample({
    required this.timestamp,
    required this.batteryLevelPercent,
    required this.batteryCurrentMa,
    required this.currentAvailable,
    required this.batteryVoltageMv,
    required this.chargeCounterUah,
    required this.isCharging,
    required this.temperatureCelsius,
    required this.temperatureAvailable,
    required this.thermalStatus,
    required this.availableRamMb,
    required this.totalRamMb,
    required this.lowMemory,
    required this.rssMb,
    required this.peakRssMb,
    required this.networkCondition,
    this.sampleLatencyMs = 0,
  });

  /// Parses the map returned by the `sampleState` platform method.
  ///
  /// Throws [FormatException] when a field required by the shared data
  /// contract is missing, so broken telemetry never becomes silent zeros.
  factory TelemetrySample.fromPlatformMap(
    Map<Object?, Object?> map, {
    double sampleLatencyMs = 0,
  }) {
    num required(String key) {
      final value = map[key];
      if (value is num) return value;
      throw FormatException('Missing numeric telemetry field: $key');
    }

    num? optional(String key) {
      final value = map[key];
      return value is num ? value : null;
    }

    bool flag(String key, {bool fallback = false}) {
      final value = map[key];
      return value is bool ? value : fallback;
    }

    final network = map['network_condition'];
    if (network is! String) {
      throw const FormatException('Missing string telemetry field: network_condition');
    }

    return TelemetrySample(
      timestamp: required('timestamp').toInt(),
      batteryLevelPercent: required('battery_level_percent').toInt(),
      batteryCurrentMa: required('battery_current_ma').toDouble(),
      currentAvailable: flag('battery_current_available', fallback: true),
      batteryVoltageMv: optional('battery_voltage_mv')?.toInt() ?? -1,
      chargeCounterUah: optional('charge_counter_uah')?.toInt(),
      isCharging: flag('is_charging'),
      temperatureCelsius: required('temperature_celsius').toDouble(),
      temperatureAvailable: flag('temperature_available', fallback: true),
      thermalStatus: optional('thermal_status')?.toInt() ?? -1,
      availableRamMb: required('available_ram_mb').toDouble(),
      totalRamMb: optional('total_ram_mb')?.toDouble() ?? 0,
      lowMemory: flag('low_memory'),
      rssMb: optional('rss_mb')?.toDouble() ?? required('peak_memory_mb').toDouble(),
      peakRssMb: required('peak_memory_mb').toDouble(),
      networkCondition: NetworkCondition.fromString(network),
      sampleLatencyMs: sampleLatencyMs,
    );
  }

  /// Epoch milliseconds at which the native side took the reading.
  final int timestamp;
  final int batteryLevelPercent;

  /// Negative while discharging, positive while charging (contract sign).
  final double batteryCurrentMa;

  /// False when the device does not expose `BATTERY_PROPERTY_CURRENT_NOW`
  /// (typical on emulators); [batteryCurrentMa] is then 0 and meaningless.
  final bool currentAvailable;
  final int batteryVoltageMv;

  /// Remaining battery charge in micro-amp-hours, or null if unsupported.
  final int? chargeCounterUah;
  final bool isCharging;
  final double temperatureCelsius;
  final bool temperatureAvailable;

  /// `PowerManager.THERMAL_STATUS_*` (0 = none ... 6 = shutdown), -1 if unknown.
  final int thermalStatus;
  final double availableRamMb;
  final double totalRamMb;
  final bool lowMemory;

  /// Current resident set size of the app process (VmRSS).
  final double rssMb;

  /// High-water mark of the app process RSS since launch (VmHWM).
  final double peakRssMb;
  final NetworkCondition networkCondition;

  /// Round-trip time of the platform-channel call that produced this sample.
  final double sampleLatencyMs;

  /// Projects this sample onto the shared-contract [DeviceState].
  DeviceState toDeviceState({
    required int contextSizeTokens,
    required double remainingBudgetUsd,
  }) {
    return DeviceState(
      timestamp: timestamp,
      batteryLevelPercent: batteryLevelPercent,
      batteryCurrentMa: batteryCurrentMa,
      temperatureCelsius: temperatureCelsius,
      availableRamMb: availableRamMb,
      peakMemoryMb: peakRssMb,
      networkCondition: networkCondition,
      contextSizeTokens: contextSizeTokens,
      remainingBudgetUsd: remainingBudgetUsd,
    );
  }

  static const List<String> thermalStatusNames = <String>[
    'none',
    'light',
    'moderate',
    'severe',
    'critical',
    'emergency',
    'shutdown',
  ];

  String get thermalStatusName =>
      thermalStatus >= 0 && thermalStatus < thermalStatusNames.length
          ? thermalStatusNames[thermalStatus]
          : 'unknown';
}

/// Static description of the device the collector runs on.
@immutable
class DeviceDescriptor {
  const DeviceDescriptor({
    required this.deviceModel,
    required this.manufacturer,
    required this.model,
    required this.androidRelease,
    required this.sdkInt,
    required this.hardware,
    required this.cpuCores,
    required this.isEmulator,
  });

  factory DeviceDescriptor.fromPlatformMap(Map<Object?, Object?> map) {
    String text(String key) => map[key] is String ? map[key]! as String : 'unknown';
    int integer(String key) => map[key] is num ? (map[key]! as num).toInt() : -1;
    return DeviceDescriptor(
      deviceModel: text('device_model'),
      manufacturer: text('manufacturer'),
      model: text('model'),
      androidRelease: text('android_release'),
      sdkInt: integer('sdk_int'),
      hardware: text('hardware'),
      cpuCores: integer('cpu_cores'),
      isEmulator: map['is_emulator'] == true,
    );
  }

  /// CSV-safe identifier, e.g. `Google_Pixel_4a_Android_15`.
  final String deviceModel;
  final String manufacturer;
  final String model;
  final String androidRelease;
  final int sdkInt;
  final String hardware;
  final int cpuCores;
  final bool isEmulator;
}
