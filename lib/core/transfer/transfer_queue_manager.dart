import 'dart:async';
import 'dart:math';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import '../cloud/cloud_storage_provider.dart';
import '../cloud/providers/local_storage_provider.dart';
import '../database/app_database.dart';
import '../database/transfer_task_entity.dart';
import '../utils/format_utils.dart';
import 'background_service_handler.dart';
import 'speed_estimator.dart';

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

class _TransferAbortedException implements Exception {
  final bool isCancelled;
  const _TransferAbortedException({required this.isCancelled});
}

class _ActiveTransferControl {
  final CancelToken cancelToken = CancelToken();
  StreamSubscription<List<int>>? subscription;
  StreamController<List<int>>? controller;
  final Completer<void> finished = Completer<void>();
  bool isPaused = false;
  bool isCancelled = false;

  Future<void> abort({required bool cancelled}) async {
    if (cancelled) {
      isCancelled = true;
    } else {
      isPaused = true;
    }

    if (!cancelToken.isCancelled) {
      cancelToken.cancel(cancelled ? 'Task cancelled' : 'Task paused');
    }

    final sub = subscription;
    subscription = null;
    if (sub != null) {
      try {
        await sub.cancel();
      } catch (_) {}
    }

    final ctrl = controller;
    if (ctrl != null && !ctrl.isClosed) {
      if (cancelled) {
        ctrl.addError(_TransferAbortedException(isCancelled: true));
      }
      await ctrl.close();
    }
  }
}

class TransferQueueManager extends ChangeNotifier {
  static final TransferQueueManager instance = TransferQueueManager._();
  TransferQueueManager._();

  final AppDatabase _db = AppDatabase.instance;
  final Map<String, CloudStorageProvider> _providers = {};

  int maxConcurrentTasks = 3;
  final Set<String> _activeTaskIds = {};
  final Set<String> _cancelledTaskIds = {};
  final Map<String, _ActiveTransferControl> _activeControls = {};

  // Realtime granular task progress map (taskId -> TaskProgressInfo)
  final Map<String, TaskProgressInfo> _taskProgressMap = {};
  Map<String, TaskProgressInfo> get taskProgressMap => Map.unmodifiable(_taskProgressMap);

  // Speed calculation metrics (smoothed via sliding window + EMA)
  double currentSpeedBytesPerSec = 0.0;
  final SlidingWindowSpeedEstimator _globalSpeedEstimator = SlidingWindowSpeedEstimator();
  final Map<String, SlidingWindowSpeedEstimator> _taskSpeedEstimators = {};
  final Map<String, int> _lastRecordedTaskBytes = {};
  Timer? _speedMeterTimer;
  double _lastNotifiedGlobalSpeed = 0.0;

  int _taskListVersion = 0;
  int get taskListVersion => _taskListVersion;

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
    _taskSpeedEstimators.clear();
    _lastRecordedTaskBytes.clear();
    _globalSpeedEstimator.reset();
    currentSpeedBytesPerSec = 0.0;
    _lastNotifiedGlobalSpeed = 0.0;

    // 2. Restore progress map so UI shows persisted transferredBytes immediately
    _taskProgressMap.clear();
    final existingTasks = await _db.getAllTasks();
    for (final task in existingTasks) {
      _taskProgressMap[task.id] = TaskProgressInfo(
        transferredBytes: task.transferredBytes,
        totalBytes: task.totalBytes,
        speedBytesPerSec: 0.0,
        status: task.status,
      );
    }
    _taskListVersion++;

    // 3. Start speed calculator loop (every 500ms)
    _speedMeterTimer?.cancel();
    _speedMeterTimer = Timer.periodic(const Duration(milliseconds: 500), (_) => _calculateGlobalSpeed());

    // 4. Only process immediately if providers are already registered;
    // otherwise AccountsNotifier.loadAccounts() triggers processQueue() once ready.
    if (_providers.isNotEmpty) {
      processQueue();
    }
  }

  void _calculateGlobalSpeed() {
    if (_activeTaskIds.isEmpty) {
      _globalSpeedEstimator.reset();
      currentSpeedBytesPerSec = 0.0;
      if (_lastNotifiedGlobalSpeed != 0.0) {
        _lastNotifiedGlobalSpeed = 0.0;
        notifyListeners();
      }
      return;
    }

    currentSpeedBytesPerSec = _globalSpeedEstimator.tick();
    for (final taskId in _activeTaskIds) {
      final estimator = _taskSpeedEstimators[taskId];
      final existing = _taskProgressMap[taskId];
      if (estimator != null && existing != null && existing.status == TransferStatus.active) {
        final nextSpeed = estimator.tick();
        _taskProgressMap[taskId] = TaskProgressInfo(
          transferredBytes: existing.transferredBytes,
          totalBytes: existing.totalBytes,
          speedBytesPerSec: nextSpeed,
          status: existing.status,
        );
      }
    }

    _lastNotifiedGlobalSpeed = currentSpeedBytesPerSec;
    notifyListeners();
  }

  Future<void> enqueueTask(TransferTask task) async {
    await _db.deleteMatchingPausedTasks(task);
    await _db.insertTask(task);
    _taskProgressMap[task.id] = TaskProgressInfo(
      transferredBytes: task.transferredBytes,
      totalBytes: task.totalBytes,
      speedBytesPerSec: 0.0,
      status: task.status,
    );
    _taskListVersion++;
    notifyListeners();
    processQueue();
  }

  Future<void> enqueueBatch(List<TransferTask> tasks) async {
    for (final task in tasks) {
      await _db.deleteMatchingPausedTasks(task);
    }
    await _db.insertTasksBatch(tasks);
    for (final task in tasks) {
      _taskProgressMap[task.id] = TaskProgressInfo(
        transferredBytes: task.transferredBytes,
        totalBytes: task.totalBytes,
        speedBytesPerSec: 0.0,
        status: task.status,
      );
    }
    _taskListVersion++;
    notifyListeners();
    processQueue();
  }

  Future<void> pauseTask(String taskId) async {
    final control = _activeControls[taskId];
    _taskSpeedEstimators.remove(taskId);
    _lastRecordedTaskBytes.remove(taskId);
    if (_taskProgressMap.containsKey(taskId)) {
      final old = _taskProgressMap[taskId]!;
      _taskProgressMap[taskId] = TaskProgressInfo(
        transferredBytes: old.transferredBytes,
        totalBytes: old.totalBytes,
        speedBytesPerSec: 0,
        status: TransferStatus.paused,
      );
    }
    notifyListeners();

    if (control != null) {
      await control.abort(cancelled: false);
      await control.finished.future.timeout(const Duration(seconds: 5), onTimeout: () {});
    }

    _activeTaskIds.remove(taskId);
    await _db.updateTaskStatus(taskId, TransferStatus.paused);
    if (_activeTaskIds.isEmpty) {
      _globalSpeedEstimator.reset();
      currentSpeedBytesPerSec = 0.0;
      await BackgroundServiceManager.instance.stopServiceIfIdle();
    }
    notifyListeners();
    processQueue();
  }

  Future<void> resumeTask(String taskId) async {
    _cancelledTaskIds.remove(taskId);
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
    _cancelledTaskIds.add(taskId);
    _taskSpeedEstimators.remove(taskId);
    _lastRecordedTaskBytes.remove(taskId);
    final task = await _db.getTaskById(taskId);
    final control = _activeControls[taskId];

    _activeTaskIds.remove(taskId);
    _taskProgressMap.remove(taskId);
    _taskListVersion++;
    notifyListeners();

    if (control != null) {
      await control.abort(cancelled: true);
      await control.finished.future.timeout(const Duration(seconds: 5), onTimeout: () {});
    }

    if (task != null) {
      await _deleteLocalPartialFileForTask(task);
    }

    await _db.deleteTask(taskId);
    if (_activeTaskIds.isEmpty) {
      _globalSpeedEstimator.reset();
      currentSpeedBytesPerSec = 0.0;
      await BackgroundServiceManager.instance.stopServiceIfIdle();
    }
    notifyListeners();
    processQueue();
  }

  Future<void> cancelAll() async {
    final dbTasks = await _db.getAllTasks();
    final incompleteTasks = dbTasks
        .where(
          (t) =>
              t.status == TransferStatus.pending ||
              t.status == TransferStatus.active ||
              t.status == TransferStatus.paused,
        )
        .toList();

    for (final t in incompleteTasks) {
      _cancelledTaskIds.add(t.id);
      _taskSpeedEstimators.remove(t.id);
      _lastRecordedTaskBytes.remove(t.id);
    }
    _cancelledTaskIds.addAll(_activeTaskIds);

    final controls = _activeControls.values.toList();
    _activeTaskIds.clear();
    _taskProgressMap.removeWhere(
      (_, p) =>
          p.status == TransferStatus.pending ||
          p.status == TransferStatus.active ||
          p.status == TransferStatus.paused,
    );
    _globalSpeedEstimator.reset();
    currentSpeedBytesPerSec = 0.0;
    _taskListVersion++;
    notifyListeners();

    await Future.wait(controls.map((c) => c.abort(cancelled: true)));
    await Future.wait(
      controls.map((c) => c.finished.future.timeout(const Duration(seconds: 5), onTimeout: () {})),
    );

    for (final t in incompleteTasks) {
      await _deleteLocalPartialFileForTask(t);
    }

    await _db.cancelIncompleteTasks();
    await BackgroundServiceManager.instance.stopServiceIfIdle();
    notifyListeners();
  }

  Future<void> pauseAll() async {
    await _db.pauseAllPendingAndActiveTasks();
    for (final entry in _taskProgressMap.entries.toList()) {
      if (entry.value.status == TransferStatus.active ||
          entry.value.status == TransferStatus.pending) {
        _taskSpeedEstimators.remove(entry.key);
        _lastRecordedTaskBytes.remove(entry.key);
        _taskProgressMap[entry.key] = TaskProgressInfo(
          transferredBytes: entry.value.transferredBytes,
          totalBytes: entry.value.totalBytes,
          speedBytesPerSec: 0,
          status: TransferStatus.paused,
        );
      }
    }
    notifyListeners();

    final controls = _activeControls.values.toList();
    await Future.wait(controls.map((c) => c.abort(cancelled: false)));
    await Future.wait(
      controls.map((c) => c.finished.future.timeout(const Duration(seconds: 5), onTimeout: () {})),
    );
    _activeTaskIds.clear();
    _globalSpeedEstimator.reset();
    currentSpeedBytesPerSec = 0.0;
    await BackgroundServiceManager.instance.stopServiceIfIdle();
    notifyListeners();
  }

  Future<void> resumeAll() async {
    final tasks = await _db.getAllTasks();
    for (final t in tasks) {
      if (t.status == TransferStatus.paused) {
        _cancelledTaskIds.remove(t.id);
        await _db.updateTaskStatus(t.id, TransferStatus.pending);
        if (_taskProgressMap.containsKey(t.id)) {
          final old = _taskProgressMap[t.id]!;
          _taskProgressMap[t.id] = TaskProgressInfo(
            transferredBytes: old.transferredBytes,
            totalBytes: old.totalBytes,
            speedBytesPerSec: 0,
            status: TransferStatus.pending,
          );
        }
      }
    }
    notifyListeners();
    processQueue();
  }

  Future<void> pauseGroup(String groupId) async {
    final tasks = await _db.getTasksByGroupId(groupId);
    await _db.pauseGroupTasks(groupId);
    final activeControlsToAbort = <_ActiveTransferControl>[];

    for (final t in tasks) {
      final info = _taskProgressMap[t.id];
      final status = info?.status ?? t.status;
      if (status == TransferStatus.active || status == TransferStatus.pending) {
        _taskSpeedEstimators.remove(t.id);
        _lastRecordedTaskBytes.remove(t.id);
        _activeTaskIds.remove(t.id);
        final ctrl = _activeControls[t.id];
        if (ctrl != null) {
          activeControlsToAbort.add(ctrl);
        }
        _taskProgressMap[t.id] = TaskProgressInfo(
          transferredBytes: info?.transferredBytes ?? t.transferredBytes,
          totalBytes: info?.totalBytes ?? t.totalBytes,
          speedBytesPerSec: 0.0,
          status: TransferStatus.paused,
        );
      }
    }
    _taskListVersion++;
    notifyListeners();

    await Future.wait(activeControlsToAbort.map((c) => c.abort(cancelled: false)));
    await Future.wait(
      activeControlsToAbort.map((c) => c.finished.future.timeout(const Duration(seconds: 5), onTimeout: () {})),
    );

    if (_activeTaskIds.isEmpty) {
      _globalSpeedEstimator.reset();
      currentSpeedBytesPerSec = 0.0;
      await BackgroundServiceManager.instance.stopServiceIfIdle();
    }
    notifyListeners();
    processQueue();
  }

  Future<void> resumeGroup(String groupId) async {
    final tasks = await _db.getTasksByGroupId(groupId);
    for (final t in tasks) {
      final status = _taskProgressMap[t.id]?.status ?? t.status;
      if (status == TransferStatus.paused || status == TransferStatus.failed) {
        _cancelledTaskIds.remove(t.id);
        await _db.updateTaskStatus(t.id, TransferStatus.pending, retryCount: 0);
        final old = _taskProgressMap[t.id];
        _taskProgressMap[t.id] = TaskProgressInfo(
          transferredBytes: old?.transferredBytes ?? t.transferredBytes,
          totalBytes: old?.totalBytes ?? t.totalBytes,
          speedBytesPerSec: 0.0,
          status: TransferStatus.pending,
        );
      }
    }
    _taskListVersion++;
    notifyListeners();
    processQueue();
  }

  Future<void> cancelGroup(String groupId) async {
    final tasks = await _db.getTasksByGroupId(groupId);
    final incompleteTasks = tasks.where((t) {
      final status = _taskProgressMap[t.id]?.status ?? t.status;
      return status == TransferStatus.pending ||
          status == TransferStatus.active ||
          status == TransferStatus.paused;
    }).toList();

    final controlsToAbort = <_ActiveTransferControl>[];
    for (final t in incompleteTasks) {
      _cancelledTaskIds.add(t.id);
      _taskSpeedEstimators.remove(t.id);
      _lastRecordedTaskBytes.remove(t.id);
      _activeTaskIds.remove(t.id);
      _taskProgressMap.remove(t.id);
      final ctrl = _activeControls[t.id];
      if (ctrl != null) {
        controlsToAbort.add(ctrl);
      }
    }
    _taskListVersion++;
    notifyListeners();

    await Future.wait(controlsToAbort.map((c) => c.abort(cancelled: true)));
    await Future.wait(
      controlsToAbort.map((c) => c.finished.future.timeout(const Duration(seconds: 5), onTimeout: () {})),
    );

    for (final t in incompleteTasks) {
      await _deleteLocalPartialFileForTask(t);
    }

    await _db.cancelGroupIncompleteTasks(groupId);
    if (_activeTaskIds.isEmpty) {
      _globalSpeedEstimator.reset();
      currentSpeedBytesPerSec = 0.0;
      await BackgroundServiceManager.instance.stopServiceIfIdle();
    }
    notifyListeners();
    processQueue();
  }

  Future<void> removeGroup(String groupId) async {
    await cancelGroup(groupId);
    final tasks = await _db.getTasksByGroupId(groupId);
    for (final t in tasks) {
      _taskProgressMap.remove(t.id);
    }
    await _db.deleteGroupTasks(groupId);
    _taskListVersion++;
    notifyListeners();
  }

  Future<void> clearCompleted() async {
    await _db.clearCompletedTasks();
    _taskProgressMap.removeWhere((_, p) => p.status == TransferStatus.completed || p.status == TransferStatus.failed);
    _taskListVersion++;
    notifyListeners();
  }

  Future<void> _deleteLocalPartialFileForTask(TransferTask task) async {
    final dstProvider = _providers[task.destAccountId];
    if (dstProvider is LocalStorageProvider) {
      try {
        await dstProvider.deletePartialFile(
          parentId: task.destinationPath,
          fileName: task.fileName,
        );
      } catch (e) {
        debugPrint('[TransferQueue] Failed to delete partial file for ${task.fileName}: $e');
      }
    }
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
        await _db.updateTaskStatus(nextTask.id, TransferStatus.active);
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
    _cancelledTaskIds.remove(task.id);
    final control = _ActiveTransferControl();
    _activeControls[task.id] = control;

    int transferred = task.transferredBytes;
    int total = task.totalBytes;

    try {
      if (_cancelledTaskIds.contains(task.id) || control.isCancelled || control.isPaused) {
        return;
      }

      _taskProgressMap[task.id] = TaskProgressInfo(
        transferredBytes: transferred,
        totalBytes: total,
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

      int existingBytes = 0;
      if (dstProvider is LocalStorageProvider) {
        existingBytes = await dstProvider.getResumableBytes(
          parentId: task.destinationPath,
          fileName: task.fileName,
          expectedTotalBytes: total,
          recordedTransferredBytes: task.transferredBytes,
        );
        if (control.isCancelled || control.isPaused || _cancelledTaskIds.contains(task.id)) {
          return;
        }
        if (total > 0 && existingBytes == total) {
          await dstProvider.finalizePartialFile(
            parentId: task.destinationPath,
            fileName: task.fileName,
          );
          await _markCompleted(task, total, total);
          return;
        }
      }

      int actualStartByte = 0;
      final rawStream = await srcProvider.downloadStream(
        fileId: task.sourcePath,
        startByte: existingBytes > 0 ? existingBytes : null,
        cancelToken: control.cancelToken,
        onActualStartByte: (offset) {
          actualStartByte = offset;
        },
      );

      if (control.isCancelled || control.isPaused || _cancelledTaskIds.contains(task.id)) {
        await _drainCancelStream(rawStream);
        return;
      }

      transferred = actualStartByte;
      _lastRecordedTaskBytes[task.id] = actualStartByte;
      _taskSpeedEstimators[task.id] = SlidingWindowSpeedEstimator();
      DateTime lastNotifyTime = DateTime.now();
      DateTime lastDbWriteTime = DateTime.now();

      if (transferred != task.transferredBytes) {
        _taskProgressMap[task.id] = TaskProgressInfo(
          transferredBytes: transferred,
          totalBytes: total,
          speedBytesPerSec: 0.0,
          status: TransferStatus.active,
        );
        await _db.updateTaskProgress(
          id: task.id,
          transferredBytes: transferred,
          totalBytes: total,
          status: TransferStatus.active,
        );
        notifyListeners();
      }

      if (control.isCancelled || control.isPaused || _cancelledTaskIds.contains(task.id)) {
        await _drainCancelStream(rawStream);
        return;
      }

      late final StreamController<List<int>> controller;
      controller = StreamController<List<int>>(
        onPause: () => control.subscription?.pause(),
        onResume: () => control.subscription?.resume(),
        onCancel: () async {
          final sub = control.subscription;
          control.subscription = null;
          if (sub != null) {
            await sub.cancel();
          }
        },
      );
      control.controller = controller;
      control.subscription = rawStream.listen(
        (chunk) {
          if (!controller.isClosed) {
            controller.add(chunk);
          }
        },
        onError: (Object error, StackTrace stackTrace) {
          if (!controller.isClosed) {
            controller.addError(error, stackTrace);
            controller.close();
          }
        },
        onDone: () {
          if (!controller.isClosed) {
            controller.close();
          }
        },
        cancelOnError: true,
      );

      // Throttled progress callback with smoothed byte-delta tracking
      void onProgress(int bytesSent, int totalBytes) {
        if (control.isCancelled || control.isPaused || _cancelledTaskIds.contains(task.id)) {
          return;
        }
        transferred = bytesSent;
        if (totalBytes > 0) total = totalBytes;

        final prevRecorded = _lastRecordedTaskBytes[task.id] ?? actualStartByte;
        final delta = transferred - prevRecorded;
        if (delta > 0) {
          _lastRecordedTaskBytes[task.id] = transferred;
          _taskSpeedEstimators[task.id]?.recordBytes(delta);
          _globalSpeedEstimator.recordBytes(delta);
        }

        final taskSpeed = _taskSpeedEstimators[task.id]?.currentSpeed ?? 0.0;
        _taskProgressMap[task.id] = TaskProgressInfo(
          transferredBytes: transferred,
          totalBytes: total,
          speedBytesPerSec: taskSpeed,
          status: TransferStatus.active,
        );

        final now = DateTime.now();
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

        // Throttle UI notifications to avoid rebuilding on every small socket chunk
        if (now.difference(lastNotifyTime).inMilliseconds >= 200) {
          lastNotifyTime = now;
          notifyListeners();
        }
      }

      if (dstProvider is LocalStorageProvider) {
        await dstProvider.uploadStream(
          parentId: task.destinationPath,
          fileName: task.fileName,
          stream: controller.stream,
          length: total > 0 ? total : 0,
          onProgress: onProgress,
          startByte: actualStartByte,
          shouldFinalize: () => !control.isCancelled && !control.isPaused,
        );
      } else {
        await dstProvider.uploadStream(
          parentId: task.destinationPath,
          fileName: task.fileName,
          stream: controller.stream,
          length: total > 0 ? total : 0,
          onProgress: onProgress,
        );
      }

      if (control.isCancelled || _cancelledTaskIds.contains(task.id)) return;

      if (control.isPaused) {
        await _savePausedState(task.id, transferred, total);
        return;
      }

      if (total > 0 && transferred < total) {
        throw Exception(
          '전송이 불완전하게 종료되었습니다 ($transferred / $total bytes)',
        );
      }

      await _markCompleted(task, total, transferred);
    } catch (e) {
      if (control.isCancelled || _cancelledTaskIds.contains(task.id)) {
        return;
      }
      if (control.isPaused) {
        await _savePausedState(task.id, transferred, total);
        return;
      }
      debugPrint('[TransferQueue] Error on task ${task.id}: $e');
      if (task.retryCount < 5) {
        final backoffDelay = pow(2, task.retryCount) as int;
        await _db.updateTaskProgress(
          id: task.id,
          transferredBytes: transferred,
          totalBytes: total,
          status: TransferStatus.pending,
          errorMessage: '일시적 오류: $e ($backoffDelay초 후 재시도)',
        );
        await _db.updateTaskStatus(
          task.id,
          TransferStatus.pending,
          errorMessage: '일시적 오류: $e ($backoffDelay초 후 재시도)',
          retryCount: task.retryCount + 1,
        );
        _taskProgressMap[task.id] = TaskProgressInfo(
          transferredBytes: transferred,
          totalBytes: total,
          speedBytesPerSec: 0.0,
          status: TransferStatus.pending,
        );
        _activeTaskIds.remove(task.id);
        _taskListVersion++;
        notifyListeners();
        Future.delayed(Duration(seconds: backoffDelay), () => processQueue());
      } else {
        await _failTask(task.copyWith(transferredBytes: transferred, totalBytes: total), e.toString());
      }
    } finally {
      final sub = control.subscription;
      control.subscription = null;
      if (sub != null) {
        try {
          await sub.cancel();
        } catch (_) {}
      }
      final ctrl = control.controller;
      if (ctrl != null && !ctrl.isClosed) {
        try {
          await ctrl.close();
        } catch (_) {}
      }
      _activeControls.remove(task.id);
      _activeTaskIds.remove(task.id);
      _taskSpeedEstimators.remove(task.id);
      _lastRecordedTaskBytes.remove(task.id);
      if (!control.finished.isCompleted) {
        control.finished.complete();
      }
      notifyListeners();
    }
  }

  Future<void> _drainCancelStream(Stream<List<int>> stream) async {
    try {
      final sub = stream.listen((_) {}, onError: (_) {});
      await sub.cancel();
    } catch (_) {}
  }

  Future<void> _savePausedState(String taskId, int transferred, int total) async {
    _taskSpeedEstimators.remove(taskId);
    _lastRecordedTaskBytes.remove(taskId);
    await _db.updateTaskProgress(
      id: taskId,
      transferredBytes: transferred,
      totalBytes: total,
      status: TransferStatus.paused,
    );
    _taskProgressMap[taskId] = TaskProgressInfo(
      transferredBytes: transferred,
      totalBytes: total,
      speedBytesPerSec: 0.0,
      status: TransferStatus.paused,
    );
  }

  Future<void> _markCompleted(TransferTask task, int total, int transferred) async {
    final finalBytes = total > 0 ? total : transferred;
    _taskSpeedEstimators.remove(task.id);
    _lastRecordedTaskBytes.remove(task.id);
    await _db.updateTaskProgress(
      id: task.id,
      transferredBytes: finalBytes,
      totalBytes: finalBytes,
      status: TransferStatus.completed,
    );
    _taskProgressMap[task.id] = TaskProgressInfo(
      transferredBytes: finalBytes,
      totalBytes: finalBytes,
      speedBytesPerSec: 0.0,
      status: TransferStatus.completed,
    );
    _activeTaskIds.remove(task.id);
    _taskListVersion++;
    notifyListeners();
    processQueue();
  }

  Future<void> _failTask(TransferTask task, String error) async {
    _activeTaskIds.remove(task.id);
    _taskSpeedEstimators.remove(task.id);
    _lastRecordedTaskBytes.remove(task.id);
    _taskProgressMap[task.id] = TaskProgressInfo(
      transferredBytes: task.transferredBytes,
      totalBytes: task.totalBytes,
      speedBytesPerSec: 0.0,
      status: TransferStatus.failed,
    );
    await _db.updateTaskProgress(
      id: task.id,
      transferredBytes: task.transferredBytes,
      totalBytes: task.totalBytes,
      status: TransferStatus.failed,
      errorMessage: error,
    );
    _taskListVersion++;
    notifyListeners();
    processQueue();
  }
}
