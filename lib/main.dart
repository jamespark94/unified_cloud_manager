import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/database/app_database.dart';
import 'core/transfer/background_service_handler.dart';
import 'core/transfer/transfer_queue_manager.dart';
import 'core/utils/google_auth_manager.dart';
import 'ui/screens/main_shell_screen.dart';
import 'ui/theme/app_theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: AppTheme.scaffoldBg,
      systemNavigationBarIconBrightness: Brightness.light,
      systemNavigationBarDividerColor: Colors.transparent,
    ),
  );

  // 1. Initialize Background Service & Foreground Task
  BackgroundServiceManager.init();

  // 2. Initialize Database & Queue Manager
  await AppDatabase.instance.database;
  await TransferQueueManager.instance.init();

  // 3. Restore previous Google Sign-In session without blocking startup
  try {
    unawaited(GoogleAuthManager().initialize());
  } catch (e) {
    debugPrint('[Main] GoogleAuthManager initialization failed: $e');
  }

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
