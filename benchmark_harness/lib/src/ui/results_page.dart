import 'dart:io';

import 'package:auraf/auraf_telemetry.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../harness_services.dart';
import 'widgets.dart';

/// Reads the SQLite log back, aggregates it per matrix cell and exports CSV.
class ResultsPage extends StatefulWidget {
  const ResultsPage({super.key});

  @override
  State<ResultsPage> createState() => _ResultsPageState();
}

class _Cell {
  final List<BenchmarkRecord> runs = <BenchmarkRecord>[];

  double mean(double Function(BenchmarkRecord) f) =>
      runs.map(f).reduce((a, b) => a + b) / runs.length;
  int get violations => runs.where((r) => r.constraintViolated).length;
}

class _ResultsPageState extends State<ResultsPage> {
  Future<_Snapshot>? _load;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _load ??= _read();
  }

  Future<_Snapshot> _read() async {
    final db = HarnessScope.of(context).database;
    final records = await db.records();
    return _Snapshot(records, await db.sampleCount(), db.path);
  }

  void _refresh() => setState(() => _load = _read());

  Future<void> _export() async {
    final db = HarnessScope.of(context).database;
    final messenger = ScaffoldMessenger.of(context);
    // App-specific external storage is readable with `adb pull` (no root).
    final dir = await getExternalStorageDirectory() ?? await getApplicationDocumentsDirectory();
    final file = await db.exportRecordsCsv(p.join(dir.path, 'm2_benchmark_results.csv'));
    await File(p.join(dir.path, 'm2_device_state_samples.csv'))
        .writeAsString(await db.samplesCsv());
    await Clipboard.setData(ClipboardData(text: file.path));
    messenger.showSnackBar(SnackBar(content: Text('Exported to ${file.path} (path copied)')));
  }

  Future<void> _clear() async {
    final services = HarnessScope.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear telemetry log?'),
        content: const Text('Deletes every benchmark record and telemetry sample.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Clear')),
        ],
      ),
    );
    if (ok ?? false) {
      await services.database.clear();
      _refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FutureBuilder<_Snapshot>(
      future: _load,
      builder: (context, snap) {
        if (snap.hasError) return Center(child: Text('Could not read log: ${snap.error}'));
        if (!snap.hasData) return const Center(child: CircularProgressIndicator());
        final data = snap.data!;
        final cells = <String, _Cell>{};
        for (final r in data.records) {
          cells
              .putIfAbsent('${r.networkCondition}|${r.contextBudget}|${r.placement}', _Cell.new)
              .runs
              .add(r);
        }
        return RefreshIndicator(
          onRefresh: () async => _refresh(),
          child: ListView(
            padding: const EdgeInsets.all(12),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('SQLite telemetry log', style: theme.textTheme.titleMedium),
                      const SizedBox(height: 4),
                      Text('${data.records.length} benchmark records · '
                          '${data.sampleCount} device-state samples'),
                      if (data.path != null)
                        Text(data.path!, style: theme.textTheme.bodySmall),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        children: [
                          FilledButton.icon(
                            key: const Key('export-csv'),
                            onPressed: data.records.isEmpty ? null : _export,
                            icon: const Icon(Icons.file_download),
                            label: const Text('Export CSV'),
                          ),
                          OutlinedButton.icon(
                            onPressed: _refresh,
                            icon: const Icon(Icons.refresh),
                            label: const Text('Refresh'),
                          ),
                          TextButton.icon(
                            onPressed: _clear,
                            icon: const Icon(Icons.delete_outline),
                            label: const Text('Clear'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SectionHeader('Mean per matrix cell'),
              if (cells.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: Text('No runs yet. Start one on the Benchmark tab.')),
                )
              else
                Card(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: DataTable(
                      columnSpacing: 16,
                      headingRowHeight: 36,
                      dataRowMinHeight: 32,
                      dataRowMaxHeight: 36,
                      columns: const [
                        DataColumn(label: Text('Network')),
                        DataColumn(label: Text('Ctx'), numeric: true),
                        DataColumn(label: Text('Place')),
                        DataColumn(label: Text('n'), numeric: true),
                        DataColumn(label: Text('TTFT ms'), numeric: true),
                        DataColumn(label: Text('Total ms'), numeric: true),
                        DataColumn(label: Text('tok/s'), numeric: true),
                        DataColumn(label: Text('mAh'), numeric: true),
                        DataColumn(label: Text('MB'), numeric: true),
                        DataColumn(label: Text('°C'), numeric: true),
                        DataColumn(label: Text('\$'), numeric: true),
                        DataColumn(label: Text('Viol.'), numeric: true),
                      ],
                      rows: [
                        for (final c in cells.values)
                          DataRow(cells: [
                            DataCell(Text(c.runs.first.networkCondition)),
                            DataCell(Text('${c.runs.first.contextBudget}')),
                            DataCell(Text(c.runs.first.placement)),
                            DataCell(Text('${c.runs.length}')),
                            DataCell(Text(c.mean((r) => r.ttftMs).toStringAsFixed(0))),
                            DataCell(Text(c.mean((r) => r.totalLatencyMs).toStringAsFixed(0))),
                            DataCell(Text(c.mean((r) => r.tokensPerSec).toStringAsFixed(1))),
                            DataCell(Text(c.mean((r) => r.energyMah).toStringAsFixed(3))),
                            DataCell(Text(c.mean((r) => r.peakMemoryMb).toStringAsFixed(0))),
                            DataCell(Text(c.mean((r) => r.tempCelsius).toStringAsFixed(1))),
                            DataCell(Text(c.mean((r) => r.costUsd).toStringAsFixed(5))),
                            DataCell(Text('${c.violations}')),
                          ]),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _Snapshot {
  const _Snapshot(this.records, this.sampleCount, this.path);

  final List<BenchmarkRecord> records;
  final int sampleCount;
  final String? path;
}
