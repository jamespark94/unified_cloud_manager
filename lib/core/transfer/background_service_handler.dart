import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

@pragma('vm:entry-point')
void startCallback() {
  FlutterForegroundTask.setTaskHandler(TransferForegroundTaskHandler());
}

class TransferForegroundTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    debugPrint('[ForegroundTask] Started at $timestamp');
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    // Periodic heartbeat
  }

  @override
  Future<void> onDestroy(DateTime timestamp) async {
    debugPrint('[ForegroundTask] Destroyed at $timestamp');
  }

  @override
  void onReceiveData(Object data) {
    // Receive progress update from UI/TransferQueueManager
    if (data is Map<String, dynamic>) {
      final title = data['title'] as String? ?? '클라우드 파일 전송 중';
      final text = data['text'] as String? ?? '진행 중...';
      FlutterForegroundTask.updateService(
        notificationTitle: title,
        notificationText: text,
      );
    }
  }

  @override
  void onNotificationButtonPressed(String id) {
    debugPrint('[ForegroundTask] Notification button pressed: $id');
  }

  @override
  void onNotificationPressed() {
    FlutterForegroundTask.launchApp();
  }

  @override
  void onNotificationDismissed() {}
}

class BackgroundServiceManager {
  static final BackgroundServiceManager instance = BackgroundServiceManager._();
  BackgroundServiceManager._();

  bool _isRunning = false;
  bool get isRunning => _isRunning;

  static void init() {
    if (kIsWeb || !Platform.isAndroid) return;

    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'unified_cloud_transfer_channel',
        channelName: 'Unified Cloud Transfers',
        channelDescription: 'Ongoing background file transfer status and speed',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(5000),
        autoRunOnBoot: false,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
  }

  Future<void> startServiceIfNeeded() async {
    if (kIsWeb || !Platform.isAndroid || _isRunning) return;

    final serviceStatus = await FlutterForegroundTask.isRunningService;
    if (!serviceStatus) {
      await FlutterForegroundTask.startService(
        serviceId: 256,
        notificationTitle: 'Unified Cloud Manager',
        notificationText: '백그라운드 전송 대기 중...',
        callback: startCallback,
      );
      _isRunning = true;
    }
  }

  Future<void> updateNotification({required String title, required String text}) async {
    if (kIsWeb || !Platform.isAndroid) return;
    FlutterForegroundTask.sendDataToTask({'title': title, 'text': text});
  }

  Future<void> stopServiceIfIdle() async {
    if (kIsWeb || !Platform.isAndroid || !_isRunning) return;
    await FlutterForegroundTask.stopService();
    _isRunning = false;
  }
}
