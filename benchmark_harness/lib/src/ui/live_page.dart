import 'dart:async';

import 'package:auraf/auraf_telemetry.dart';
import 'package:flutter/material.dart';

import '../harness_services.dart';
import 'widgets.dart';

/// Live view of the State Collector, refreshed once per second.
class LivePage extends StatefulWidget {
  const LivePage({super.key});

  @override
  State<LivePage> createState() => _LivePageState();
}

class _LivePageState extends State<LivePage> {
  static const int _historyLength = 60;

  StreamSubscription<TelemetrySample>? _sub;
  TelemetrySample? _latest;
  DeviceDescriptor? _device;
  Object? _error;
  bool _logging = false;
  int _logged = 0;
  final List<TelemetrySample> _history = <TelemetrySample>[];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_sub != null) return;
    final services = HarnessScope.of(context);
    services.collector.describeDevice().then(
          (d) => mounted ? setState(() => _device = d) : null,
          onError: (Object e) => mounted ? setState(() => _error = e) : null,
        );
    _sub = services.collector.watch().listen(
      (sample) {
        if (_logging) {
          services.database.logSamples(<TelemetrySample>[sample], runId: 'live');
          _logged++;
        }
        setState(() {
          _latest = sample;
          _error = null;
          _history.add(sample);
          if (_history.length > _historyLength) _history.removeAt(0);
        });
      },
      onError: (Object e) => setState(() => _error = e),
    );
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  List<double> _series(double Function(TelemetrySample) f) =>
      _history.map(f).toList(growable: false);

  @override
  Widget build(BuildContext context) {
    final s = _latest;
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Card(
          child: ListTile(
            leading: Icon(
              _device?.isEmulator ?? false ? Icons.computer : Icons.smartphone,
              color: theme.colorScheme.primary,
            ),
            title: Text(_device?.deviceModel ?? 'Detecting device...'),
            subtitle: Text(
              _device == null
                  ? ''
                  : 'SDK ${_device!.sdkInt} · ${_device!.cpuCores} cores · '
                      '${_device!.hardware}'
                      '${_device!.isEmulator ? ' · emulator' : ''}',
            ),
          ),
        ),
        if (_device?.isEmulator ?? false)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text(
              'Emulator: battery current and temperature are virtual. '
              'Energy readings need a physical phone.',
              style: theme.textTheme.bodySmall,
            ),
          ),
        if (_error != null)
          Card(
            color: theme.colorScheme.errorContainer,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text('Telemetry unavailable: $_error'),
            ),
          ),
        SectionHeader(
          'Device state',
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_logging ? 'Logging ($_logged)' : 'Log to SQLite',
                  style: theme.textTheme.labelMedium),
              Switch(
                key: const Key('live-log-switch'),
                value: _logging,
                onChanged: (v) => setState(() => _logging = v),
              ),
            ],
          ),
        ),
        if (s == null && _error == null)
          const Padding(
            padding: EdgeInsets.all(32),
            child: Center(child: CircularProgressIndicator()),
          ),
        if (s != null)
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            childAspectRatio: 1.45,
            mainAxisSpacing: 4,
            crossAxisSpacing: 4,
            children: [
              MetricTile(
                icon: Icons.battery_std,
                label: 'Battery',
                value: '${s.batteryLevelPercent}',
                unit: s.isCharging ? '% · charging' : '%',
                history: _series((x) => x.batteryLevelPercent.toDouble()),
              ),
              MetricTile(
                icon: Icons.bolt,
                label: 'Battery current',
                value: s.currentAvailable ? s.batteryCurrentMa.toStringAsFixed(0) : '—',
                unit: 'mA',
                note: s.currentAvailable ? null : 'sensor not exposed',
                history: _series((x) => x.batteryCurrentMa),
                color: Colors.orange,
              ),
              MetricTile(
                icon: Icons.thermostat,
                label: 'Temperature',
                value: s.temperatureCelsius.toStringAsFixed(1),
                unit: '°C · ${s.thermalStatusName}',
                history: _series((x) => x.temperatureCelsius),
                color: Colors.redAccent,
              ),
              MetricTile(
                icon: Icons.memory,
                label: 'Available RAM',
                value: s.availableRamMb.toStringAsFixed(0),
                unit: 'of ${s.totalRamMb.toStringAsFixed(0)} MB',
                history: _series((x) => x.availableRamMb),
                color: Colors.teal,
              ),
              MetricTile(
                icon: Icons.apps,
                label: 'App memory (RSS)',
                value: s.rssMb.toStringAsFixed(1),
                unit: 'MB · peak ${s.peakRssMb.toStringAsFixed(0)}',
                history: _series((x) => x.rssMb),
                color: Colors.indigo,
              ),
              MetricTile(
                icon: Icons.network_check,
                label: 'Network',
                value: s.networkCondition.wireName,
                unit: '',
                color: Colors.blueGrey,
              ),
            ],
          ),
        if (s != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'Collector round trip: ${s.sampleLatencyMs.toStringAsFixed(2)} ms · '
              'voltage ${s.batteryVoltageMv} mV · '
              'charge counter ${s.chargeCounterUah == null ? 'n/a' : '${s.chargeCounterUah} µAh'}',
              style: theme.textTheme.bodySmall,
            ),
          ),
      ],
    );
  }
}
