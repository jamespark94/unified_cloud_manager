import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/database/app_database.dart';
import 'core/transfer/background_service_handler.dart';
import 'core/transfer/transfer_queue_manager.dart';
import 'ui/screens/main_shell_screen.dart';
import 'ui/theme/app_theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 1. Initialize Background Service & Foreground Task
  BackgroundServiceManager.init();

  // 2. Initialize Database & Queue Manager
  await AppDatabase.instance.database;
  await TransferQueueManager.instance.init();

  runApp(
    const ProviderScope(
      child: UnifiedCloudManagerApp(),
    ),
  );
}

class UnifiedCloudManagerApp extends StatelessWidget {
  const UnifiedCloudManagerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Unified Cloud Manager',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme,
      home: const MainShellScreen(),
    );
  }
}
