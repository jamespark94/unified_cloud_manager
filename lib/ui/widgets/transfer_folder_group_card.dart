import 'package:flutter/material.dart';
import '../../core/database/transfer_task_entity.dart';
import '../../core/transfer/transfer_tree_builder.dart';
import '../../core/utils/format_utils.dart';

class TransferFolderGroupCard extends StatefulWidget {
  final TransferGroupSummary group;
  final bool initiallyExpanded;
  final VoidCallback onPauseGroup;
  final VoidCallback onResumeGroup;
  final VoidCallback onCancelGroup;
  final ValueChanged<String> onPauseTask;
  final ValueChanged<String> onResumeTask;
  final ValueChanged<String> onCancelTask;

  const TransferFolderGroupCard({
    super.key,
    required this.group,
    this.initiallyExpanded = false,
    required this.onPauseGroup,
    required this.onResumeGroup,
    required this.onCancelGroup,
    required this.onPauseTask,
    required this.onResumeTask,
    required this.onCancelTask,
  });

  @override
  State<TransferFolderGroupCard> createState() => _TransferFolderGroupCardState();
}

class _TransferFolderGroupCardState extends State<TransferFolderGroupCard> {
  late bool _isExpanded;
  final Set<String> _collapsedSubfolders = {};

  @override
  void initState() {
    super.initState();
    _isExpanded = widget.initiallyExpanded;
  }

  void _toggleSubfolder(String relPath) {
    setState(() {
      if (_collapsedSubfolders.contains(relPath)) {
        _collapsedSubfolders.remove(relPath);
      } else {
        _collapsedSubfolders.add(relPath);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final g = widget.group;
    final status = g.aggregateStatus;
    final statusColor = _getStatusColor(status);
    final hasActiveOrPending = g.activeFiles > 0 || g.pendingFiles > 0;
    final hasPausedOrFailed = g.pausedFiles > 0 || g.failedFiles > 0;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Folder Header
          InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => setState(() => _isExpanded = !_isExpanded),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        _isExpanded ? Icons.keyboard_arrow_down : Icons.keyboard_arrow_right,
                        size: 20,
                        color: Colors.white70,
                      ),
                      const SizedBox(width: 4),
                      Icon(
                        _isExpanded ? Icons.folder_open_rounded : Icons.folder_rounded,
                        size: 22,
                        color: Colors.amber,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              g.groupName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '${g.taskType.label} • 파일 ${g.completedFiles}/${g.totalFiles} 완료'
                              '${g.failedFiles > 0 ? " (실패 ${g.failedFiles})" : ""}',
                              style: const TextStyle(fontSize: 11, color: Colors.white54),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      _buildStatusBadge(status, statusColor),
                    ],
                  ),
                  const SizedBox(height: 10),
                  LinearProgressIndicator(
                    value: g.progress,
                    backgroundColor: Colors.white12,
                    valueColor: AlwaysStoppedAnimation<Color>(statusColor),
                    minHeight: 5,
                    borderRadius: BorderRadius.circular(3),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 2,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text(
                              '${FormatUtils.formatBytes(g.transferredBytes)} / ${FormatUtils.formatBytes(g.totalBytes)} (${(g.progress * 100).toStringAsFixed(1)}%)',
                              style: const TextStyle(fontSize: 11.5, color: Colors.white70),
                            ),
                            if (status == TransferStatus.active && g.speedBytesPerSec > 0) ...[
                              Text(
                                '• ${FormatUtils.formatSpeed(g.speedBytesPerSec)}',
                                style: const TextStyle(
                                  fontSize: 11.5,
                                  color: Colors.blueAccent,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              Text(
                                '• 남은 시간 ${FormatUtils.formatEta(g.remainingBytes, g.speedBytesPerSec)}',
                                style: const TextStyle(fontSize: 11, color: Colors.white54),
                              ),
                            ],
                          ],
                        ),
                      ),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (hasActiveOrPending)
                            IconButton(
                              icon: const Icon(Icons.pause, size: 18),
                              tooltip: '폴더 일시정지',
                              onPressed: widget.onPauseGroup,
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(),
                            ),
                          if (hasPausedOrFailed) ...[
                            if (hasActiveOrPending) const SizedBox(width: 10),
                            IconButton(
                              icon: const Icon(Icons.play_arrow, size: 18, color: Colors.greenAccent),
                              tooltip: '폴더 재개',
                              onPressed: widget.onResumeGroup,
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(),
                            ),
                          ],
                          const SizedBox(width: 12),
                          IconButton(
                            icon: Icon(
                              hasActiveOrPending || g.pausedFiles > 0
                                  ? Icons.close
                                  : Icons.delete_outline,
                              size: 18,
                              color: Colors.redAccent,
                            ),
                            tooltip: hasActiveOrPending || g.pausedFiles > 0 ? '폴더 전송 취소' : '목록에서 제거',
                            onPressed: widget.onCancelGroup,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                          ),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),

          // Expanded Tree View
          if (_isExpanded) ...[
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.only(left: 10, right: 12, top: 6, bottom: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: _buildFolderChildren(g.rootNode, depth: 0),
              ),
            ),
          ],
        ],
      ),
    );
  }

  List<Widget> _buildFolderChildren(TransferFolderNode folder, {required int depth}) {
    final List<Widget> widgets = [];
    for (final sub in folder.subfolders) {
      final isSubExpanded = !_collapsedSubfolders.contains(sub.fullRelPath);
      widgets.add(_buildSubfolderRow(sub, depth: depth, isExpanded: isSubExpanded));
      if (isSubExpanded) {
        widgets.addAll(_buildFolderChildren(sub, depth: depth + 1));
      }
    }
    for (final file in folder.files) {
      widgets.add(_buildFileRow(file, depth: depth));
    }
    return widgets;
  }

  Widget _buildSubfolderRow(
    TransferFolderNode folder, {
    required int depth,
    required bool isExpanded,
  }) {
    final statusColor = _getStatusColor(folder.aggregateStatus);
    return Padding(
      padding: EdgeInsets.only(left: depth * 18.0, top: 3, bottom: 3),
      child: Container(
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(color: Colors.white.withAlpha(28), width: 1.5),
          ),
        ),
        padding: const EdgeInsets.only(left: 8, top: 4, bottom: 4, right: 4),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: () => _toggleSubfolder(folder.fullRelPath),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    isExpanded ? Icons.keyboard_arrow_down : Icons.keyboard_arrow_right,
                    size: 16,
                    color: Colors.white54,
                  ),
                  const SizedBox(width: 2),
                  Icon(
                    isExpanded ? Icons.folder_open_rounded : Icons.folder_rounded,
                    size: 16,
                    color: Colors.amber,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      folder.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '${folder.completedFiles}/${folder.totalFiles}',
                    style: const TextStyle(fontSize: 11, color: Colors.white54),
                  ),
                  if (folder.aggregateStatus == TransferStatus.active &&
                      folder.speedBytesPerSec > 0) ...[
                    const SizedBox(width: 6),
                    Text(
                      FormatUtils.formatSpeed(folder.speedBytesPerSec),
                      style: const TextStyle(
                        fontSize: 11,
                        color: Colors.blueAccent,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                  const SizedBox(width: 6),
                  _buildStatusBadge(folder.aggregateStatus, statusColor, compact: true),
                ],
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  const SizedBox(width: 22),
                  Expanded(
                    child: LinearProgressIndicator(
                      value: folder.progress,
                      backgroundColor: Colors.white12,
                      valueColor: AlwaysStoppedAnimation<Color>(statusColor),
                      minHeight: 3,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '${FormatUtils.formatBytes(folder.transferredBytes)} / ${FormatUtils.formatBytes(folder.totalBytes)}',
                    style: const TextStyle(fontSize: 10.5, color: Colors.white54),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFileRow(TransferFileNode file, {required int depth}) {
    final statusColor = _getStatusColor(file.status);
    return Padding(
      padding: EdgeInsets.only(left: depth * 18.0, top: 3, bottom: 3),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white.withAlpha(8),
          borderRadius: BorderRadius.circular(6),
          border: Border(
            left: BorderSide(color: statusColor.withAlpha(140), width: 2),
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.insert_drive_file_outlined, size: 15, color: Colors.white60),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    file.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
                const SizedBox(width: 6),
                _buildStatusBadge(file.status, statusColor, compact: true),
              ],
            ),
            const SizedBox(height: 5),
            LinearProgressIndicator(
              value: file.progress,
              backgroundColor: Colors.white12,
              valueColor: AlwaysStoppedAnimation<Color>(statusColor),
              minHeight: 3,
              borderRadius: BorderRadius.circular(2),
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 2,
                    children: [
                      Text(
                        '${FormatUtils.formatBytes(file.transferredBytes)} / ${FormatUtils.formatBytes(file.totalBytes)} (${(file.progress * 100).toStringAsFixed(1)}%)',
                        style: const TextStyle(fontSize: 10.5, color: Colors.white54),
                      ),
                      if (file.status == TransferStatus.active && file.speedBytesPerSec > 0)
                        Text(
                          '• ${FormatUtils.formatSpeed(file.speedBytesPerSec)}',
                          style: const TextStyle(
                            fontSize: 10.5,
                            color: Colors.blueAccent,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                    ],
                  ),
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (file.status == TransferStatus.active)
                      IconButton(
                        icon: const Icon(Icons.pause, size: 15),
                        tooltip: '일시정지',
                        onPressed: () => widget.onPauseTask(file.task.id),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                      )
                    else if (file.status == TransferStatus.paused ||
                        file.status == TransferStatus.failed)
                      IconButton(
                        icon: const Icon(Icons.play_arrow, size: 15, color: Colors.greenAccent),
                        tooltip: '재개',
                        onPressed: () => widget.onResumeTask(file.task.id),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                      ),
                    const SizedBox(width: 8),
                    IconButton(
                      icon: const Icon(Icons.close, size: 15, color: Colors.redAccent),
                      tooltip: '취소',
                      onPressed: () => widget.onCancelTask(file.task.id),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
                  ],
                ),
              ],
            ),
            if (file.errorMessage != null && file.errorMessage!.isNotEmpty) ...[
              const SizedBox(height: 3),
              Text(
                file.errorMessage!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 10.5, color: Colors.redAccent),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildStatusBadge(TransferStatus status, Color color, {bool compact = false}) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: compact ? 5 : 6, vertical: compact ? 1 : 2),
      decoration: BoxDecoration(
        color: color.withAlpha(30),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withAlpha(80)),
      ),
      child: Text(
        status.label,
        style: TextStyle(
          fontSize: compact ? 9.5 : 10,
          color: color,
          fontWeight: FontWeight.bold,
        ),
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
