import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../core/cloud/cloud_item.dart';
import '../../core/utils/format_utils.dart';
import '../../core/utils/sort_utils.dart';

class CloudItemTile extends StatelessWidget {
  final CloudItem item;
  final bool isSelected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback? onDelete;

  const CloudItemTile({
    super.key,
    required this.item,
    this.isSelected = false,
    required this.onTap,
    required this.onLongPress,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: isSelected ? Colors.blueAccent.withAlpha(35) : Colors.transparent,
      child: ListTile(
        onTap: onTap,
        onLongPress: onLongPress,
        dense: true,
        leading: _buildLeadingIcon(),
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
            : onDelete != null
                ? IconButton(
                    icon: const Icon(Icons.more_vert, size: 18, color: Colors.white54),
                    onPressed: onDelete,
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
