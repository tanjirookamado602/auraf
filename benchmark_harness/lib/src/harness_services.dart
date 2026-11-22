import 'package:auraf/auraf_telemetry.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'benchmark/benchmark_config.dart';
import 'benchmark/benchmark_runner.dart';

/// Long-lived objects shared by every screen and by the integration test.
class HarnessServices {
  HarnessServices._(this.collector, this.database, this.runner, this.prompts);

  static Future<HarnessServices> create({
    DeviceStateCollector? collector,
    TelemetryDatabase? database,
    BenchmarkConfig? config,
  }) async {
    final json = await rootBundle.loadString('packages/auraf/assets/prompts.json');
    final prompts = BenchmarkPrompt.parseList(json);
    final c = collector ?? DeviceStateCollector();
    final db = database ?? TelemetryDatabase();
    final runner = BenchmarkRunner(
      collector: c,
      database: db,
      prompts: prompts,
      config: config,
    );
    return HarnessServices._(c, db, runner, prompts);
  }

  final DeviceStateCollector collector;
  final TelemetryDatabase database;
  final BenchmarkRunner runner;
  final List<BenchmarkPrompt> prompts;
}

class HarnessScope extends InheritedWidget {
  const HarnessScope({super.key, required this.services, required super.child});

  final HarnessServices services;

  static HarnessServices of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<HarnessScope>()!.services;

  @override
  bool updateShouldNotify(HarnessScope oldWidget) => services != oldWidget.services;
}
