import 'dart:io';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/cloud/cloud_credentials.dart';
import '../../core/cloud/cloud_item.dart';
import '../../core/database/transfer_task_entity.dart';
import '../../core/transfer/recursive_folder_handler.dart';
import '../../core/utils/format_utils.dart';
import '../../core/utils/sort_utils.dart';
import '../../state/accounts_provider.dart';
import '../../state/transfer_queue_provider.dart';
import '../widgets/breadcrumb_bar.dart';
import '../widgets/cloud_item_tile.dart';

class _VisibleTreeRow {
  final CloudItem item;
  final int depth;

  const _VisibleTreeRow({
    required this.item,
    required this.depth,
  });
}

class ExplorerPaneSnapshot {
  final String accountId;
  final List<MapEntry<String, String>> folderStack;
  final List<CloudItem> items;
  final Set<String> selectedItemIds;
  final Map<String, List<CloudItem>> treeChildren;
  final Set<String> treeExpanded;
  final Map<String, List<MapEntry<String, String>>> folderPathMap;
  final bool isLoading;
  final String? errorMessage;

  const ExplorerPaneSnapshot({
    required this.accountId,
    required this.folderStack,
    required this.items,
    required this.selectedItemIds,
    required this.treeChildren,
    required this.treeExpanded,
    required this.folderPathMap,
    required this.isLoading,
    required this.errorMessage,
  });
}

class ExplorerPane extends ConsumerStatefulWidget {
  final String paneId;
  final String paneRoleLabel;
  final bool isLeftPane;
  final bool isFocused;
  final List<CloudAccount> accounts;
  final CloudAccount account;
  final ValueChanged<CloudAccount> onAccountChanged;
  final VoidCallback onFocus;
  final ValueChanged<List<MapEntry<String, String>>> onLocationChanged;
  final ValueChanged<List<CloudItem>> onSelectionChanged;
  final void Function(List<CloudItem> selectedItems, CloudAccount sourceAccount) onTransferToOpposite;
  final void Function(List<CloudItem> selectedItems, CloudAccount sourceAccount)? onTransferCustom;
  final String oppositeLabel;
  final VoidCallback? onRemoveAccount;

  const ExplorerPane({
    super.key,
    required this.paneId,
    required this.paneRoleLabel,
    required this.isLeftPane,
    required this.isFocused,
    required this.accounts,
    required this.account,
    required this.onAccountChanged,
    required this.onFocus,
    required this.onLocationChanged,
    required this.onSelectionChanged,
    required this.onTransferToOpposite,
    this.onTransferCustom,
    required this.oppositeLabel,
    this.onRemoveAccount,
  });

  @override
  ConsumerState<ExplorerPane> createState() => ExplorerPaneState();
}

class ExplorerPaneState extends ConsumerState<ExplorerPane> {
  bool _isLoading = true;
  String? _errorMessage;
  List<CloudItem> _items = [];
  final Set<String> _selectedItemIds = {};
  bool _isDragging = false;

  // Navigation Stack (id, name)
  final List<MapEntry<String, String>> _folderStack = [];

  // Unified inline tree state
  final Map<String, List<CloudItem>> _treeChildren = {};
  final Set<String> _treeExpanded = {};
  final Set<String> _treeLoading = {};
  final Map<String, String> _treeErrors = {};
  final Map<String, List<MapEntry<String, String>>> _folderPathMap = {};
  bool _suppressNextAccountReset = false;

  static const String _prefSortFieldKey = 'explorer_sort_field';
  static const String _prefSortAscKey = 'explorer_sort_ascending';
  SortField _sortField = SortField.name;
  bool _sortAscending = true;

  String get currentFolderId => _folderStack.isNotEmpty ? _folderStack.last.key : 'root';
  String get currentFolderName =>
      _folderStack.isNotEmpty ? _folderStack.last.value : _rootDisplayName(widget.account);
  List<MapEntry<String, String>> get folderStack => List.unmodifiable(_folderStack);

  List<CloudItem> get selectedItems {
    if (_selectedItemIds.isEmpty) return const [];
    final Map<String, CloudItem> byId = {};
    for (final item in _items) {
      byId[item.id] = item;
    }
    for (final children in _treeChildren.values) {
      for (final item in children) {
        byId.putIfAbsent(item.id, () => item);
      }
    }
    return _selectedItemIds.map((id) => byId[id]).whereType<CloudItem>().toList();
  }

  void suppressNextAccountReset() {
    _suppressNextAccountReset = true;
  }

  ExplorerPaneSnapshot exportState() {
    return ExplorerPaneSnapshot(
      accountId: widget.account.id,
      folderStack: List<MapEntry<String, String>>.from(_folderStack),
      items: List<CloudItem>.from(_items),
      selectedItemIds: Set<String>.from(_selectedItemIds),
      treeChildren: _treeChildren.map((k, v) => MapEntry(k, List<CloudItem>.from(v))),
      treeExpanded: Set<String>.from(_treeExpanded),
      folderPathMap: _folderPathMap.map(
        (k, v) => MapEntry(k, List<MapEntry<String, String>>.from(v)),
      ),
      isLoading: _isLoading,
      errorMessage: _errorMessage,
    );
  }

  void importState(ExplorerPaneSnapshot snap) {
    if (!mounted) return;
    setState(() {
      _folderStack
        ..clear()
        ..addAll(snap.folderStack);
      _items = List<CloudItem>.from(snap.items);
      _selectedItemIds
        ..clear()
        ..addAll(snap.selectedItemIds);
      _treeChildren
        ..clear()
        ..addAll(snap.treeChildren.map((k, v) => MapEntry(k, List<CloudItem>.from(v))));
      _treeExpanded
        ..clear()
        ..addAll(snap.treeExpanded);
      _treeLoading.clear();
      _treeErrors.clear();
      _folderPathMap
        ..clear()
        ..addAll(snap.folderPathMap.map((k, v) => MapEntry(k, List<MapEntry<String, String>>.from(v))));
      _isLoading = snap.isLoading;
      _errorMessage = snap.errorMessage;
    });
    widget.onLocationChanged(List.unmodifiable(_folderStack));
    widget.onSelectionChanged(selectedItems);
    if (snap.isLoading) {
      _loadFolder(forceTreeRefresh: true);
    }
  }

  void clearSelection() {
    if (_selectedItemIds.isEmpty) return;
    setState(() => _selectedItemIds.clear());
    widget.onSelectionChanged(const []);
  }

  Future<void> refreshCurrentFolder() async {
    await _loadFolder(forceTreeRefresh: true);
  }

  String _rootDisplayName(CloudAccount account) =>
      account.type == CloudProviderType.local ? '내 기기' : '홈';

  @override
  void initState() {
    super.initState();
    _loadSortPreference();
    _initStackForAccount(widget.account);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.onLocationChanged(List.unmodifiable(_folderStack));
      widget.onSelectionChanged(const []);
      _loadFolder(forceTreeRefresh: true);
    });
  }

  @override
  void didUpdateWidget(covariant ExplorerPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.account.id != widget.account.id ||
        oldWidget.account.accessToken != widget.account.accessToken) {
      if (_suppressNextAccountReset) {
        _suppressNextAccountReset = false;
        return;
      }
      _initStackForAccount(widget.account);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        widget.onLocationChanged(List.unmodifiable(_folderStack));
        widget.onSelectionChanged(const []);
        _loadFolder(forceTreeRefresh: true);
      });
    }
  }

  void _initStackForAccount(CloudAccount account) {
    final rootEntry = MapEntry('root', _rootDisplayName(account));
    _folderStack
      ..clear()
      ..add(rootEntry);
    _selectedItemIds.clear();
    _treeChildren.clear();
    _treeExpanded.clear();
    _treeLoading.clear();
    _treeErrors.clear();
    _folderPathMap
      ..clear()
      ..['root'] = [rootEntry];
  }

  Future<void> _loadSortPreference() async {
    final prefs = await SharedPreferences.getInstance();
    final savedField = prefs.getString('${_prefSortFieldKey}_${widget.paneId}') ??
        prefs.getString(_prefSortFieldKey);
    final savedAsc = prefs.getBool('${_prefSortAscKey}_${widget.paneId}') ??
        prefs.getBool(_prefSortAscKey);
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
      for (final key in _treeChildren.keys.toList()) {
        _treeChildren[key] = SortUtils.sortCloudItems(
          _treeChildren[key]!,
          field: _sortField,
          ascending: _sortAscending,
        );
      }
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('${_prefSortFieldKey}_${widget.paneId}', field.name);
    await prefs.setBool('${_prefSortAscKey}_${widget.paneId}', ascending);
  }

  void _onSelectSortField(SortField field) {
    final nextAsc = field == _sortField ? !_sortAscending : field.defaultAscending;
    _changeSort(field, ascending: nextAsc);
  }

  Future<void> _loadFolder({bool forceTreeRefresh = false}) async {
    final targetFolderId = _folderStack.last.key;
    final currentStackSnapshot = List<MapEntry<String, String>>.from(_folderStack);
    final hadSelection = _selectedItemIds.isNotEmpty;
    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _selectedItemIds.clear();
    });
    if (hadSelection) {
      widget.onSelectionChanged(const []);
    }

    try {
      final provider = ref.read(accountsProvider.notifier).createProviderForAccount(widget.account);
      final fetched = await provider.listItems(folderIdOrPath: targetFolderId);
      if (!mounted) return;
      if (_folderStack.last.key != targetFolderId) return; // stale response

      final sorted = SortUtils.sortCloudItems(
        fetched,
        field: _sortField,
        ascending: _sortAscending,
      );

      setState(() {
        _items = sorted;
        _isLoading = false;
        if (forceTreeRefresh || !_treeChildren.containsKey(targetFolderId)) {
          _treeChildren[targetFolderId] = sorted;
        }
        _treeErrors.remove(targetFolderId);
        for (final f in sorted.where((i) => i.isFolder)) {
          _folderPathMap[f.id] = [...currentStackSnapshot, MapEntry(f.id, f.name)];
        }
      });
    } catch (e) {
      if (mounted && _folderStack.last.key == targetFolderId) {
        setState(() {
          _isLoading = false;
          _errorMessage = e.toString();
        });
      }
    }
  }

  Future<void> _toggleTreeExpand(String folderId) async {
    widget.onFocus();
    if (_treeExpanded.contains(folderId)) {
      setState(() {
        _treeExpanded.remove(folderId);
      });
      return;
    }

    setState(() {
      _treeExpanded.add(folderId);
    });

    if (!_treeChildren.containsKey(folderId)) {
      await _loadTreeChildren(folderId);
    }
  }

  Future<void> _loadTreeChildren(String folderId) async {
    if (_treeLoading.contains(folderId)) return;
    setState(() {
      _treeLoading.add(folderId);
      _treeErrors.remove(folderId);
    });

    try {
      final provider = ref.read(accountsProvider.notifier).createProviderForAccount(widget.account);
      final fetched = await provider.listItems(folderIdOrPath: folderId);
      if (!mounted) return;
      final sorted = SortUtils.sortCloudItems(
        fetched,
        field: _sortField,
        ascending: _sortAscending,
      );
      final parentStack = _folderPathMap[folderId] ?? [MapEntry('root', _rootDisplayName(widget.account))];

      setState(() {
        _treeChildren[folderId] = sorted;
        _treeLoading.remove(folderId);
        for (final f in sorted.where((i) => i.isFolder)) {
          _folderPathMap[f.id] = [...parentStack, MapEntry(f.id, f.name)];
        }
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _treeLoading.remove(folderId);
          _treeErrors[folderId] = e.toString();
        });
      }
    }
  }

  void _navigateToFolder(CloudItem folder) {
    widget.onFocus();
    final mapped = _folderPathMap[folder.id];
    setState(() {
      if (mapped != null && mapped.isNotEmpty) {
        _folderStack
          ..clear()
          ..addAll(mapped);
      } else {
        _folderStack.add(MapEntry(folder.id, folder.name));
        _folderPathMap[folder.id] = List<MapEntry<String, String>>.from(_folderStack);
      }
    });
    widget.onLocationChanged(List.unmodifiable(_folderStack));
    _loadFolder();
  }

  void _navigateToIndex(int index) {
    widget.onFocus();
    if (index >= 0 && index < _folderStack.length - 1) {
      setState(() {
        _folderStack.removeRange(index + 1, _folderStack.length);
      });
      widget.onLocationChanged(List.unmodifiable(_folderStack));
      _loadFolder();
    }
  }

  void _toggleSelection(CloudItem item) {
    widget.onFocus();
    setState(() {
      if (_selectedItemIds.contains(item.id)) {
        _selectedItemIds.remove(item.id);
      } else {
        _selectedItemIds.add(item.id);
      }
    });
    widget.onSelectionChanged(selectedItems);
  }

  void _toggleSelectAll(List<_VisibleTreeRow> visibleRows) {
    widget.onFocus();
    final visibleIds = visibleRows.map((r) => r.item.id).toSet();
    final allVisibleSelected =
        visibleIds.isNotEmpty && visibleIds.every((id) => _selectedItemIds.contains(id));
    setState(() {
      if (allVisibleSelected) {
        _selectedItemIds.removeAll(visibleIds);
      } else {
        _selectedItemIds.addAll(visibleIds);
      }
    });
    widget.onSelectionChanged(selectedItems);
  }

  List<_VisibleTreeRow> _buildVisibleUnifiedRows() {
    final List<_VisibleTreeRow> rows = [];
    final visited = <String>{};

    void appendItems(List<CloudItem> items, int depth) {
      for (final item in items) {
        rows.add(_VisibleTreeRow(item: item, depth: depth));
        if (item.isFolder &&
            _treeExpanded.contains(item.id) &&
            visited.add(item.id)) {
          final children = _treeChildren[item.id];
          if (children != null && children.isNotEmpty) {
            appendItems(children, depth + 1);
          }
        }
      }
    }

    appendItems(_items, 0);
    return rows;
  }

  Future<void> _handleDroppedPaths(List<String> paths) async {
    if (paths.isEmpty) return;

    final queueMgr = ref.read(transferQueueManagerProvider);
    final targetFolderId = _folderStack.last.key;
    final List<TransferTask> plannedTasks = [];
    int seq = 0;

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
        final groupId = 'group_${DateTime.now().millisecondsSinceEpoch}_${seq++}_${fileName.hashCode}';
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

        final taskId = 'task_${DateTime.now().microsecondsSinceEpoch}_${seq++}_${fileName.hashCode}';
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

  Future<void> _promptCreateFolder({String? parentId}) async {
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
        final targetParent = parentId ?? _folderStack.last.key;
        await provider.createFolder(parentId: targetParent, folderName: name);
        await _loadTreeChildren(targetParent);
        if (targetParent == _folderStack.last.key) {
          await _loadFolder(forceTreeRefresh: true);
        }
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
        await _loadFolder(forceTreeRefresh: true);
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('삭제 실패: $e')));
        }
      }
    }
  }

  Future<void> _showItemDetails(CloudItem item) async {
    final typeLabel = item.isFolder ? '폴더' : SortUtils.getCloudItemTypeLabel(item);
    final sizeLabel = item.isFolder
        ? '-'
        : (item.size != null ? '${FormatUtils.formatBytes(item.size!)} (${item.size} B)' : '크기 미상');
    final modifiedLabel = item.modifiedTime != null
        ? DateFormat('yyyy-MM-dd HH:mm:ss').format(item.modifiedTime!)
        : '정보 없음';

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            Icon(
              item.isFolder ? Icons.folder_rounded : Icons.insert_drive_file_outlined,
              color: item.isFolder ? Colors.amber : Colors.blueAccent,
            ),
            const SizedBox(width: 8),
            const Expanded(
              child: Text('상세 정보', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildDetailRow('이름', item.name),
            _buildDetailRow('유형', typeLabel),
            if (!item.isFolder) _buildDetailRow('크기', sizeLabel),
            _buildDetailRow('수정 일시', modifiedLabel),
            _buildDetailRow('저장소', '${widget.account.name} (${item.providerType.displayName})'),
            _buildDetailRow('경로 / ID', item.path ?? item.id),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('닫기')),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.blueAccent),
            onPressed: () {
              Navigator.pop(ctx);
              widget.onTransferToOpposite([item], widget.account);
            },
            icon: Icon(
              widget.isLeftPane ? Icons.arrow_forward_rounded : Icons.arrow_back_rounded,
              size: 16,
              color: Colors.white,
            ),
            label: Text(widget.oppositeLabel, style: const TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  Widget _buildDetailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 72,
            child: Text(label, style: const TextStyle(fontSize: 12, color: Colors.white54)),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: const TextStyle(fontSize: 12, color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final visibleRows = _buildVisibleUnifiedRows();
    final allSelected = visibleRows.isNotEmpty &&
        visibleRows.every((r) => _selectedItemIds.contains(r.item.id));

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTapDown: (_) => widget.onFocus(),
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(
            color: widget.isFocused ? Colors.blueAccent.withAlpha(140) : const Color(0xFF283142),
            width: widget.isFocused ? 1.5 : 1,
          ),
          borderRadius: BorderRadius.circular(8),
          color: const Color(0xFF0F141C),
        ),
        clipBehavior: Clip.antiAlias,
        child: Material(
          type: MaterialType.transparency,
          child: DropTarget(
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
                  // 1. Account Selector Header
                  _buildPaneHeader(),

                  // 2. Breadcrumb Path Bar
                  BreadcrumbBar(
                    folderStack: _folderStack,
                    onSelectIndex: _navigateToIndex,
                  ),

                  // 3. Action Toolbar
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    color: const Color(0xFF181F2C),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 24,
                          height: 24,
                          child: Checkbox(
                            value: allSelected,
                            onChanged: visibleRows.isEmpty ? null : (_) => _toggleSelectAll(visibleRows),
                            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            visualDensity: VisualDensity.compact,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          '${_items.length}개',
                          style: const TextStyle(fontSize: 11.5, color: Colors.white54),
                        ),
                        const SizedBox(width: 8),
                        _buildSortMenuButton(),
                        const Spacer(),
                        if (_treeExpanded.isNotEmpty) ...[
                          IconButton(
                            icon: const Icon(Icons.unfold_less_rounded, size: 18, color: Colors.white70),
                            tooltip: '펼친 폴더 모두 접기',
                            onPressed: () => setState(() => _treeExpanded.clear()),
                            padding: const EdgeInsets.all(4),
                            constraints: const BoxConstraints(),
                          ),
                          const SizedBox(width: 6),
                        ],
                        IconButton(
                          icon: const Icon(Icons.upload_file_outlined, size: 18),
                          tooltip: '파일 업로드 선택',
                          onPressed: _promptUploadFiles,
                          padding: const EdgeInsets.all(4),
                          constraints: const BoxConstraints(),
                        ),
                        const SizedBox(width: 6),
                        IconButton(
                          icon: const Icon(Icons.create_new_folder_outlined, size: 18),
                          tooltip: '새 폴더 생성',
                          onPressed: () => _promptCreateFolder(),
                          padding: const EdgeInsets.all(4),
                          constraints: const BoxConstraints(),
                        ),
                        const SizedBox(width: 6),
                        IconButton(
                          icon: const Icon(Icons.refresh, size: 18),
                          tooltip: '새로고침',
                          onPressed: () => _loadFolder(forceTreeRefresh: true),
                          padding: const EdgeInsets.all(4),
                          constraints: const BoxConstraints(),
                        ),
                      ],
                    ),
                  ),

                  // 4. Unified Tree & File List
                  Expanded(
                    child: _buildUnifiedItemsList(visibleRows),
                  ),

                  // 5. Bottom Selection Action Bar
                  if (_selectedItemIds.isNotEmpty) _buildSelectionActionBar(),
                ],
              ),

              // Drag Over Visual Indicator
              if (_isDragging)
                Container(
                  color: Colors.blueAccent.withAlpha(50),
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                      decoration: BoxDecoration(
                        color: const Color(0xFF181F2C),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.blueAccent, width: 2),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.file_download, color: Colors.blueAccent, size: 28),
                          SizedBox(width: 10),
                          Text(
                            '현재 폴더로 업로드',
                            style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.white),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        ),
      ),
    );
  }

  Widget _buildPaneHeader() {
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      color: widget.isFocused ? const Color(0xFF1D273B) : const Color(0xFF161C28),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
            decoration: BoxDecoration(
              color: widget.isLeftPane
                  ? Colors.blueAccent.withAlpha(35)
                  : Colors.tealAccent.withAlpha(30),
              borderRadius: BorderRadius.circular(5),
              border: Border.all(
                color: widget.isLeftPane
                    ? Colors.blueAccent.withAlpha(110)
                    : Colors.tealAccent.withAlpha(90),
              ),
            ),
            child: Text(
              widget.paneRoleLabel,
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.bold,
                color: widget.isLeftPane ? Colors.blueAccent : Colors.tealAccent,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Tooltip(
              message: '클라우드 / 저장소 변경',
              child: Container(
                height: 32,
                padding: const EdgeInsets.only(left: 10, right: 6),
                decoration: BoxDecoration(
                  color: const Color(0xFF232D42),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: widget.isFocused
                        ? Colors.blueAccent.withAlpha(140)
                        : Colors.white24,
                  ),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: widget.accounts.any((a) => a.id == widget.account.id)
                        ? widget.account.id
                        : null,
                    isExpanded: true,
                    isDense: true,
                    dropdownColor: const Color(0xFF1E2638),
                    icon: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 1,
                          height: 16,
                          margin: const EdgeInsets.symmetric(horizontal: 6),
                          color: Colors.white12,
                        ),
                        const Icon(Icons.keyboard_arrow_down_rounded, size: 20, color: Colors.white),
                      ],
                    ),
                    items: widget.accounts.map((acc) {
                      return DropdownMenuItem<String>(
                        value: acc.id,
                        child: Row(
                          children: [
                            Icon(_getAccountIcon(acc.type), size: 16, color: Colors.blueAccent),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                acc.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                              ),
                            ),
                          ],
                        ),
                      );
                    }).toList(),
                    onChanged: (accId) {
                      if (accId == null) return;
                      widget.onFocus();
                      final found = widget.accounts.firstWhere(
                        (a) => a.id == accId,
                        orElse: () => widget.account,
                      );
                      widget.onAccountChanged(found);
                    },
                  ),
                ),
              ),
            ),
          ),
          if (widget.account.id != 'local' && widget.onRemoveAccount != null)
            IconButton(
              icon: const Icon(Icons.delete_outline, size: 17, color: Colors.redAccent),
              tooltip: '계정 연결 해제',
              onPressed: widget.onRemoveAccount,
              padding: const EdgeInsets.all(4),
              constraints: const BoxConstraints(),
            ),
        ],
      ),
    );
  }

  Widget _buildUnifiedItemsList(List<_VisibleTreeRow> visibleRows) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_errorMessage != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 40, color: Colors.redAccent),
              const SizedBox(height: 10),
              Text(_errorMessage!, textAlign: TextAlign.center, style: const TextStyle(fontSize: 12.5)),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: () => _loadFolder(forceTreeRefresh: true),
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('다시 시도'),
              ),
            ],
          ),
        ),
      );
    }
    if (visibleRows.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.folder_open_outlined, size: 40, color: Colors.white24),
              SizedBox(height: 8),
              Text('폴더가 비어 있습니다.', style: TextStyle(color: Colors.white54, fontSize: 13)),
              SizedBox(height: 4),
              Text(
                '외부 파일/폴더를 드래그 앤 드롭하거나 반대쪽 패널에서 전송할 수 있습니다.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11, color: Colors.white38),
              ),
            ],
          ),
        ),
      );
    }

    return ListView.builder(
      itemCount: visibleRows.length,
      itemBuilder: (context, index) {
        final row = visibleRows[index];
        final item = row.item;
        final isSelected = _selectedItemIds.contains(item.id);
        final isExpanded = item.isFolder && _treeExpanded.contains(item.id);
        final isExpandLoading = item.isFolder && _treeLoading.contains(item.id);

        return CloudItemTile(
          item: item,
          isSelected: isSelected,
          showCheckbox: true,
          treeDepth: row.depth,
          isExpanded: isExpanded,
          isExpandLoading: isExpandLoading,
          onToggleExpand: item.isFolder ? () => _toggleTreeExpand(item.id) : null,
          onTap: () {
            if (item.isFolder) {
              _navigateToFolder(item);
            } else {
              _toggleSelection(item);
            }
          },
          onLongPress: () => _toggleSelection(item),
          onOpen: item.isFolder ? () => _navigateToFolder(item) : null,
          onSelect: () => _toggleSelection(item),
          onTransfer: () => widget.onTransferToOpposite([item], widget.account),
          onDetails: () => _showItemDetails(item),
          onDelete: () => _confirmDelete(item),
        );
      },
    );
  }

  Widget _buildSelectionActionBar() {
    final selected = selectedItems;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      color: const Color(0xFF1F293D),
      child: Row(
        children: [
          Text(
            '${selected.length}개 선택',
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
          ),
          const SizedBox(width: 6),
          TextButton(
            onPressed: clearSelection,
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text('해제', style: TextStyle(fontSize: 12)),
          ),
          const Spacer(),
          if (widget.onTransferCustom != null)
            IconButton(
              icon: const Icon(Icons.drive_file_move_outlined, size: 18, color: Colors.white70),
              tooltip: '다른 저장소 선택하여 전송',
              onPressed: () => widget.onTransferCustom!(selected, widget.account),
              padding: const EdgeInsets.all(6),
              constraints: const BoxConstraints(),
            ),
          const SizedBox(width: 4),
          Flexible(
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blueAccent,
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              ),
              onPressed: () => widget.onTransferToOpposite(selected, widget.account),
              icon: Icon(
                widget.isLeftPane ? Icons.arrow_forward_rounded : Icons.arrow_back_rounded,
                size: 16,
                color: Colors.white,
              ),
              label: Text(
                widget.oppositeLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 12),
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
        height: 26,
        padding: const EdgeInsets.symmetric(horizontal: 7),
        decoration: BoxDecoration(
          color: Colors.white.withAlpha(15),
          borderRadius: BorderRadius.circular(5),
          border: Border.all(color: Colors.white12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.sort_rounded, size: 13, color: Colors.blueAccent),
            const SizedBox(width: 4),
            Text(
              _sortField.label,
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Colors.white),
            ),
            const SizedBox(width: 2),
            Icon(
              _sortAscending ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded,
              size: 12,
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
              if (_sortAscending) const Icon(Icons.check, size: 16, color: Colors.blueAccent),
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
              if (!_sortAscending) const Icon(Icons.check, size: 16, color: Colors.blueAccent),
            ],
          ),
        ),
      ],
    );
  }

  IconData _getAccountIcon(CloudProviderType type) {
    switch (type) {
      case CloudProviderType.googleDrive:
        return Icons.add_to_drive;
      case CloudProviderType.terabox:
        return Icons.cloud_circle_outlined;
      case CloudProviderType.baidu:
        return Icons.cloud_done_outlined;
      case CloudProviderType.naver:
        return Icons.cloud_queue_rounded;
      case CloudProviderType.mega:
        return Icons.lock_outline_rounded;
      case CloudProviderType.local:
      default:
        return Icons.phone_android_rounded;
    }
  }
}
