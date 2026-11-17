import 'package:flutter/material.dart';
import '../../core/database/transfer_task_entity.dart';
import '../../core/transfer/transfer_queue_manager.dart';
import '../../core/utils/format_utils.dart';

class TransferTaskCard extends StatelessWidget {
  final TransferTask task;
  final TaskProgressInfo? progressInfo;
  final VoidCallback onPause;
  final VoidCallback onResume;
  final VoidCallback onCancel;

  const TransferTaskCard({
    super.key,
    required this.task,
    this.progressInfo,
    required this.onPause,
    required this.onResume,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    final currentTransferred = progressInfo?.transferredBytes ?? task.transferredBytes;
    final currentTotal = (progressInfo?.totalBytes ?? 0) > 0 ? progressInfo!.totalBytes : task.totalBytes;
    final currentProgress = currentTotal > 0 ? (currentTransferred / currentTotal).clamp(0.0, 1.0) : 0.0;
    final currentStatus = progressInfo?.status ?? task.status;
    final taskSpeed = progressInfo?.speedBytesPerSec ?? 0.0;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _buildTaskTypeIcon(),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    task.fileName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                  ),
                ),
                _buildStatusBadge(currentStatus),
              ],
            ),
            const SizedBox(height: 8),
            LinearProgressIndicator(
              value: currentProgress,
              backgroundColor: Colors.white12,
              valueColor: AlwaysStoppedAnimation<Color>(_getStatusColor(currentStatus)),
              minHeight: 4,
              borderRadius: BorderRadius.circular(2),
            ),
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '${FormatUtils.formatBytes(currentTransferred)} / ${FormatUtils.formatBytes(currentTotal)} (${(currentProgress * 100).toStringAsFixed(1)}%)',
                      style: const TextStyle(fontSize: 11, color: Colors.white54),
                    ),
                    if (currentStatus == TransferStatus.active && taskSpeed > 0) ...[
                      const SizedBox(width: 8),
                      Text(
                        '• ${FormatUtils.formatSpeed(taskSpeed)}',
                        style: const TextStyle(fontSize: 11, color: Colors.blueAccent, fontWeight: FontWeight.bold),
                      ),
                    ],
                  ],
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (currentStatus == TransferStatus.active)
                      IconButton(
                        icon: const Icon(Icons.pause, size: 18),
                        tooltip: '일시정지',
                        onPressed: onPause,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                      )
                    else if (currentStatus == TransferStatus.paused)
                      IconButton(
                        icon: const Icon(Icons.play_arrow, size: 18, color: Colors.greenAccent),
                        tooltip: '재개',
                        onPressed: onResume,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                      ),
                    const SizedBox(width: 12),
                    IconButton(
                      icon: const Icon(Icons.close, size: 18, color: Colors.redAccent),
                      tooltip: '취소',
                      onPressed: onCancel,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
                  ],
                ),
              ],
            ),
            if (task.errorMessage != null) ...[
              const SizedBox(height: 4),
              Text(
                task.errorMessage!,
                style: const TextStyle(fontSize: 11, color: Colors.redAccent),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildTaskTypeIcon() {
    switch (task.taskType) {
      case TransferTaskType.upload:
        return const Icon(Icons.upload, size: 18, color: Colors.blueAccent);
      case TransferTaskType.download:
        return const Icon(Icons.download, size: 18, color: Colors.greenAccent);
      case TransferTaskType.cloudToCloud:
        return const Icon(Icons.sync_alt, size: 18, color: Colors.orangeAccent);
    }
  }

  Widget _buildStatusBadge(TransferStatus status) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: _getStatusColor(status).withAlpha(30),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: _getStatusColor(status).withAlpha(80)),
      ),
      child: Text(
        status.label,
        style: TextStyle(fontSize: 10, color: _getStatusColor(status), fontWeight: FontWeight.bold),
      ),
    );
  }

  Color _getStatusColor(TransferStatus status) {
    switch (status) {
      case TransferStatus.active:
        return Colors.blueAccent;
      case TransferStatus.completed:
        return Colors.greenAccent;
      case TransferStatus.paused:
        return Colors.amberAccent;
      case TransferStatus.failed:
        return Colors.redAccent;
      case TransferStatus.pending:
        return Colors.grey;
    }
  }
}
