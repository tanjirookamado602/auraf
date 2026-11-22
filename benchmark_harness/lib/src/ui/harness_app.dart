import 'package:flutter/material.dart';

import '../harness_services.dart';
import 'benchmark_page.dart';
import 'live_page.dart';
import 'results_page.dart';

class HarnessApp extends StatelessWidget {
  const HarnessApp({super.key, required this.services});

  final HarnessServices services;

  @override
  Widget build(BuildContext context) {
    ThemeData theme(Brightness b) => ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1E5AA8), brightness: b),
          useMaterial3: true,
        );
    return HarnessScope(
      services: services,
      child: MaterialApp(
        title: 'AURAF Harness',
        debugShowCheckedModeBanner: false,
        theme: theme(Brightness.light),
        darkTheme: theme(Brightness.dark),
        home: const HarnessHome(),
      ),
    );
  }
}

class HarnessHome extends StatefulWidget {
  const HarnessHome({super.key});

  @override
  State<HarnessHome> createState() => _HarnessHomeState();
}

class _HarnessHomeState extends State<HarnessHome> {
  int _tab = 0;

  static const _titles = ['Live telemetry', 'Benchmark', 'Results'];

  @override
  Widget build(BuildContext context) {
    // Pages are rebuilt on tab switch on purpose: the live monitor stops
    // polling while a benchmark runs, so it does not add collector load.
    final body = switch (_tab) {
      0 => const LivePage(),
      1 => const BenchmarkPage(),
      _ => const ResultsPage(),
    };
    return Scaffold(
      appBar: AppBar(
        title: Text('AURAF · ${_titles[_tab]}'),
        centerTitle: false,
      ),
      body: SafeArea(child: body),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(
            key: Key('nav-live'),
            icon: Icon(Icons.monitor_heart_outlined),
            selectedIcon: Icon(Icons.monitor_heart),
            label: 'Live',
          ),
          NavigationDestination(
            key: Key('nav-benchmark'),
            icon: Icon(Icons.speed_outlined),
            selectedIcon: Icon(Icons.speed),
            label: 'Benchmark',
          ),
          NavigationDestination(
            key: Key('nav-results'),
            icon: Icon(Icons.table_chart_outlined),
            selectedIcon: Icon(Icons.table_chart),
            label: 'Results',
          ),
        ],
      ),
    );
  }
}
