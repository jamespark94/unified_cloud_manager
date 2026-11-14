import 'dart:io';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/cloud/cloud_credentials.dart';
import '../../core/cloud/cloud_item.dart';
import '../../core/database/transfer_task_entity.dart';
import '../../core/transfer/recursive_folder_handler.dart';
import '../../core/utils/sort_utils.dart';
import '../../state/accounts_provider.dart';
import '../../state/transfer_queue_provider.dart';
import '../widgets/breadcrumb_bar.dart';
import '../widgets/cloud_item_tile.dart';

class ExplorerTabView extends ConsumerStatefulWidget {
  final CloudAccount account;
  final Function(List<CloudItem> selectedItems, CloudAccount sourceAccount)? onRequestTransfer;
  final VoidCallback? onRemoveAccount;

  const ExplorerTabView({
    super.key,
    required this.account,
    this.onRequestTransfer,
    this.onRemoveAccount,
  });

  @override
  ConsumerState<ExplorerTabView> createState() => _ExplorerTabViewState();
}

class _ExplorerTabViewState extends ConsumerState<ExplorerTabView> {
  bool _isLoading = true;
  String? _errorMessage;
  List<CloudItem> _items = [];
  final Set<String> _selectedItemIds = {};
  bool _isDragging = false;

  // Navigation Stack (id, name)
  final List<MapEntry<String, String>> _folderStack = [];

  static const String _prefSortFieldKey = 'explorer_sort_field';
  static const String _prefSortAscKey = 'explorer_sort_ascending';
  SortField _sortField = SortField.name;
  bool _sortAscending = true;

  @override
  void initState() {
    super.initState();
    _loadSortPreference();
    _folderStack.add(MapEntry('root', widget.account.type == CloudProviderType.local ? '내 기기' : '홈'));
    _loadFolder();
  }

  Future<void> _loadSortPreference() async {
    final prefs = await SharedPreferences.getInstance();
    final savedField = prefs.getString(_prefSortFieldKey);
    final savedAsc = prefs.getBool(_prefSortAscKey);
    if (mounted) {
      setState(() {
        if (savedField != null) {
          _sortField = SortField.values.firstWhere(
            (f) => f.name == savedField,
            orElse: () => SortField.name,
          );
        }
        if (savedAsc != null) {
          _sortAscending = savedAsc;
        }
        _items = SortUtils.sortCloudItems(
          _items,
          field: _sortField,
          ascending: _sortAscending,
        );
      });
    }
  }

  Future<void> _changeSort(SortField field, {required bool ascending}) async {
    setState(() {
      _sortField = field;
      _sortAscending = ascending;
      _items = SortUtils.sortCloudItems(
        _items,
        field: _sortField,
        ascending: _sortAscending,
      );
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefSortFieldKey, field.name);
    await prefs.setBool(_prefSortAscKey, ascending);
  }

  void _onSelectSortField(SortField field) {
    final nextAsc = field == _sortField ? !_sortAscending : field.defaultAscending;
    _changeSort(field, ascending: nextAsc);
  }

  Future<void> _loadFolder() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _selectedItemIds.clear();
    });

    try {
      final provider = ref.read(accountsProvider.notifier).createProviderForAccount(widget.account);
      final currentFolderId = _folderStack.last.key;
      final fetched = await provider.listItems(folderIdOrPath: currentFolderId);
      if (mounted) {
        setState(() {
          _items = SortUtils.sortCloudItems(
            fetched,
            field: _sortField,
            ascending: _sortAscending,
          );
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = e.toString();
        });
      }
    }
  }

  void _navigateToFolder(CloudItem folder) {
    setState(() {
      _folderStack.add(MapEntry(folder.id, folder.name));
    });
    _loadFolder();
  }

  void _navigateToIndex(int index) {
    if (index >= 0 && index < _folderStack.length - 1) {
      setState(() {
        _folderStack.removeRange(index + 1, _folderStack.length);
      });
      _loadFolder();
    }
  }

  void _toggleSelection(CloudItem item) {
    setState(() {
      if (_selectedItemIds.contains(item.id)) {
        _selectedItemIds.remove(item.id);
      } else {
        _selectedItemIds.add(item.id);
      }
    });
  }

  Future<void> _handleDroppedPaths(List<String> paths) async {
    if (paths.isEmpty) return;

    final queueMgr = ref.read(transferQueueManagerProvider);
    final targetFolderId = _folderStack.last.key;
    final List<TransferTask> plannedTasks = [];

    for (final path in paths) {
      if (path.isEmpty) continue;

      final fileEntity = File(path);
      final isDir = FileSystemEntity.isDirectorySync(path);
      final fileName = path.split(Platform.pathSeparator).last;

      if (isDir) {
        final handler = RecursiveFolderHandler({
          'local': queueMgr.getProvider('local')!,
          widget.account.id: queueMgr.getProvider(widget.account.id)!,
        });
        final groupId = 'group_${DateTime.now().millisecondsSinceEpoch}_${fileName.hashCode}';
        final tasks = await handler.planFolderTransfer(
          sourceAccountId: 'local',
          destAccountId: widget.account.id,
          sourceFolderIdOrPath: path,
          sourceFolderName: fileName,
          destParentFolderIdOrPath: targetFolderId,
          groupId: groupId,
        );
        plannedTasks.addAll(tasks);
      } else {
        int size = 0;
        try {
          size = fileEntity.lengthSync();
        } catch (_) {}

        final taskId = 'task_${DateTime.now().microsecondsSinceEpoch}_${fileName.hashCode}';
        plannedTasks.add(
          TransferTask(
            id: taskId,
            providerType: widget.account.type.code,
            sourceAccountId: 'local',
            destAccountId: widget.account.id,
            taskType: widget.account.type == CloudProviderType.local
                ? TransferTaskType.download
                : TransferTaskType.upload,
            fileName: fileName,
            sourcePath: path,
            destinationPath: targetFolderId,
            totalBytes: size,
            transferredBytes: 0,
            status: TransferStatus.pending,
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
        );
      }
    }

    if (plannedTasks.isNotEmpty) {
      await queueMgr.enqueueBatch(plannedTasks);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('드롭된 ${plannedTasks.length}개 파일/폴더의 업로드가 시작되었습니다.')),
        );
      }
    }
  }

  Future<void> _promptUploadFiles() async {
    final result = await FilePicker.pickFiles();
    if (result.isNotEmpty) {
      final paths = result.map((f) => f.path).whereType<String>().where((p) => p.isNotEmpty).toList();
      _handleDroppedPaths(paths);
    }
  }

  Future<void> _promptCreateFolder() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('새 폴더 생성', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '폴더 이름 입력'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('취소')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('생성'),
          ),
        ],
      ),
    );

    if (name != null && name.isNotEmpty) {
      try {
        final provider = ref.read(accountsProvider.notifier).createProviderForAccount(widget.account);
        final currentFolderId = _folderStack.last.key;
        await provider.createFolder(parentId: currentFolderId, folderName: name);
        _loadFolder();
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('폴더 생성 실패: $e')));
        }
      }
    }
  }

  Future<void> _confirmDelete(CloudItem item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('삭제 확인'),
        content: Text('\'${item.name}\'을(를) 정말 삭제하시겠습니까?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('취소')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('삭제', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        final provider = ref.read(accountsProvider.notifier).createProviderForAccount(widget.account);
        await provider.deleteItem(idOrPath: item.id, isFolder: item.isFolder);
        _loadFolder();
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('삭제 실패: $e')));
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return DropTarget(
      onDragEntered: (_) => setState(() => _isDragging = true),
      onDragExited: (_) => setState(() => _isDragging = false),
      onDragDone: (details) {
        setState(() => _isDragging = false);
        final paths = details.files.map((f) => f.path).where((p) => p.isNotEmpty).toList();
        _handleDroppedPaths(paths);
      },
      child: Stack(
        children: [
          Column(
            children: [
              // Breadcrumb Address Bar
              BreadcrumbBar(
                folderStack: _folderStack,
                onSelectIndex: _navigateToIndex,
              ),

              // Action Toolbar
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                color: const Color(0xFF181F2C),
                child: Row(
                  children: [
                    Text(
                      '총 ${_items.length}개 항목',
                      style: const TextStyle(fontSize: 12, color: Colors.white54),
                    ),
                    const SizedBox(width: 10),
                    _buildSortMenuButton(),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.upload_file_outlined, size: 20),
                      tooltip: '파일 업로드 선택',
                      onPressed: _promptUploadFiles,
                    ),
                    IconButton(
                      icon: const Icon(Icons.create_new_folder_outlined, size: 20),
                      tooltip: '새 폴더 생성',
                      onPressed: _promptCreateFolder,
                    ),
                    IconButton(
                      icon: const Icon(Icons.refresh, size: 20),
                      tooltip: '새로고침',
                      onPressed: _loadFolder,
                    ),
                    if (widget.account.id != 'local' && widget.onRemoveAccount != null) ...[
                      const SizedBox(width: 4),
                      IconButton(
                        icon: const Icon(Icons.delete_outline, size: 20, color: Colors.redAccent),
                        tooltip: '계정 연결 해제 / 삭제',
                        onPressed: widget.onRemoveAccount,
                      ),
                    ],
                  ],
                ),
              ),

              // Items View
              Expanded(
                child: _isLoading
                    ? const Center(child: CircularProgressIndicator())
                    : _errorMessage != null
                        ? Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.error_outline, size: 48, color: Colors.redAccent),
                                const SizedBox(height: 12),
                                Text(_errorMessage!, textAlign: TextAlign.center, style: const TextStyle(fontSize: 13)),
                                const SizedBox(height: 16),
                                OutlinedButton.icon(
                                  onPressed: _loadFolder,
                                  icon: const Icon(Icons.refresh, size: 16),
                                  label: const Text('다시 시도'),
                                ),
                              ],
                            ),
                          )
                        : _items.isEmpty
                            ? Center(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(Icons.cloud_upload_outlined, size: 48, color: Colors.white24),
                                    const SizedBox(height: 8),
                                    const Text('폴더가 비어 있습니다.', style: TextStyle(color: Colors.white54)),
                                    const SizedBox(height: 4),
                                    const Text('여기로 외부 파일이나 폴더를 드래그 앤 드롭하여 업로드할 수 있습니다.',
                                        style: TextStyle(fontSize: 11, color: Colors.white38)),
                                  ],
                                ),
                              )
                            : ListView.builder(
                                itemCount: _items.length,
                                itemBuilder: (context, index) {
                                  final item = _items[index];
                                  final isSelected = _selectedItemIds.contains(item.id);
                                  return CloudItemTile(
                                    item: item,
                                    isSelected: isSelected,
                                    onTap: () {
                                      if (_selectedItemIds.isNotEmpty) {
                                        _toggleSelection(item);
                                      } else if (item.isFolder) {
                                        _navigateToFolder(item);
                                      } else {
                                        _toggleSelection(item);
                                      }
                                    },
                                    onLongPress: () => _toggleSelection(item),
                                    onDelete: () => _confirmDelete(item),
                                  );
                                },
                              ),
              ),

              // Bottom Selection Action Bar
              if (_selectedItemIds.isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  color: const Color(0xFF1F293D),
                  child: Row(
                    children: [
                      Text(
                        '${_selectedItemIds.length}개 선택됨',
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                      ),
                      const Spacer(),
                      TextButton(
                        onPressed: () => setState(() => _selectedItemIds.clear()),
                        child: const Text('선택 해제'),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(backgroundColor: Colors.blueAccent),
                        onPressed: () {
                          final selected = _items.where((i) => _selectedItemIds.contains(i.id)).toList();
                          widget.onRequestTransfer?.call(selected, widget.account);
                        },
                        icon: const Icon(Icons.send_rounded, size: 16, color: Colors.white),
                        label: const Text('전송하기', style: TextStyle(color: Colors.white)),
                      ),
                    ],
                  ),
                ),
            ],
          ),

          // Drag Over Visual Indicator
          if (_isDragging)
            Container(
              color: Colors.blueAccent.withAlpha(50),
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                  decoration: BoxDecoration(
                    color: const Color(0xFF181F2C),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.blueAccent, width: 2),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.file_download, color: Colors.blueAccent, size: 32),
                      SizedBox(width: 12),
                      Text(
                        '현재 폴더로 파일/폴더 업로드',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSortMenuButton() {
    return PopupMenuButton<String>(
      tooltip: '정렬 기준 (${_sortField.label} ${_sortAscending ? "오름차순" : "내림차순"})',
      onSelected: (value) {
        if (value == 'dir:asc') {
          _changeSort(_sortField, ascending: true);
        } else if (value == 'dir:desc') {
          _changeSort(_sortField, ascending: false);
        } else if (value.startsWith('field:')) {
          final name = value.substring('field:'.length);
          final field = SortField.values.firstWhere(
            (f) => f.name == name,
            orElse: () => SortField.name,
          );
          _onSelectSortField(field);
        }
      },
      child: Container(
        height: 30,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: Colors.white.withAlpha(15),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: Colors.white12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.sort_rounded, size: 15, color: Colors.blueAccent),
            const SizedBox(width: 4),
            Text(
              _sortField.label,
              style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: Colors.white),
            ),
            const SizedBox(width: 2),
            Icon(
              _sortAscending ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded,
              size: 13,
              color: Colors.blueAccent,
            ),
          ],
        ),
      ),
      itemBuilder: (context) => [
        ...SortField.values.map((field) {
          final isSelected = field == _sortField;
          return PopupMenuItem<String>(
            value: 'field:${field.name}',
            child: Row(
              children: [
                Icon(
                  field.icon,
                  size: 18,
                  color: isSelected ? Colors.blueAccent : Colors.white70,
                ),
                const SizedBox(width: 10),
                Text(
                  field.label,
                  style: TextStyle(
                    fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                    color: isSelected ? Colors.blueAccent : Colors.white,
                  ),
                ),
                const Spacer(),
                if (isSelected)
                  Icon(
                    _sortAscending ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded,
                    size: 16,
                    color: Colors.blueAccent,
                  ),
              ],
            ),
          );
        }),
        const PopupMenuDivider(),
        PopupMenuItem<String>(
          value: 'dir:asc',
          child: Row(
            children: [
              Icon(
                Icons.arrow_upward_rounded,
                size: 18,
                color: _sortAscending ? Colors.blueAccent : Colors.white70,
              ),
              const SizedBox(width: 10),
              Text(
                '오름차순',
                style: TextStyle(
                  fontWeight: _sortAscending ? FontWeight.bold : FontWeight.normal,
                  color: _sortAscending ? Colors.blueAccent : Colors.white,
                ),
              ),
              const Spacer(),
              if (_sortAscending)
                const Icon(Icons.check, size: 16, color: Colors.blueAccent),
            ],
          ),
        ),
        PopupMenuItem<String>(
          value: 'dir:desc',
          child: Row(
            children: [
              Icon(
                Icons.arrow_downward_rounded,
                size: 18,
                color: !_sortAscending ? Colors.blueAccent : Colors.white70,
              ),
              const SizedBox(width: 10),
              Text(
                '내림차순',
                style: TextStyle(
                  fontWeight: !_sortAscending ? FontWeight.bold : FontWeight.normal,
                  color: !_sortAscending ? Colors.blueAccent : Colors.white,
                ),
              ),
              const Spacer(),
              if (!_sortAscending)
                const Icon(Icons.check, size: 16, color: Colors.blueAccent),
            ],
          ),
        ),
      ],
    );
  }
}
