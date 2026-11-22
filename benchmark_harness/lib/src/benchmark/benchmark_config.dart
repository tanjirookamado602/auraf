import 'package:auraf/auraf_telemetry.dart';

/// Execution placement in the benchmark matrix (contract values).
enum Placement {
  cloud('cloud'),
  device('device');

  const Placement(this.wireName);
  final String wireName;
}

/// The experimental matrix and limits from
/// `docs/MEASUREMENT_PROTOCOL_OUTLINE.md`. Every field can be overridden from
/// the command line with `--dart-define` (see [BenchmarkConfig.fromEnvironment]).
class BenchmarkConfig {
  const BenchmarkConfig({
    this.networks = NetworkCondition.values,
    this.contextBudgets = const <int>[512, 2048, 8192],
    this.placements = Placement.values,
    this.repetitions = 5,
    this.maxOutputTokens = 64,
    this.slaMs = 5000,
    this.energyMaxMah = 5.0,
    this.thermalCriticalCelsius = 42.0,
    this.cooldownThresholdCelsius = 35.0,
    this.cooldownMaxWait = const Duration(seconds: 60),
    this.interRunGap = const Duration(milliseconds: 250),
    this.offlineTimeoutMs = 2000,
    this.cloudBudgetUsd = 10.0,
    this.cloudInputUsdPerMTok = 0.10,
    this.cloudOutputUsdPerMTok = 0.40,
    this.deviceWorkScale = 1.0,
    this.promptSplit = 'profiling',
    this.seed = 42,
  });

  /// Reads overrides passed as `--dart-define=AURAF_<NAME>=<value>`.
  factory BenchmarkConfig.fromEnvironment() {
    const reps = int.fromEnvironment('AURAF_REPS', defaultValue: 5);
    const maxOut = int.fromEnvironment('AURAF_MAX_OUTPUT_TOKENS', defaultValue: 64);
    const cooldown = String.fromEnvironment('AURAF_COOLDOWN_C', defaultValue: '35');
    const sla = int.fromEnvironment('AURAF_SLA_MS', defaultValue: 5000);
    const seed = int.fromEnvironment('AURAF_SEED', defaultValue: 42);
    const scale = String.fromEnvironment('AURAF_DEVICE_WORK_SCALE', defaultValue: '1.0');
    return BenchmarkConfig(
      repetitions: reps,
      maxOutputTokens: maxOut,
      cooldownThresholdCelsius: double.tryParse(cooldown) ?? 35,
      slaMs: sla,
      seed: seed,
      deviceWorkScale: double.tryParse(scale) ?? 1.0,
    );
  }

  final List<NetworkCondition> networks;
  final List<int> contextBudgets;
  final List<Placement> placements;
  final int repetitions;

  /// Generated tokens per request (prompts' expected length is capped to this
  /// so a full 4x3x2x5 matrix finishes in a few minutes).
  final int maxOutputTokens;

  /// T_SLA, E_max and Θ_crit of the constraint-violation indicator.
  final int slaMs;
  final double energyMaxMah;
  final double thermalCriticalCelsius;

  /// Thermal cool-down rule: idle until temp <= threshold before each run.
  final double cooldownThresholdCelsius;
  final Duration cooldownMaxWait;
  final Duration interRunGap;

  /// How long a cloud request waits before failing when offline.
  final int offlineTimeoutMs;
  final double cloudBudgetUsd;
  final double cloudInputUsdPerMTok;
  final double cloudOutputUsdPerMTok;
  final double deviceWorkScale;
  final String promptSplit;
  final int seed;

  int get cellsPerRepetition =>
      networks.length * contextBudgets.length * placements.length;
  int get totalRuns => cellsPerRepetition * repetitions;

  BenchmarkConfig copyWith({
    List<NetworkCondition>? networks,
    List<int>? contextBudgets,
    List<Placement>? placements,
    int? repetitions,
  }) {
    return BenchmarkConfig(
      networks: networks ?? this.networks,
      contextBudgets: contextBudgets ?? this.contextBudgets,
      placements: placements ?? this.placements,
      repetitions: repetitions ?? this.repetitions,
      maxOutputTokens: maxOutputTokens,
      slaMs: slaMs,
      energyMaxMah: energyMaxMah,
      thermalCriticalCelsius: thermalCriticalCelsius,
      cooldownThresholdCelsius: cooldownThresholdCelsius,
      cooldownMaxWait: cooldownMaxWait,
      interRunGap: interRunGap,
      offlineTimeoutMs: offlineTimeoutMs,
      cloudBudgetUsd: cloudBudgetUsd,
      cloudInputUsdPerMTok: cloudInputUsdPerMTok,
      cloudOutputUsdPerMTok: cloudOutputUsdPerMTok,
      deviceWorkScale: deviceWorkScale,
      promptSplit: promptSplit,
      seed: seed,
    );
  }

  Map<String, Object> toJson() => <String, Object>{
        'networks': networks.map((n) => n.wireName).toList(),
        'context_budgets': contextBudgets,
        'placements': placements.map((p) => p.wireName).toList(),
        'repetitions': repetitions,
        'total_runs': totalRuns,
        'max_output_tokens': maxOutputTokens,
        'sla_ms': slaMs,
        'energy_max_mah': energyMaxMah,
        'thermal_critical_celsius': thermalCriticalCelsius,
        'cooldown_threshold_celsius': cooldownThresholdCelsius,
        'offline_timeout_ms': offlineTimeoutMs,
        'device_work_scale': deviceWorkScale,
        'prompt_split': promptSplit,
        'seed': seed,
      };
}
