import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import '../cloud/cloud_storage_provider.dart';
import '../database/app_database.dart';
import '../database/transfer_task_entity.dart';
import '../utils/format_utils.dart';
import 'background_service_handler.dart';

class TaskProgressInfo {
  final int transferredBytes;
  final int totalBytes;
  final double speedBytesPerSec;
  final TransferStatus status;

  const TaskProgressInfo({
    required this.transferredBytes,
    required this.totalBytes,
    required this.speedBytesPerSec,
    required this.status,
  });

  double get progress => totalBytes > 0 ? (transferredBytes / totalBytes).clamp(0.0, 1.0) : 0.0;
}

class TransferQueueManager extends ChangeNotifier {
  static final TransferQueueManager instance = TransferQueueManager._();
  TransferQueueManager._();

  final AppDatabase _db = AppDatabase.instance;
  final Map<String, CloudStorageProvider> _providers = {};

  int maxConcurrentTasks = 3;
  final Set<String> _activeTaskIds = {};
  final Map<String, StreamSubscription> _subscriptions = {};

  // Realtime granular task progress map (taskId -> TaskProgressInfo)
  final Map<String, TaskProgressInfo> _taskProgressMap = {};
  Map<String, TaskProgressInfo> get taskProgressMap => Map.unmodifiable(_taskProgressMap);

  // Speed calculation metrics
  double currentSpeedBytesPerSec = 0.0;
  int _lastCumulativeBytes = 0;
  DateTime _lastSpeedCalcTime = DateTime.now();
  Timer? _speedMeterTimer;

  bool _isProcessing = false;

  void registerProvider(CloudStorageProvider provider) {
    _providers[provider.providerId] = provider;
  }

  void unregisterProvider(String providerId) {
    _providers.remove(providerId);
  }

  CloudStorageProvider? getProvider(String providerId) => _providers[providerId];

  Future<void> init() async {
    // 1. Reset interrupted active tasks to pending
    await _db.resetInterruptedActiveTasks();

    // 2. Start speed calculator loop (every 500ms)
    _speedMeterTimer?.cancel();
    _speedMeterTimer = Timer.periodic(const Duration(milliseconds: 500), (_) => _calculateGlobalSpeed());

    // 3. Trigger queue process
    processQueue();
  }

  void _calculateGlobalSpeed() {
    final now = DateTime.now();
    final elapsedSec = now.difference(_lastSpeedCalcTime).inMilliseconds / 1000.0;
    if (elapsedSec <= 0.1) return;

    if (_activeTaskIds.isEmpty) {
      currentSpeedBytesPerSec = 0.0;
      _lastCumulativeBytes = 0;
    } else {
      int currentTotal = 0;
      for (final p in _taskProgressMap.values) {
        if (p.status == TransferStatus.active) {
          currentTotal += p.transferredBytes;
        }
      }

      if (_lastCumulativeBytes > 0 && currentTotal >= _lastCumulativeBytes) {
        final diff = currentTotal - _lastCumulativeBytes;
        currentSpeedBytesPerSec = diff / elapsedSec;
      }
      _lastCumulativeBytes = currentTotal;
    }

    _lastSpeedCalcTime = now;
    notifyListeners();
  }

  Future<void> enqueueTask(TransferTask task) async {
    await _db.insertTask(task);
    _taskProgressMap[task.id] = TaskProgressInfo(
      transferredBytes: task.transferredBytes,
      totalBytes: task.totalBytes,
      speedBytesPerSec: 0.0,
      status: task.status,
    );
    notifyListeners();
    processQueue();
  }

  Future<void> enqueueBatch(List<TransferTask> tasks) async {
    await _db.insertTasksBatch(tasks);
    for (final task in tasks) {
      _taskProgressMap[task.id] = TaskProgressInfo(
        transferredBytes: task.transferredBytes,
        totalBytes: task.totalBytes,
        speedBytesPerSec: 0.0,
        status: task.status,
      );
    }
    notifyListeners();
    processQueue();
  }

  Future<void> pauseTask(String taskId) async {
    _subscriptions[taskId]?.cancel();
    _subscriptions.remove(taskId);
    _activeTaskIds.remove(taskId);
    if (_taskProgressMap.containsKey(taskId)) {
      final old = _taskProgressMap[taskId]!;
      _taskProgressMap[taskId] = TaskProgressInfo(
        transferredBytes: old.transferredBytes,
        totalBytes: old.totalBytes,
        speedBytesPerSec: 0,
        status: TransferStatus.paused,
      );
    }
    await _db.updateTaskStatus(taskId, TransferStatus.paused);
    notifyListeners();
    processQueue();
  }

  Future<void> resumeTask(String taskId) async {
    if (_taskProgressMap.containsKey(taskId)) {
      final old = _taskProgressMap[taskId]!;
      _taskProgressMap[taskId] = TaskProgressInfo(
        transferredBytes: old.transferredBytes,
        totalBytes: old.totalBytes,
        speedBytesPerSec: 0,
        status: TransferStatus.pending,
      );
    }
    await _db.updateTaskStatus(taskId, TransferStatus.pending);
    notifyListeners();
    processQueue();
  }

  Future<void> cancelTask(String taskId) async {
    _subscriptions[taskId]?.cancel();
    _subscriptions.remove(taskId);
    _activeTaskIds.remove(taskId);
    _taskProgressMap.remove(taskId);
    await _db.deleteTask(taskId);
    notifyListeners();
    processQueue();
  }

  Future<void> pauseAll() async {
    for (final id in _activeTaskIds.toList()) {
      await pauseTask(id);
    }
  }

  Future<void> resumeAll() async {
    final tasks = await _db.getAllTasks();
    for (final t in tasks) {
      if (t.status == TransferStatus.paused) {
        await _db.updateTaskStatus(t.id, TransferStatus.pending);
      }
    }
    notifyListeners();
    processQueue();
  }

  Future<void> clearCompleted() async {
    await _db.clearCompletedTasks();
    _taskProgressMap.removeWhere((_, p) => p.status == TransferStatus.completed || p.status == TransferStatus.failed);
    notifyListeners();
  }

  /// 큐 처리 메인 루프 (최대 3개 동시 실행)
  Future<void> processQueue() async {
    if (_isProcessing) return;
    _isProcessing = true;

    try {
      while (_activeTaskIds.length < maxConcurrentTasks) {
        final nextTask = await _db.getNextPendingTask();
        if (nextTask == null) break;

        if (_activeTaskIds.contains(nextTask.id)) break;

        _activeTaskIds.add(nextTask.id);
        await BackgroundServiceManager.instance.startServiceIfNeeded();
        _executeTask(nextTask);
      }
    } finally {
      _isProcessing = false;
      if (_activeTaskIds.isEmpty) {
        await BackgroundServiceManager.instance.stopServiceIfIdle();
      }
      notifyListeners();
    }
  }

  Future<void> _executeTask(TransferTask task) async {
    await _db.updateTaskStatus(task.id, TransferStatus.active);
    _taskProgressMap[task.id] = TaskProgressInfo(
      transferredBytes: task.transferredBytes,
      totalBytes: task.totalBytes,
      speedBytesPerSec: 0.0,
      status: TransferStatus.active,
    );
    notifyListeners();

    final srcProvider = _providers[task.sourceAccountId];
    final dstProvider = _providers[task.destAccountId];

    if (srcProvider == null || dstProvider == null) {
      await _failTask(task, '스토리지 제공자를 찾을 수 없습니다.');
      return;
    }

    try {
      int transferred = task.transferredBytes;
      int total = task.totalBytes;
      int lastTaskBytes = transferred;
      DateTime lastSpeedTime = DateTime.now();
      DateTime lastDbWriteTime = DateTime.now();

      final stream = await srcProvider.downloadStream(
        fileId: task.sourcePath,
        startByte: transferred > 0 ? transferred : null,
      );

      // Throttled progress callback
      void onProgress(int bytesSent, int totalBytes) {
        transferred = bytesSent;
        if (totalBytes > 0) total = totalBytes;

        final now = DateTime.now();
        final elapsed = now.difference(lastSpeedTime).inMilliseconds / 1000.0;
        double taskSpeed = 0.0;
        if (elapsed >= 0.5) {
          taskSpeed = (transferred - lastTaskBytes) / elapsed;
          lastTaskBytes = transferred;
          lastSpeedTime = now;
        }

        _taskProgressMap[task.id] = TaskProgressInfo(
          transferredBytes: transferred,
          totalBytes: total,
          speedBytesPerSec: taskSpeed > 0 ? taskSpeed : (_taskProgressMap[task.id]?.speedBytesPerSec ?? 0.0),
          status: TransferStatus.active,
        );

        // SQLite write throttled to once every 1000ms
        if (now.difference(lastDbWriteTime).inMilliseconds >= 1000) {
          lastDbWriteTime = now;
          _db.updateTaskProgress(
            id: task.id,
            transferredBytes: transferred,
            totalBytes: total,
            status: TransferStatus.active,
          );

          // Update Notification
          final percent = total > 0 ? ((transferred / total) * 100).toStringAsFixed(1) : '0';
          BackgroundServiceManager.instance.updateNotification(
            title: '전송 중: ${task.fileName}',
            text: '$percent% (${FormatUtils.formatBytes(transferred)} / ${FormatUtils.formatBytes(total)})',
          );
        }
        notifyListeners();
      }

      await dstProvider.uploadStream(
        parentId: task.destinationPath,
        fileName: task.fileName,
        stream: stream,
        length: total > 0 ? total : 0,
        onProgress: onProgress,
      );

      // Mark completed
      await _db.updateTaskProgress(
        id: task.id,
        transferredBytes: total > 0 ? total : transferred,
        totalBytes: total > 0 ? total : transferred,
        status: TransferStatus.completed,
      );

      _taskProgressMap[task.id] = TaskProgressInfo(
        transferredBytes: total > 0 ? total : transferred,
        totalBytes: total > 0 ? total : transferred,
        speedBytesPerSec: 0.0,
        status: TransferStatus.completed,
      );

      _activeTaskIds.remove(task.id);
      notifyListeners();
      processQueue();
    } catch (e) {
      debugPrint('[TransferQueue] Error on task ${task.id}: $e');
      if (task.retryCount < 5) {
        final backoffDelay = pow(2, task.retryCount) as int;
        await _db.updateTaskStatus(
          task.id,
          TransferStatus.pending,
          errorMessage: '일시적 오류: $e ($backoffDelay초 후 재시도)',
          retryCount: task.retryCount + 1,
        );
        _taskProgressMap[task.id] = TaskProgressInfo(
          transferredBytes: task.transferredBytes,
          totalBytes: task.totalBytes,
          speedBytesPerSec: 0.0,
          status: TransferStatus.pending,
        );
        _activeTaskIds.remove(task.id);
        notifyListeners();
        Future.delayed(Duration(seconds: backoffDelay), () => processQueue());
      } else {
        await _failTask(task, e.toString());
      }
    }
  }

  Future<void> _failTask(TransferTask task, String error) async {
    _activeTaskIds.remove(task.id);
    _taskProgressMap[task.id] = TaskProgressInfo(
      transferredBytes: task.transferredBytes,
      totalBytes: task.totalBytes,
      speedBytesPerSec: 0.0,
      status: TransferStatus.failed,
    );
    await _db.updateTaskStatus(task.id, TransferStatus.failed, errorMessage: error);
    notifyListeners();
    processQueue();
  }
}
