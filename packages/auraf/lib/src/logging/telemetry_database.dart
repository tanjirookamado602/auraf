import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../collector/telemetry_sample.dart';
import '../models/benchmark_record.dart';

/// Local SQLite telemetry log for AURAF.
///
/// * `benchmark_records`: one row per run, exact DDL from
///   `docs/SHARED_DATA_CONTRACT.md` §4.
/// * `device_state_samples`: every State Collector reading taken during a run
///   (or during live monitoring), using the contract `DeviceState` column
///   names plus collector diagnostics.
///
/// sqflite executes queries on a native background thread, so logging never
/// blocks the UI isolate. Each run's record and samples are written in one
/// transaction.
class TelemetryDatabase {
  TelemetryDatabase({String? databasePath, DatabaseFactory? factory})
      : _databasePath = databasePath,
        _factory = factory;

  static const String databaseName = 'auraf_telemetry.db';
  static const int schemaVersion = 2;

  static const String samplesCsvHeader =
      'run_id,timestamp,battery_level_percent,battery_current_ma,'
      'temperature_celsius,available_ram_mb,peak_memory_mb,network_condition,'
      'context_size_tokens,remaining_budget_usd,rss_mb,thermal_status,'
      'is_charging,sample_latency_ms';

  final String? _databasePath;
  final DatabaseFactory? _factory;
  Future<Database>? _opening;
  String? _resolvedPath;

  /// Absolute path of the database file once opened.
  String? get path => _resolvedPath;

  Future<Database> get database => _opening ??= _open();

  Future<Database> _open() async {
    final factory = _factory ?? databaseFactory;
    final location = _databasePath ??
        p.join(await factory.getDatabasesPath(), databaseName);
    _resolvedPath = location;
    return factory.openDatabase(
      location,
      options: OpenDatabaseOptions(
        version: schemaVersion,
        onCreate: (db, _) async {
          await _createRecordsTable(db);
          await _createSamplesTable(db);
        },
        onUpgrade: (db, from, _) async {
          if (from < 2) await _createSamplesTable(db);
        },
      ),
    );
  }

  static Future<void> _createRecordsTable(Database db) async {
    await db.execute('''
CREATE TABLE IF NOT EXISTS benchmark_records (
    run_id TEXT PRIMARY KEY,
    timestamp INTEGER NOT NULL,
    device_model TEXT NOT NULL,
    network_condition TEXT NOT NULL,
    context_budget INTEGER NOT NULL,
    placement TEXT NOT NULL,
    ttft_ms REAL NOT NULL,
    total_latency_ms REAL NOT NULL,
    tokens_per_sec REAL NOT NULL,
    energy_mah REAL NOT NULL,
    peak_memory_mb REAL NOT NULL,
    temp_celsius REAL NOT NULL,
    cost_usd REAL NOT NULL,
    quality_score REAL NOT NULL,
    constraint_violated INTEGER NOT NULL
)''');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_records_timestamp '
        'ON benchmark_records(timestamp)');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_records_placement '
        'ON benchmark_records(placement)');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_records_network '
        'ON benchmark_records(network_condition)');
  }

  static Future<void> _createSamplesTable(Database db) async {
    await db.execute('''
CREATE TABLE IF NOT EXISTS device_state_samples (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    run_id TEXT,
    timestamp INTEGER NOT NULL,
    battery_level_percent INTEGER NOT NULL,
    battery_current_ma REAL NOT NULL,
    temperature_celsius REAL NOT NULL,
    available_ram_mb REAL NOT NULL,
    peak_memory_mb REAL NOT NULL,
    network_condition TEXT NOT NULL,
    context_size_tokens INTEGER NOT NULL,
    remaining_budget_usd REAL NOT NULL,
    rss_mb REAL NOT NULL,
    thermal_status INTEGER NOT NULL,
    is_charging INTEGER NOT NULL,
    sample_latency_ms REAL NOT NULL
)''');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_samples_run '
        'ON device_state_samples(run_id)');
  }

  static Map<String, Object?> _sampleRow(
    TelemetrySample s, {
    required String? runId,
    required int contextSizeTokens,
    required double remainingBudgetUsd,
  }) =>
      <String, Object?>{
        'run_id': runId,
        ...s
            .toDeviceState(
              contextSizeTokens: contextSizeTokens,
              remainingBudgetUsd: remainingBudgetUsd,
            )
            .toMap(),
        'rss_mb': s.rssMb,
        'thermal_status': s.thermalStatus,
        'is_charging': s.isCharging ? 1 : 0,
        'sample_latency_ms': s.sampleLatencyMs,
      };

  /// Writes a run's record and its telemetry samples atomically.
  Future<void> logRun(
    BenchmarkRecord record, {
    List<TelemetrySample> samples = const <TelemetrySample>[],
    double remainingBudgetUsd = 0,
  }) async {
    final db = await database;
    await db.transaction((txn) async {
      final batch = txn.batch()
        ..insert(
          'benchmark_records',
          record.toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      for (final s in samples) {
        batch.insert(
          'device_state_samples',
          _sampleRow(
            s,
            runId: record.runId,
            contextSizeTokens: record.contextBudget,
            remainingBudgetUsd: remainingBudgetUsd,
          ),
        );
      }
      await batch.commit(noResult: true);
    });
  }

  /// Logs live-monitor readings that do not belong to a benchmark run.
  Future<void> logSamples(
    List<TelemetrySample> samples, {
    String? runId,
    int contextSizeTokens = 0,
    double remainingBudgetUsd = 0,
  }) async {
    if (samples.isEmpty) return;
    final batch = (await database).batch();
    for (final s in samples) {
      batch.insert(
        'device_state_samples',
        _sampleRow(
          s,
          runId: runId,
          contextSizeTokens: contextSizeTokens,
          remainingBudgetUsd: remainingBudgetUsd,
        ),
      );
    }
    await batch.commit(noResult: true);
  }

  Future<List<BenchmarkRecord>> records({int? limit, bool newestFirst = false}) async {
    final rows = await (await database).query(
      'benchmark_records',
      orderBy: newestFirst ? 'timestamp DESC, run_id DESC' : 'timestamp ASC, run_id ASC',
      limit: limit,
    );
    return rows.map(BenchmarkRecord.fromMap).toList(growable: false);
  }

  Future<int> recordCount() => _count('benchmark_records');
  Future<int> sampleCount() => _count('device_state_samples');

  Future<int> _count(String table) async {
    final rows = await (await database).rawQuery('SELECT COUNT(*) FROM $table');
    return Sqflite.firstIntValue(rows) ?? 0;
  }

  Future<void> clear() async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete('benchmark_records');
      await txn.delete('device_state_samples');
    });
  }

  /// Contract CSV (§5): exact header, records ordered by time.
  Future<String> recordsCsv() async {
    final buffer = StringBuffer(BenchmarkRecord.csvHeader)..write('\n');
    for (final r in await records()) {
      buffer
        ..write(r.toCsvRow())
        ..write('\n');
    }
    return buffer.toString();
  }

  Future<String> samplesCsv() async {
    final rows = await (await database).query(
      'device_state_samples',
      orderBy: 'timestamp ASC, id ASC',
    );
    final columns = samplesCsvHeader.split(',');
    final buffer = StringBuffer(samplesCsvHeader)..write('\n');
    for (final row in rows) {
      buffer
        ..write(columns.map((c) => row[c]?.toString() ?? '').join(','))
        ..write('\n');
    }
    return buffer.toString();
  }

  Future<File> exportRecordsCsv(String outputPath) async {
    final file = File(outputPath);
    await file.parent.create(recursive: true);
    return file.writeAsString(await recordsCsv(), flush: true);
  }

  Future<void> close() async {
    final opening = _opening;
    _opening = null;
    if (opening != null) await (await opening).close();
  }
}
