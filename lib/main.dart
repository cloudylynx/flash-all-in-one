import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'core/config.dart';
import 'services/device_provider.dart';
import 'ui/main_shell.dart';
import 'ui/theme/app_theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 从 pubspec 读版本号（必须在 runApp 前，UI 才能显示正确版本）
  await AppConfig.loadVersion();

  runApp(
    ChangeNotifierProvider(
      create: (_) => DeviceProvider(),
      child: const GaojiApp(),
    ),
  );
}

class GaojiApp extends StatelessWidget {
  const GaojiApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: AppConfig.appName,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark(),
      darkTheme: AppTheme.dark(),
      themeMode: ThemeMode.dark,
      home: const MainShell(),
    );
  }
}
