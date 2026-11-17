import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/database/app_database.dart';
import '../../core/database/transfer_task_entity.dart';
import '../../core/transfer/transfer_queue_manager.dart';
import '../../core/transfer/transfer_tree_builder.dart';
import '../../core/utils/format_utils.dart';
import '../../state/transfer_queue_provider.dart';
import '../widgets/transfer_folder_group_card.dart';
import '../widgets/transfer_task_card.dart';

class TransferDashboardScreen extends ConsumerStatefulWidget {
  const TransferDashboardScreen({super.key});

  @override
  ConsumerState<TransferDashboardScreen> createState() => _TransferDashboardScreenState();
}

class _TransferDashboardScreenState extends ConsumerState<TransferDashboardScreen> {
  List<TransferTask> _cachedTasks = [];
  bool _isLoading = true;
  int _lastObservedVersion = -1;
  bool _isFetching = false;
  bool _needsRefetch = false;

  @override
  void initState() {
    super.initState();
    _fetchTasks();
  }

  Future<void> _fetchTasks() async {
    if (_isFetching) {
      _needsRefetch = true;
      return;
    }
    _isFetching = true;
    try {
      do {
        _needsRefetch = false;
        final tasks = await AppDatabase.instance.getAllTasks();
        if (mounted) {
          setState(() {
            _cachedTasks = tasks;
            _isLoading = false;
          });
        }
      } while (_needsRefetch && mounted);
    } finally {
      _isFetching = false;
    }
  }

  bool _hasIncompleteTasks(Map<String, TaskProgressInfo> progressMap) {
    return _cachedTasks.any((t) {
      final status = progressMap[t.id]?.status ?? t.status;
      return status == TransferStatus.pending ||
          status == TransferStatus.active ||
          status == TransferStatus.paused;
    });
  }

  Future<void> _confirmCancelAll(TransferQueueManager queueMgr) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('전체 취소 확인'),
        content: const Text('진행 중이거나 대기·일시정지된 모든 전송 작업을 취소하시겠습니까?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('닫기')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('전체 취소', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await queueMgr.cancelAll();
      await _fetchTasks();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('진행 및 대기 중인 전송 작업이 모두 취소되었습니다.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // Only rebuild for speed meter and task progress mapping
    final queueMgr = ref.watch(transferQueueManagerProvider);
    if (_lastObservedVersion != queueMgr.taskListVersion) {
      _lastObservedVersion = queueMgr.taskListVersion;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _fetchTasks();
      });
    }
    final progressMap = queueMgr.taskProgressMap;
    final hasIncomplete = _hasIncompleteTasks(progressMap);
    final entries = TransferTreeBuilder.buildDashboardEntries(_cachedTasks, progressMap);

    return Scaffold(
      appBar: AppBar(
        title: const Text('전송 대시보드'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '목록 새로고침',
            onPressed: _fetchTasks,
          ),
          IconButton(
            icon: const Icon(Icons.cleaning_services_outlined),
            tooltip: '완료된 항목 정리',
            onPressed: () async {
              await queueMgr.clearCompleted();
              await _fetchTasks();
            },
          ),
          PopupMenuButton<String>(
            tooltip: '전송 관리 메뉴',
            onSelected: (value) async {
              switch (value) {
                case 'pause_all':
                  await queueMgr.pauseAll();
                  await _fetchTasks();
                  break;
                case 'resume_all':
                  await queueMgr.resumeAll();
                  await _fetchTasks();
                  break;
                case 'cancel_all':
                  await _confirmCancelAll(queueMgr);
                  break;
                case 'clear_completed':
                  await queueMgr.clearCompleted();
                  await _fetchTasks();
                  break;
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem<String>(
                value: 'pause_all',
                child: Row(
                  children: [
                    Icon(Icons.pause, size: 18),
                    SizedBox(width: 10),
                    Text('전체 일시정지'),
                  ],
                ),
              ),
              const PopupMenuItem<String>(
                value: 'resume_all',
                child: Row(
                  children: [
                    Icon(Icons.play_arrow, size: 18, color: Colors.blueAccent),
                    SizedBox(width: 10),
                    Text('전체 재개'),
                  ],
                ),
              ),
              PopupMenuItem<String>(
                value: 'cancel_all',
                enabled: hasIncomplete,
                child: Row(
                  children: [
                    Icon(
                      Icons.cancel_outlined,
                      size: 18,
                      color: hasIncomplete ? Colors.redAccent : Colors.white38,
                    ),
                    const SizedBox(width: 10),
                    Text(
                      '전체 취소',
                      style: TextStyle(
                        color: hasIncomplete ? Colors.redAccent : Colors.white38,
                      ),
                    ),
                  ],
                ),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem<String>(
                value: 'clear_completed',
                child: Row(
                  children: [
                    Icon(Icons.cleaning_services_outlined, size: 18),
                    SizedBox(width: 10),
                    Text('완료된 항목 정리'),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            // Header Speed Meter & Controls
            Container(
              padding: const EdgeInsets.all(16),
              color: const Color(0xFF181F2C),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('실시간 전송 속도', style: TextStyle(fontSize: 12, color: Colors.white54)),
                      Text(
                        FormatUtils.formatSpeed(queueMgr.currentSpeedBytesPerSec),
                        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.blueAccent),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      OutlinedButton.icon(
                        onPressed: () async {
                          await queueMgr.pauseAll();
                          await _fetchTasks();
                        },
                        icon: const Icon(Icons.pause, size: 16),
                        label: const Text('전체 일시정지'),
                      ),
                      ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(backgroundColor: Colors.blueAccent),
                        onPressed: () async {
                          await queueMgr.resumeAll();
                          await _fetchTasks();
                        },
                        icon: const Icon(Icons.play_arrow, size: 16, color: Colors.white),
                        label: const Text('전체 재개', style: TextStyle(color: Colors.white)),
                      ),
                      OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.redAccent,
                          side: BorderSide(
                            color: hasIncomplete ? Colors.redAccent : Colors.white24,
                          ),
                        ),
                        onPressed: hasIncomplete ? () => _confirmCancelAll(queueMgr) : null,
                        icon: const Icon(Icons.cancel_outlined, size: 16),
                        label: const Text('전체 취소'),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            // Tasks List without blinking (grouped folders as expandable trees + standalone files)
            Expanded(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : entries.isEmpty
                      ? const Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.inbox_outlined, size: 48, color: Colors.white38),
                              SizedBox(height: 12),
                              Text('진행 중이거나 완료된 전송 작업이 없습니다.', style: TextStyle(color: Colors.white54)),
                            ],
                          ),
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          itemCount: entries.length,
                          itemBuilder: (context, index) {
                            final entry = entries[index];
                            if (entry is TransferGroupEntry) {
                              final g = entry.group;
                              return TransferFolderGroupCard(
                                key: ValueKey('group_${g.groupId}'),
                                group: g,
                                onPauseGroup: () async {
                                  await queueMgr.pauseGroup(g.groupId);
                                  await _fetchTasks();
                                },
                                onResumeGroup: () async {
                                  await queueMgr.resumeGroup(g.groupId);
                                  await _fetchTasks();
                                },
                                onCancelGroup: () async {
                                  final hasIncompleteInGroup =
                                      g.activeFiles > 0 || g.pendingFiles > 0 || g.pausedFiles > 0;
                                  if (hasIncompleteInGroup) {
                                    await queueMgr.cancelGroup(g.groupId);
                                  } else {
                                    await queueMgr.removeGroup(g.groupId);
                                  }
                                  await _fetchTasks();
                                },
                                onPauseTask: (taskId) async {
                                  await queueMgr.pauseTask(taskId);
                                  await _fetchTasks();
                                },
                                onResumeTask: (taskId) async {
                                  await queueMgr.resumeTask(taskId);
                                  await _fetchTasks();
                                },
                                onCancelTask: (taskId) async {
                                  await queueMgr.cancelTask(taskId);
                                  await _fetchTasks();
                                },
                              );
                            } else {
                              final task = (entry as TransferSingleTaskEntry).task;
                              final progressInfo = progressMap[task.id];
                              return TransferTaskCard(
                                key: ValueKey(task.id),
                                task: task,
                                progressInfo: progressInfo,
                                onPause: () async {
                                  await queueMgr.pauseTask(task.id);
                                  await _fetchTasks();
                                },
                                onResume: () async {
                                  await queueMgr.resumeTask(task.id);
                                  await _fetchTasks();
                                },
                                onCancel: () async {
                                  await queueMgr.cancelTask(task.id);
                                  await _fetchTasks();
                                },
                              );
                            }
                          },
                        ),
            ),
          ],
        ),
      ),
    );
  }
}
