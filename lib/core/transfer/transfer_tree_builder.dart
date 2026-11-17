import '../database/transfer_task_entity.dart';
import '../utils/sort_utils.dart';
import 'transfer_queue_manager.dart';

sealed class TransferDashboardEntry {
  const TransferDashboardEntry();
}

class TransferGroupEntry extends TransferDashboardEntry {
  final TransferGroupSummary group;
  const TransferGroupEntry(this.group);
}

class TransferSingleTaskEntry extends TransferDashboardEntry {
  final TransferTask task;
  const TransferSingleTaskEntry(this.task);
}

class TransferFileNode {
  final String name;
  final String relativePath;
  final TransferTask task;
  final int transferredBytes;
  final int totalBytes;
  final double speedBytesPerSec;
  final TransferStatus status;
  final String? errorMessage;

  const TransferFileNode({
    required this.name,
    required this.relativePath,
    required this.task,
    required this.transferredBytes,
    required this.totalBytes,
    required this.speedBytesPerSec,
    required this.status,
    this.errorMessage,
  });

  double get progress => totalBytes > 0
      ? (transferredBytes / totalBytes).clamp(0.0, 1.0)
      : (status == TransferStatus.completed ? 1.0 : 0.0);
}

class TransferFolderNode {
  final String name;
  final String fullRelPath;
  final List<TransferFolderNode> subfolders;
  final List<TransferFileNode> files;
  final int transferredBytes;
  final int totalBytes;
  final double speedBytesPerSec;
  final int totalFiles;
  final int completedFiles;
  final int activeFiles;
  final int pausedFiles;
  final int pendingFiles;
  final int failedFiles;
  final TransferStatus aggregateStatus;

  const TransferFolderNode({
    required this.name,
    required this.fullRelPath,
    required this.subfolders,
    required this.files,
    required this.transferredBytes,
    required this.totalBytes,
    required this.speedBytesPerSec,
    required this.totalFiles,
    required this.completedFiles,
    required this.activeFiles,
    required this.pausedFiles,
    required this.pendingFiles,
    required this.failedFiles,
    required this.aggregateStatus,
  });

  double get progress {
    if (totalBytes > 0) {
      return (transferredBytes / totalBytes).clamp(0.0, 1.0);
    }
    if (totalFiles > 0) {
      return (completedFiles / totalFiles).clamp(0.0, 1.0);
    }
    return aggregateStatus == TransferStatus.completed ? 1.0 : 0.0;
  }

  int get remainingBytes => (totalBytes - transferredBytes).clamp(0, totalBytes);
}

class TransferGroupSummary {
  final String groupId;
  final String groupName;
  final TransferTaskType taskType;
  final TransferFolderNode rootNode;

  const TransferGroupSummary({
    required this.groupId,
    required this.groupName,
    required this.taskType,
    required this.rootNode,
  });

  int get totalFiles => rootNode.totalFiles;
  int get completedFiles => rootNode.completedFiles;
  int get activeFiles => rootNode.activeFiles;
  int get pausedFiles => rootNode.pausedFiles;
  int get pendingFiles => rootNode.pendingFiles;
  int get failedFiles => rootNode.failedFiles;
  int get transferredBytes => rootNode.transferredBytes;
  int get totalBytes => rootNode.totalBytes;
  int get remainingBytes => rootNode.remainingBytes;
  double get speedBytesPerSec => rootNode.speedBytesPerSec;
  double get progress => rootNode.progress;
  TransferStatus get aggregateStatus => rootNode.aggregateStatus;
}

class _MutableFolderBuilder {
  final String name;
  final String fullRelPath;
  final Map<String, _MutableFolderBuilder> subfolders = {};
  final List<TransferFileNode> files = [];

  _MutableFolderBuilder({required this.name, required this.fullRelPath});

  TransferFolderNode build() {
    final builtSubfolders = subfolders.values.map((s) => s.build()).toList()
      ..sort((a, b) => NaturalSortUtils.compare(a.name, b.name));
    final sortedFiles = List<TransferFileNode>.from(files)
      ..sort((a, b) => NaturalSortUtils.compare(a.name, b.name));

    int transferred = 0;
    int total = 0;
    double speed = 0.0;
    int totalFiles = 0;
    int completed = 0;
    int active = 0;
    int paused = 0;
    int pending = 0;
    int failed = 0;

    for (final sub in builtSubfolders) {
      transferred += sub.transferredBytes;
      total += sub.totalBytes;
      speed += sub.speedBytesPerSec;
      totalFiles += sub.totalFiles;
      completed += sub.completedFiles;
      active += sub.activeFiles;
      paused += sub.pausedFiles;
      pending += sub.pendingFiles;
      failed += sub.failedFiles;
    }

    for (final f in sortedFiles) {
      transferred += f.transferredBytes;
      total += f.totalBytes;
      if (f.status == TransferStatus.active) {
        speed += f.speedBytesPerSec;
      }
      totalFiles += 1;
      switch (f.status) {
        case TransferStatus.completed:
          completed += 1;
          break;
        case TransferStatus.active:
          active += 1;
          break;
        case TransferStatus.paused:
          paused += 1;
          break;
        case TransferStatus.pending:
          pending += 1;
          break;
        case TransferStatus.failed:
          failed += 1;
          break;
      }
    }

    final TransferStatus aggStatus;
    if (active > 0) {
      aggStatus = TransferStatus.active;
    } else if (pending > 0) {
      aggStatus = TransferStatus.pending;
    } else if (paused > 0) {
      aggStatus = TransferStatus.paused;
    } else if (failed > 0) {
      aggStatus = TransferStatus.failed;
    } else {
      aggStatus = TransferStatus.completed;
    }

    return TransferFolderNode(
      name: name,
      fullRelPath: fullRelPath,
      subfolders: builtSubfolders,
      files: sortedFiles,
      transferredBytes: transferred,
      totalBytes: total,
      speedBytesPerSec: speed,
      totalFiles: totalFiles,
      completedFiles: completed,
      activeFiles: active,
      pausedFiles: paused,
      pendingFiles: pending,
      failedFiles: failed,
      aggregateStatus: aggStatus,
    );
  }
}

class TransferTreeBuilder {
  TransferTreeBuilder._();

  static List<TransferDashboardEntry> buildDashboardEntries(
    List<TransferTask> tasks,
    Map<String, TaskProgressInfo> progressMap,
  ) {
    final List<TransferDashboardEntry> entries = [];
    final Map<String, List<TransferTask>> groupedTasks = {};
    final List<String> orderTokens = []; // 'group:<id>' or 'single:<index>'
    final Map<String, TransferTask> singleTasks = {};

    for (final task in tasks) {
      final gid = task.groupId;
      if (gid != null && gid.isNotEmpty) {
        if (!groupedTasks.containsKey(gid)) {
          groupedTasks[gid] = [];
          orderTokens.add('group:$gid');
        }
        groupedTasks[gid]!.add(task);
      } else {
        final token = 'single:${task.id}';
        singleTasks[token] = task;
        orderTokens.add(token);
      }
    }

    for (final token in orderTokens) {
      if (token.startsWith('group:')) {
        final gid = token.substring('group:'.length);
        final groupList = groupedTasks[gid]!;
        entries.add(TransferGroupEntry(_buildGroupSummary(gid, groupList, progressMap)));
      } else {
        entries.add(TransferSingleTaskEntry(singleTasks[token]!));
      }
    }

    return entries;
  }

  static TransferGroupSummary _buildGroupSummary(
    String groupId,
    List<TransferTask> tasks,
    Map<String, TaskProgressInfo> progressMap,
  ) {
    String groupName = '폴더 전송';
    for (final t in tasks) {
      if (t.groupName != null && t.groupName!.trim().isNotEmpty) {
        groupName = t.groupName!.trim();
        break;
      }
    }

    final rootBuilder = _MutableFolderBuilder(name: groupName, fullRelPath: '');
    for (final task in tasks) {
      final info = progressMap[task.id];
      final transferred = info?.transferredBytes ?? task.transferredBytes;
      final total = (info?.totalBytes ?? 0) > 0 ? info!.totalBytes : task.totalBytes;
      final status = info?.status ?? task.status;
      final speed = status == TransferStatus.active ? (info?.speedBytesPerSec ?? 0.0) : 0.0;

      final rawRel = (task.relativePath != null && task.relativePath!.trim().isNotEmpty)
          ? task.relativePath!.trim()
          : task.fileName;
      final segments = rawRel.split(RegExp(r'[\\/]')).where((s) => s.isNotEmpty).toList();
      if (segments.isEmpty) {
        segments.add(task.fileName);
      }

      var current = rootBuilder;
      for (int i = 0; i < segments.length - 1; i++) {
        final dirName = segments[i];
        final nextPath = current.fullRelPath.isEmpty ? dirName : '${current.fullRelPath}/$dirName';
        current = current.subfolders.putIfAbsent(
          dirName,
          () => _MutableFolderBuilder(name: dirName, fullRelPath: nextPath),
        );
      }

      final fileName = segments.last;
      current.files.add(
        TransferFileNode(
          name: fileName,
          relativePath: segments.join('/'),
          task: task,
          transferredBytes: transferred,
          totalBytes: total,
          speedBytesPerSec: speed,
          status: status,
          errorMessage: task.errorMessage,
        ),
      );
    }

    return TransferGroupSummary(
      groupId: groupId,
      groupName: groupName,
      taskType: tasks.first.taskType,
      rootNode: rootBuilder.build(),
    );
  }
}
