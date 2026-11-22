import 'package:auraf/auraf_telemetry.dart';

/// Builds a platform-shaped telemetry map, overriding selected fields.
Map<Object?, Object?> fakeReading({
  int? timestamp,
  double currentMa = -400,
  bool currentAvailable = true,
  int? chargeCounterUah,
  double tempC = 30,
  double rssMb = 150,
  String network = 'stable',
  bool charging = false,
}) =>
    <Object?, Object?>{
      'timestamp': timestamp ?? DateTime.now().millisecondsSinceEpoch,
      'battery_level_percent': 80,
      'battery_current_ma': currentMa,
      'battery_current_available': currentAvailable,
      'battery_voltage_mv': 3900,
      'charge_counter_uah': chargeCounterUah,
      'is_charging': charging,
      'temperature_celsius': tempC,
      'temperature_available': true,
      'thermal_status': 0,
      'available_ram_mb': 2048.0,
      'total_ram_mb': 4096.0,
      'low_memory': false,
      'rss_mb': rssMb,
      'peak_memory_mb': rssMb + 20,
      'network_condition': network,
    };

TelemetrySample sampleAt(int ms, {double currentMa = -400, int? counter, bool available = true}) =>
    TelemetrySample.fromPlatformMap(fakeReading(
      timestamp: ms,
      currentMa: currentMa,
      currentAvailable: available,
      chargeCounterUah: counter,
    ));

/// Scriptable [TelemetrySource] for host-side tests.
class FakeTelemetrySource implements TelemetrySource {
  FakeTelemetrySource({this.reading, this.error});

  Map<Object?, Object?> Function()? reading;
  Object? error;
  int calls = 0;

  @override
  Future<Map<Object?, Object?>?> sampleState() async {
    calls++;
    if (error != null) throw error!;
    return (reading ?? fakeReading)();
  }

  @override
  Future<Map<Object?, Object?>?> describeDevice() async => <Object?, Object?>{
        'device_model': 'Test_Phone_Android_15',
        'manufacturer': 'Test',
        'model': 'Phone',
        'android_release': '15',
        'sdk_int': 35,
        'hardware': 'test',
        'cpu_cores': 8,
        'is_emulator': true,
      };
}
