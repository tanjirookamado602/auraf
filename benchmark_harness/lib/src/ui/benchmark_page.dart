import 'package:auraf/auraf_telemetry.dart';
import 'package:flutter/material.dart';

import '../benchmark/benchmark_config.dart';
import '../benchmark/benchmark_runner.dart';
import '../harness_services.dart';
import 'widgets.dart';

class BenchmarkPage extends StatelessWidget {
  const BenchmarkPage({super.key});

  @override
  Widget build(BuildContext context) {
    final runner = HarnessScope.of(context).runner;
    return ListenableBuilder(
      listenable: runner,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.all(12),
        children: [
          _ConfigCard(runner: runner),
          const SizedBox(height: 8),
          _ProgressCard(runner: runner),
          if (runner.phase == RunnerPhase.done) _SummaryCard(runner: runner),
          if (runner.results.isNotEmpty) ...[
            const SectionHeader('Completed runs (latest first)'),
            for (final r in runner.results.reversed.take(40)) _RunTile(result: r),
          ],
        ],
      ),
    );
  }
}

class _ConfigCard extends StatelessWidget {
  const _ConfigCard({required this.runner});

  final BenchmarkRunner runner;

  @override
  Widget build(BuildContext context) {
    final c = runner.config;
    final enabled = !runner.isRunning;
    final theme = Theme.of(context);

    Widget chips<T>(List<T> all, List<T> selected, String Function(T) label,
        void Function(List<T>) onChanged) {
      return Wrap(
        spacing: 6,
        runSpacing: -4,
        children: [
          for (final v in all)
            FilterChip(
              label: Text(label(v)),
              selected: selected.contains(v),
              onSelected: !enabled
                  ? null
                  : (on) {
                      final next = all
                          .where((x) => x == v ? on : selected.contains(x))
                          .toList();
                      if (next.isNotEmpty) onChanged(next);
                    },
            ),
        ],
      );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Experiment matrix', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text('Network condition', style: theme.textTheme.labelMedium),
            chips<NetworkCondition>(NetworkCondition.values, c.networks,
                (n) => n.wireName, (v) => runner.updateConfig(c.copyWith(networks: v))),
            Text('Context budget (tokens)', style: theme.textTheme.labelMedium),
            chips<int>(const [512, 2048, 8192], c.contextBudgets, (b) => '$b',
                (v) => runner.updateConfig(c.copyWith(contextBudgets: v))),
            Text('Placement', style: theme.textTheme.labelMedium),
            chips<Placement>(Placement.values, c.placements, (p) => p.wireName,
                (v) => runner.updateConfig(c.copyWith(placements: v))),
            const SizedBox(height: 8),
            Row(
              children: [
                Text('Repetitions', style: theme.textTheme.labelMedium),
                const SizedBox(width: 12),
                SegmentedButton<int>(
                  segments: const [
                    ButtonSegment(value: 1, label: Text('1')),
                    ButtonSegment(value: 3, label: Text('3')),
                    ButtonSegment(value: 5, label: Text('5')),
                  ],
                  selected: {c.repetitions},
                  onSelectionChanged: !enabled
                      ? null
                      : (s) => runner.updateConfig(c.copyWith(repetitions: s.first)),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '${c.networks.length} × ${c.contextBudgets.length} × '
              '${c.placements.length} × ${c.repetitions} = ${c.totalRuns} runs · '
              'cool-down ≤ ${c.cooldownThresholdCelsius.toStringAsFixed(0)} °C · '
              'SLA ${c.slaMs} ms · ${c.maxOutputTokens} output tokens',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _ProgressCard extends StatelessWidget {
  const _ProgressCard({required this.runner});

  final BenchmarkRunner runner;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final running = runner.isRunning;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${runner.completed} / ${runner.total} runs · '
                    '${runner.elapsed.inMinutes}m ${runner.elapsed.inSeconds % 60}s',
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                running
                    ? OutlinedButton.icon(
                        key: const Key('stop-benchmark'),
                        onPressed: runner.phase == RunnerPhase.running ? runner.cancel : null,
                        icon: const Icon(Icons.stop),
                        label: const Text('Stop'),
                      )
                    : FilledButton.icon(
                        key: const Key('start-benchmark'),
                        onPressed: runner.run,
                        icon: const Icon(Icons.play_arrow),
                        label: const Text('Run benchmark'),
                      ),
              ],
            ),
            const SizedBox(height: 10),
            LinearProgressIndicator(value: running || runner.completed > 0 ? runner.progress : 0),
            const SizedBox(height: 8),
            Text(runner.status, style: theme.textTheme.bodyMedium),
            if (runner.currentCell != null)
              Text(runner.currentCell!, style: theme.textTheme.bodySmall),
            if (runner.error != null)
              Text(runner.error!, style: TextStyle(color: theme.colorScheme.error)),
          ],
        ),
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.runner});

  final BenchmarkRunner runner;

  @override
  Widget build(BuildContext context) {
    final s = runner.summaryJson();
    final overhead = (s['mean_collector_overhead_fraction']! as double) * 100;
    final sources = s['energy_sources']! as Map<String, int>;
    final theme = Theme.of(context);
    return Card(
      color: theme.colorScheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Run summary', style: theme.textTheme.titleMedium),
            const SizedBox(height: 6),
            Text('Device: ${s['device_model']}'),
            Text('Constraint violations: ${s['constraint_violations']} / ${s['runs_completed']}'),
            Text('Failed requests (cloud offline): ${s['failed_requests']}'),
            Text('Telemetry samples logged: ${s['telemetry_samples']} '
                '(${s['telemetry_failed_samples']} failed)'),
            Text('Collector round trip: '
                '${(s['mean_sample_latency_ms']! as double).toStringAsFixed(2)} ms · '
                'overhead ${overhead.toStringAsFixed(2)} % '
                '${overhead < 10 ? '(< 10 % target ✓)' : '(above 10 % target)'}'),
            Text('Energy source: ${sources.entries.where((e) => e.value > 0).map((e) => '${e.key} ×${e.value}').join(', ')}'),
          ],
        ),
      ),
    );
  }
}

class _RunTile extends StatelessWidget {
  const _RunTile({required this.result});

  final RunResult result;

  @override
  Widget build(BuildContext context) {
    final r = result.record;
    final theme = Theme.of(context);
    return ListTile(
      dense: true,
      leading: Icon(
        r.placement == 'cloud' ? Icons.cloud_outlined : Icons.phone_android,
        color: r.constraintViolated ? theme.colorScheme.error : theme.colorScheme.primary,
      ),
      title: Text('${r.networkCondition} · ${r.contextBudget}t · ${r.placement} '
          '· rep ${result.repetition}'),
      subtitle: Text(
        result.failureReason ??
            'TTFT ${r.ttftMs.toStringAsFixed(0)} ms · total ${r.totalLatencyMs.toStringAsFixed(0)} ms · '
                '${r.tokensPerSec.toStringAsFixed(1)} tok/s · ${r.energyMah.toStringAsFixed(3)} mAh · '
                '${r.peakMemoryMb.toStringAsFixed(0)} MB · ${r.tempCelsius.toStringAsFixed(1)} °C',
      ),
      trailing: r.constraintViolated
          ? Icon(Icons.warning_amber, color: theme.colorScheme.error)
          : const Icon(Icons.check_circle_outline, color: Colors.green),
    );
  }
}
