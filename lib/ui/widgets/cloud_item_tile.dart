import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../core/cloud/cloud_item.dart';
import '../../core/utils/format_utils.dart';
import '../../core/utils/sort_utils.dart';

enum CloudItemMenuAction {
  open,
  select,
  transfer,
  details,
  delete,
}

class CloudItemTile extends StatelessWidget {
  final CloudItem item;
  final bool isSelected;
  final bool showCheckbox;
  final int treeDepth;
  final bool? isExpanded;
  final bool isExpandLoading;
  final VoidCallback? onToggleExpand;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback? onOpen;
  final VoidCallback? onSelect;
  final VoidCallback? onTransfer;
  final VoidCallback? onDetails;
  final VoidCallback? onDelete;

  const CloudItemTile({
    super.key,
    required this.item,
    this.isSelected = false,
    this.showCheckbox = false,
    this.treeDepth = 0,
    this.isExpanded,
    this.isExpandLoading = false,
    this.onToggleExpand,
    required this.onTap,
    required this.onLongPress,
    this.onOpen,
    this.onSelect,
    this.onTransfer,
    this.onDetails,
    this.onDelete,
  });

  bool get _hasMenuActions =>
      (item.isFolder && onOpen != null) ||
      onSelect != null ||
      onTransfer != null ||
      onDetails != null ||
      onDelete != null;

  @override
  Widget build(BuildContext context) {
    final hasTreeControls = treeDepth > 0 || onToggleExpand != null || isExpandLoading;

    return Material(
      color: isSelected ? Colors.blueAccent.withAlpha(35) : Colors.transparent,
      child: ListTile(
        onTap: onTap,
        onLongPress: onLongPress,
        dense: true,
        contentPadding: hasTreeControls
            ? EdgeInsets.only(left: 6.0 + treeDepth * 18.0, right: 8.0)
            : null,
        leading: (showCheckbox || hasTreeControls)
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (hasTreeControls) ...[
                    SizedBox(
                      width: 24,
                      height: 24,
                      child: isExpandLoading
                          ? const Padding(
                              padding: EdgeInsets.all(4),
                              child: CircularProgressIndicator(strokeWidth: 1.5),
                            )
                          : (item.isFolder && onToggleExpand != null)
                              ? IconButton(
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(),
                                  tooltip: isExpanded == true ? '접기' : '펼치기',
                                  icon: Icon(
                                    isExpanded == true
                                        ? Icons.keyboard_arrow_down
                                        : Icons.keyboard_arrow_right,
                                    size: 18,
                                    color: Colors.white70,
                                  ),
                                  onPressed: onToggleExpand,
                                )
                              : const SizedBox.shrink(),
                    ),
                    const SizedBox(width: 2),
                  ],
                  if (showCheckbox) ...[
                    SizedBox(
                      width: 24,
                      height: 24,
                      child: Checkbox(
                        value: isSelected,
                        onChanged: (_) => (onSelect ?? onLongPress)(),
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                    const SizedBox(width: 6),
                  ],
                  _buildLeadingIcon(),
                ],
              )
            : _buildLeadingIcon(),
        title: Text(
          item.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 14,
            fontWeight: item.isFolder ? FontWeight.w600 : FontWeight.normal,
            color: isSelected ? Colors.blueAccent : Colors.white,
          ),
        ),
        subtitle: item.isFolder
            ? Text(
                item.modifiedTime != null
                    ? '폴더 • ${DateFormat("yyyy-MM-dd HH:mm").format(item.modifiedTime!)}'
                    : '폴더',
                style: const TextStyle(fontSize: 11, color: Colors.white54),
              )
            : Text(
                '${SortUtils.getCloudItemTypeLabel(item)} • ${item.size != null ? FormatUtils.formatBytes(item.size!) : "크기 미상"}${item.modifiedTime != null ? " • ${DateFormat("yyyy-MM-dd HH:mm").format(item.modifiedTime!)}" : ""}',
                style: const TextStyle(fontSize: 11, color: Colors.white54),
              ),
        trailing: isSelected
            ? const Icon(Icons.check_circle, color: Colors.blueAccent, size: 20)
            : _hasMenuActions
                ? PopupMenuButton<CloudItemMenuAction>(
                    icon: const Icon(Icons.more_vert, size: 18, color: Colors.white54),
                    tooltip: '작업 선택',
                    onSelected: (action) {
                      switch (action) {
                        case CloudItemMenuAction.open:
                          onOpen?.call();
                          break;
                        case CloudItemMenuAction.select:
                          onSelect?.call();
                          break;
                        case CloudItemMenuAction.transfer:
                          onTransfer?.call();
                          break;
                        case CloudItemMenuAction.details:
                          onDetails?.call();
                          break;
                        case CloudItemMenuAction.delete:
                          onDelete?.call();
                          break;
                      }
                    },
                    itemBuilder: (context) => [
                      if (item.isFolder && onOpen != null)
                        const PopupMenuItem<CloudItemMenuAction>(
                          value: CloudItemMenuAction.open,
                          child: Row(
                            children: [
                              Icon(Icons.folder_open_outlined, size: 18, color: Colors.amber),
                              SizedBox(width: 10),
                              Text('열기'),
                            ],
                          ),
                        ),
                      if (onTransfer != null)
                        const PopupMenuItem<CloudItemMenuAction>(
                          value: CloudItemMenuAction.transfer,
                          child: Row(
                            children: [
                              Icon(Icons.send_rounded, size: 18, color: Colors.blueAccent),
                              SizedBox(width: 10),
                              Text('전송하기 (다운로드/복사)'),
                            ],
                          ),
                        ),
                      if (onSelect != null)
                        const PopupMenuItem<CloudItemMenuAction>(
                          value: CloudItemMenuAction.select,
                          child: Row(
                            children: [
                              Icon(Icons.check_circle_outline, size: 18, color: Colors.white70),
                              SizedBox(width: 10),
                              Text('선택'),
                            ],
                          ),
                        ),
                      if (onDetails != null)
                        const PopupMenuItem<CloudItemMenuAction>(
                          value: CloudItemMenuAction.details,
                          child: Row(
                            children: [
                              Icon(Icons.info_outline, size: 18, color: Colors.white70),
                              SizedBox(width: 10),
                              Text('상세 정보'),
                            ],
                          ),
                        ),
                      if (onDelete != null) ...[
                        if ((item.isFolder && onOpen != null) ||
                            onTransfer != null ||
                            onSelect != null ||
                            onDetails != null)
                          const PopupMenuDivider(),
                        const PopupMenuItem<CloudItemMenuAction>(
                          value: CloudItemMenuAction.delete,
                          child: Row(
                            children: [
                              Icon(Icons.delete_outline, size: 18, color: Colors.redAccent),
                              SizedBox(width: 10),
                              Text('삭제', style: TextStyle(color: Colors.redAccent)),
                            ],
                          ),
                        ),
                      ],
                    ],
                  )
                : null,
      ),
    );
  }

  Widget _buildLeadingIcon() {
    if (item.isFolder) {
      return const Icon(Icons.folder_rounded, color: Colors.amber, size: 28);
    }
    final ext = item.name.contains('.') ? item.name.split('.').last.toLowerCase() : '';
    IconData iconData = Icons.insert_drive_file_outlined;
    Color iconColor = Colors.blueGrey;

    if (['mp4', 'mkv', 'avi', 'mov', 'flv', 'wmv'].contains(ext)) {
      iconData = Icons.movie_outlined;
      iconColor = Colors.purpleAccent;
    } else if (['mp3', 'flac', 'wav', 'aac', 'm4a'].contains(ext)) {
      iconData = Icons.audiotrack_outlined;
      iconColor = Colors.tealAccent;
    } else if (['zip', 'rar', '7z', 'tar', 'gz'].contains(ext)) {
      iconData = Icons.archive_outlined;
      iconColor = Colors.orangeAccent;
    } else if (['jpg', 'jpeg', 'png', 'webp', 'gif'].contains(ext)) {
      iconData = Icons.image_outlined;
      iconColor = Colors.lightBlueAccent;
    } else if (['pdf', 'doc', 'docx', 'txt'].contains(ext)) {
      iconData = Icons.description_outlined;
      iconColor = Colors.redAccent;
    }

    return Icon(iconData, color: iconColor, size: 26);
  }
}
