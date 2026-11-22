import 'dart:convert';
import 'dart:io';

import 'package:integration_test/integration_test_driver.dart';

/// Host-side driver: receives the files produced on the phone through
/// `reportData` and writes them into the results directory. This avoids
/// `adb run-as` / external-storage pulls, which fail on some OEM builds.
Future<void> main() {
  return integrationDriver(
    responseDataCallback: (Map<String, dynamic>? data) async {
      if (data == null) return;
      final dir = Directory(Platform.environment['AURAF_RESULTS_DIR'] ?? '../results');
      await dir.create(recursive: true);
      Future<void> text(String key, String name) async {
        final value = data[key];
        if (value is String) await File('${dir.path}/$name').writeAsString(value);
      }

      await text('records_csv', 'm2_benchmark_results.csv');
      await text('samples_csv', 'm2_device_state_samples.csv');
      await text('summary_json', 'm2_run_summary.json');
      final db = data['sqlite_base64'];
      if (db is String) {
        await File('${dir.path}/auraf_telemetry.db').writeAsBytes(base64Decode(db));
      }
      stdout.writeln('AURAF results written to ${dir.absolute.path}');
    },
  );
}
