import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/database/app_database.dart';
import '../../core/database/transfer_task_entity.dart';
import '../../core/utils/format_utils.dart';
import '../../state/transfer_queue_provider.dart';
import '../widgets/transfer_task_card.dart';

class TransferDashboardScreen extends ConsumerStatefulWidget {
  const TransferDashboardScreen({super.key});

  @override
  ConsumerState<TransferDashboardScreen> createState() => _TransferDashboardScreenState();
}

class _TransferDashboardScreenState extends ConsumerState<TransferDashboardScreen> {
  List<TransferTask> _cachedTasks = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _fetchTasks();
  }

  Future<void> _fetchTasks() async {
    final tasks = await AppDatabase.instance.getAllTasks();
    if (mounted) {
      setState(() {
        _cachedTasks = tasks;
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // Only rebuild for speed meter and task progress mapping
    final queueMgr = ref.watch(transferQueueManagerProvider);
    final progressMap = queueMgr.taskProgressMap;

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
        ],
      ),
      body: Column(
        children: [
          // Header Speed Meter & Controls
          Container(
            padding: const EdgeInsets.all(16),
            color: const Color(0xFF181F2C),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('실시간 전송 속도', style: TextStyle(fontSize: 12, color: Colors.white54)),
                      const SizedBox(height: 4),
                      Text(
                        FormatUtils.formatSpeed(queueMgr.currentSpeedBytesPerSec),
                        style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.blueAccent),
                      ),
                    ],
                  ),
                ),
                Wrap(
                  spacing: 8,
                  children: [
                    OutlinedButton.icon(
                      onPressed: () => queueMgr.pauseAll(),
                      icon: const Icon(Icons.pause, size: 16),
                      label: const Text('전체 일시정지'),
                    ),
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.blueAccent),
                      onPressed: () => queueMgr.resumeAll(),
                      icon: const Icon(Icons.play_arrow, size: 16, color: Colors.white),
                      label: const Text('전체 재개', style: TextStyle(color: Colors.white)),
                    ),
                  ],
                ),
              ],
            ),
          ),

          // Tasks List without blinking
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _cachedTasks.isEmpty
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
                        itemCount: _cachedTasks.length,
                        itemBuilder: (context, index) {
                          final task = _cachedTasks[index];
                          final progressInfo = progressMap[task.id];
                          return TransferTaskCard(
                            key: ValueKey(task.id),
                            task: task,
                            progressInfo: progressInfo,
                            onPause: () => queueMgr.pauseTask(task.id),
                            onResume: () => queueMgr.resumeTask(task.id),
                            onCancel: () async {
                              await queueMgr.cancelTask(task.id);
                              await _fetchTasks();
                            },
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}
