import 'package:flutter/material.dart';

import 'src/harness_services.dart';
import 'src/ui/harness_app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final services = await HarnessServices.create();
  runApp(HarnessApp(services: services));
}
