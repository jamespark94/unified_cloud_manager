import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/cloud/cloud_credentials.dart';
import '../../core/cloud/cloud_item.dart';
import '../../core/database/transfer_task_entity.dart';
import '../../core/transfer/recursive_folder_handler.dart';
import '../../core/transfer/transfer_queue_manager.dart';
import '../../core/utils/format_utils.dart';
import '../../state/accounts_provider.dart';
import '../../state/settings_provider.dart';
import '../../state/transfer_queue_provider.dart';
import '../widgets/explorer_pane.dart';
import '../widgets/target_picker_sheet.dart';
import 'add_account_dialog.dart';
import 'settings_dialog.dart';
import 'transfer_dashboard_screen.dart';

class MainShellScreen extends ConsumerStatefulWidget {
  const MainShellScreen({super.key});

  @override
  ConsumerState<MainShellScreen> createState() => _MainShellScreenState();
}

class _MainShellScreenState extends ConsumerState<MainShellScreen> {
  final GlobalKey<ExplorerPaneState> _leftPaneKey = GlobalKey<ExplorerPaneState>();
  final GlobalKey<ExplorerPaneState> _rightPaneKey = GlobalKey<ExplorerPaneState>();

  String? _leftAccountId;
  String? _rightAccountId;
  int _focusedPaneIndex = 0; // 0 = left, 1 = right

  List<MapEntry<String, String>> _leftStack = const [MapEntry('root', '홈')];
  List<MapEntry<String, String>> _rightStack = const [MapEntry('root', '내 기기')];
  List<CloudItem> _leftSelected = const [];
  List<CloudItem> _rightSelected = const [];

  @override
  void dispose() {
    super.dispose();
  }

  void _syncPaneAccounts(List<CloudAccount> accounts) {
    if (accounts.isEmpty) return;

    final hasLeft = _leftAccountId != null && accounts.any((a) => a.id == _leftAccountId);
    final hasRight = _rightAccountId != null && accounts.any((a) => a.id == _rightAccountId);

    if (!hasLeft) {
      final firstCloud = accounts.where((a) => a.id != 'local').firstOrNull;
      _leftAccountId = (firstCloud ?? accounts.first).id;
    }
    if (!hasRight) {
      final localAcc = accounts.where((a) => a.id == 'local').firstOrNull;
      if (localAcc != null && localAcc.id != _leftAccountId) {
        _rightAccountId = localAcc.id;
      } else {
        final other = accounts.where((a) => a.id != _leftAccountId).firstOrNull;
        _rightAccountId = (other ?? accounts.first).id;
      }
    }
  }

  CloudAccount _findAccount(List<CloudAccount> accounts, String? id) {
    return accounts.firstWhere(
      (a) => a.id == id,
      orElse: () => accounts.first,
    );
  }

  Future<void> _showAddAccountDialog() async {
    final newAccount = await showDialog<CloudAccount>(
      context: context,
      builder: (_) => const AddAccountDialog(),
    );
    if (newAccount != null) {
      await ref.read(accountsProvider.notifier).saveAccount(newAccount);
      setState(() {
        if (_leftAccountId == 'local' && _rightAccountId == 'local') {
          _leftAccountId = newAccount.id;
        }
      });
    }
  }

  Future<void> _showSettingsDialog() async {
    await showDialog(
      context: context,
      builder: (_) => const SettingsDialog(),
    );
  }

  Future<void> _confirmRemoveAccount(CloudAccount account) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('클라우드 계정 삭제'),
        content: Text('\'${account.name}\' 클라우드 계정 연결을 해제하시겠습니까?\n(클라우드의 실제 파일은 삭제되지 않습니다)'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('취소')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('삭제/연결 해제', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await ref.read(accountsProvider.notifier).removeAccount(account.id);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('\'${account.name}\' 계정이 삭제되었습니다.')),
        );
      }
    }
  }

  void _swapPanes() {
    final leftSnap = _leftPaneKey.currentState?.exportState();
    final rightSnap = _rightPaneKey.currentState?.exportState();
    final accountsDiffer = _leftAccountId != _rightAccountId;
    if (accountsDiffer) {
      _leftPaneKey.currentState?.suppressNextAccountReset();
      _rightPaneKey.currentState?.suppressNextAccountReset();
    }

    setState(() {
      final tmpAcc = _leftAccountId;
      _leftAccountId = _rightAccountId;
      _rightAccountId = tmpAcc;

      final tmpStack = _leftStack;
      _leftStack = _rightStack;
      _rightStack = tmpStack;

      final tmpSel = _leftSelected;
      _leftSelected = _rightSelected;
      _rightSelected = tmpSel;

      _focusedPaneIndex = _focusedPaneIndex == 0 ? 1 : 0;
    });

    if (leftSnap != null && rightSnap != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _leftPaneKey.currentState?.importState(rightSnap);
        _rightPaneKey.currentState?.importState(leftSnap);
      });
    }
  }

  String _formatOppositeTargetLabel(CloudAccount targetAccount, List<MapEntry<String, String>> stack) {
    final folderName = stack.isNotEmpty
        ? stack.last.value
        : (targetAccount.type == CloudProviderType.local ? '내 기기' : '홈');
    return '${targetAccount.name}: $folderName';
  }

  Future<void> _handleTransferToOpposite({
    required List<CloudItem> selectedItems,
    required CloudAccount sourceAccount,
    required CloudAccount targetAccount,
    required List<MapEntry<String, String>> targetStack,
    required GlobalKey<ExplorerPaneState> sourcePaneKey,
    required GlobalKey<ExplorerPaneState> targetPaneKey,
  }) async {
    if (selectedItems.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('전송할 파일 또는 폴더를 먼저 선택해 주세요.')),
      );
      return;
    }

    String destRoot = targetStack.isNotEmpty ? targetStack.last.key : 'root';

    if (targetAccount.type == CloudProviderType.local &&
        (destRoot.isEmpty || destRoot == 'root')) {
      final chosenDir = await _promptPickLocalDestination(targetAccount);
      if (chosenDir == null || chosenDir.isEmpty) return;
      destRoot = chosenDir;
    }

    // Prevent copying a folder into itself or one of its descendants
    if (sourceAccount.id == targetAccount.id) {
      for (final item in selectedItems) {
        if (item.isFolder &&
            (destRoot == item.id ||
                destRoot.startsWith('${item.id}${Platform.pathSeparator}') ||
                destRoot.startsWith('${item.id}/'))) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('\'${item.name}\' 폴더를 자기 자신 또는 하위 폴더로 전송할 수 없습니다.')),
            );
          }
          return;
        }
      }
    }

    await _executeTransfer(
      selectedItems,
      sourceAccount,
      targetAccount,
      explicitDestRoot: destRoot,
    );
    sourcePaneKey.currentState?.clearSelection();
    targetPaneKey.currentState?.refreshCurrentFolder();
  }

  Future<String?> _promptPickLocalDestination(CloudAccount targetAccount) async {
    final settings = ref.read(settingsProvider);
    final shouldPick = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('로컬 대상 폴더 선택', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        content: Text(
          '${targetAccount.name} 패널이 최상위 드라이브 목록에 있습니다.\n'
          '대상 패널의 트리에서 저장할 폴더를 먼저 선택하거나, 폴더 선택창에서 직접 지정하세요.',
          style: const TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('취소')),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.blueAccent),
            onPressed: () => Navigator.pop(ctx, true),
            icon: const Icon(Icons.folder_open, size: 16, color: Colors.white),
            label: const Text('폴더 직접 선택...', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (shouldPick != true) return null;
    return FilePicker.getDirectoryPath(
      dialogTitle: '다운로드할 대상 폴더 선택',
      initialDirectory: settings.defaultDownloadPath.isNotEmpty ? settings.defaultDownloadPath : null,
    );
  }

  void _handleCustomTransferRequest(List<CloudItem> selectedItems, CloudAccount sourceAccount) {
    final accounts = ref.read(accountsProvider);
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => TargetPickerSheet(
        accounts: accounts,
        currentAccountId: sourceAccount.id,
        onSelectAccount: (targetAccount) =>
            _executeTransfer(selectedItems, sourceAccount, targetAccount),
      ),
    );
  }

  Future<void> _executeTransfer(
    List<CloudItem> items,
    CloudAccount sourceAccount,
    CloudAccount targetAccount, {
    String? explicitDestRoot,
  }) async {
    final queueMgr = ref.read(transferQueueManagerProvider);
    final settings = ref.read(settingsProvider);
    final List<TransferTask> plannedTasks = [];
    int seq = 0;

    final targetProvider = queueMgr.getProvider(targetAccount.id);
    final sourceProvider = queueMgr.getProvider(sourceAccount.id);
    if (targetProvider == null || sourceProvider == null) return;

    String destRoot = explicitDestRoot ?? '';
    if (destRoot.isEmpty) {
      if (targetAccount.type == CloudProviderType.local) {
        if (settings.askDownloadPathEveryTime) {
          final chosenDir = await FilePicker.getDirectoryPath(
            dialogTitle: '다운로드할 대상 폴더 선택',
            initialDirectory:
                settings.defaultDownloadPath.isNotEmpty ? settings.defaultDownloadPath : null,
          );
          if (chosenDir == null || chosenDir.isEmpty) return;
          destRoot = chosenDir;
        } else {
          destRoot = settings.defaultDownloadPath.isNotEmpty ? settings.defaultDownloadPath : '';
        }
      } else {
        destRoot = 'root';
      }
    }

    int emptyFolderCount = 0;
    for (final item in items) {
      if (item.isFolder) {
        final handler = RecursiveFolderHandler({
          sourceAccount.id: sourceProvider,
          targetAccount.id: targetProvider,
        });
        final groupId = 'group_${DateTime.now().millisecondsSinceEpoch}_${seq++}_${item.name.hashCode}';
        final folderTasks = await handler.planFolderTransfer(
          sourceAccountId: sourceAccount.id,
          destAccountId: targetAccount.id,
          sourceFolderIdOrPath: item.id,
          sourceFolderName: item.name,
          destParentFolderIdOrPath: destRoot,
          groupId: groupId,
        );
        if (folderTasks.isEmpty) {
          emptyFolderCount++;
        } else {
          plannedTasks.addAll(folderTasks);
        }
      } else {
        TransferTaskType taskType = TransferTaskType.download;
        if (sourceAccount.type == CloudProviderType.local &&
            targetAccount.type != CloudProviderType.local) {
          taskType = TransferTaskType.upload;
        } else if (sourceAccount.type != CloudProviderType.local &&
            targetAccount.type == CloudProviderType.local) {
          taskType = TransferTaskType.download;
        } else {
          taskType = TransferTaskType.cloudToCloud;
        }

        final taskId = 'task_${DateTime.now().microsecondsSinceEpoch}_${seq++}_${item.name.hashCode}';
        plannedTasks.add(
          TransferTask(
            id: taskId,
            providerType: sourceAccount.type.code,
            sourceAccountId: sourceAccount.id,
            destAccountId: targetAccount.id,
            taskType: taskType,
            fileName: item.name,
            sourcePath: item.id,
            destinationPath: destRoot,
            totalBytes: item.size ?? 0,
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
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            duration: const Duration(seconds: 3),
            behavior: SnackBarBehavior.floating,
            content: Row(
              children: [
                Expanded(
                  child: Text('${plannedTasks.length}개 전송 작업이 큐에 추가되었습니다.'),
                ),
                TextButton(
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: () {
                    ScaffoldMessenger.of(context).hideCurrentSnackBar();
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const TransferDashboardScreen()),
                    );
                  },
                  child: const Text(
                    '전송 보기',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
          ),
        );
      }
    } else if (emptyFolderCount > 0 && mounted) {
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          duration: Duration(seconds: 3),
          behavior: SnackBarBehavior.floating,
          content: Text('폴더 내 파일이 없어 빈 폴더 구조만 생성되었습니다.'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final accounts = ref.watch(accountsProvider);
    final queueMgr = ref.watch(transferQueueManagerProvider);
    final activeTasksAsync = ref.watch(activeTasksProvider);

    if (accounts.isEmpty) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    _syncPaneAccounts(accounts);
    final leftAccount = _findAccount(accounts, _leftAccountId);
    final rightAccount = _findAccount(accounts, _rightAccountId);
    final activeCount = activeTasksAsync.valueOrNull?.length ?? 0;

    final leftPane = ExplorerPane(
      key: _leftPaneKey,
      paneId: 'left',
      paneRoleLabel: '좌측(원본)',
      isLeftPane: true,
      isFocused: _focusedPaneIndex == 0,
      accounts: accounts,
      account: leftAccount,
      onAccountChanged: (acc) => setState(() => _leftAccountId = acc.id),
      onFocus: () {
        if (_focusedPaneIndex != 0) setState(() => _focusedPaneIndex = 0);
      },
      onLocationChanged: (stack) => setState(() => _leftStack = stack),
      onSelectionChanged: (sel) => setState(() => _leftSelected = sel),
      onTransferToOpposite: (items, src) => _handleTransferToOpposite(
        selectedItems: items,
        sourceAccount: src,
        targetAccount: rightAccount,
        targetStack: _rightStack,
        sourcePaneKey: _leftPaneKey,
        targetPaneKey: _rightPaneKey,
      ),
      onTransferCustom: _handleCustomTransferRequest,
      oppositeLabel: _formatOppositeTargetLabel(rightAccount, _rightStack),
      onRemoveAccount: leftAccount.id != 'local' ? () => _confirmRemoveAccount(leftAccount) : null,
    );

    final rightPane = ExplorerPane(
      key: _rightPaneKey,
      paneId: 'right',
      paneRoleLabel: '우측(대상)',
      isLeftPane: false,
      isFocused: _focusedPaneIndex == 1,
      accounts: accounts,
      account: rightAccount,
      onAccountChanged: (acc) => setState(() => _rightAccountId = acc.id),
      onFocus: () {
        if (_focusedPaneIndex != 1) setState(() => _focusedPaneIndex = 1);
      },
      onLocationChanged: (stack) => setState(() => _rightStack = stack),
      onSelectionChanged: (sel) => setState(() => _rightSelected = sel),
      onTransferToOpposite: (items, src) => _handleTransferToOpposite(
        selectedItems: items,
        sourceAccount: src,
        targetAccount: leftAccount,
        targetStack: _leftStack,
        sourcePaneKey: _rightPaneKey,
        targetPaneKey: _leftPaneKey,
      ),
      onTransferCustom: _handleCustomTransferRequest,
      oppositeLabel: _formatOppositeTargetLabel(leftAccount, _leftStack),
      onRemoveAccount: rightAccount.id != 'local' ? () => _confirmRemoveAccount(rightAccount) : null,
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Unified Cloud Manager', style: TextStyle(fontWeight: FontWeight.bold)),
        actions: [
          IconButton(
            icon: const Icon(Icons.swap_horiz_rounded),
            tooltip: '왼쪽/오른쪽 창 위치 스왑',
            onPressed: _swapPanes,
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: '설정',
            onPressed: _showSettingsDialog,
          ),
          IconButton(
            icon: const Icon(Icons.add_circle_outline),
            tooltip: '클라우드 계정 추가',
            onPressed: _showAddAccountDialog,
          ),
          IconButton(
            icon: Badge(
              isLabelVisible: activeCount > 0,
              label: Text('$activeCount'),
              child: const Icon(Icons.swap_vert_circle_outlined),
            ),
            tooltip: '전송 대시보드',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const TransferDashboardScreen()),
              );
            },
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final isWide = constraints.maxWidth >= 720;
                  if (isWide) {
                    return Padding(
                      padding: const EdgeInsets.all(6),
                      child: Row(
                        children: [
                          Expanded(child: leftPane),
                          _buildCenterTransferStrip(leftAccount, rightAccount),
                          Expanded(child: rightPane),
                        ],
                      ),
                    );
                  }

                  // Compact dual-pane switcher for narrow mobile screens
                  return Column(
                    children: [
                      _buildMobilePaneSwitcher(leftAccount, rightAccount),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(6, 0, 6, 6),
                          child: IndexedStack(
                            index: _focusedPaneIndex,
                            children: [leftPane, rightPane],
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
            if (activeCount > 0) _buildMiniTransferBar(queueMgr, activeCount),
          ],
        ),
      ),
    );
  }

  ({String label, IconData typeIcon, Color accent}) _describeTransferDirection(
    CloudAccount source,
    CloudAccount target,
  ) {
    final srcLocal = source.type == CloudProviderType.local;
    final dstLocal = target.type == CloudProviderType.local;
    if (srcLocal && !dstLocal) {
      return (
        label: '업로드',
        typeIcon: Icons.cloud_upload_outlined,
        accent: Colors.blueAccent,
      );
    } else if (!srcLocal && dstLocal) {
      return (
        label: '다운로드',
        typeIcon: Icons.cloud_download_outlined,
        accent: Colors.tealAccent,
      );
    } else if (!srcLocal && !dstLocal) {
      return (
        label: '전송',
        typeIcon: Icons.cloud_sync_outlined,
        accent: Colors.orangeAccent,
      );
    } else {
      return (
        label: '복사',
        typeIcon: Icons.file_copy_outlined,
        accent: Colors.lightBlueAccent,
      );
    }
  }

  Widget _buildCenterTransferButton({
    required bool isLeftToRight,
    required int selectedCount,
    required CloudAccount sourceAccount,
    required CloudAccount targetAccount,
    required List<MapEntry<String, String>> targetStack,
    required VoidCallback onPressed,
  }) {
    final dir = _describeTransferDirection(sourceAccount, targetAccount);
    final hasSelection = selectedCount > 0;
    final arrowIcon = isLeftToRight ? Icons.arrow_forward_rounded : Icons.arrow_back_rounded;
    final targetLabel = _formatOppositeTargetLabel(targetAccount, targetStack);

    return Tooltip(
      message: '${dir.label}: ${sourceAccount.name} → $targetLabel',
      child: Badge(
        isLabelVisible: hasSelection,
        label: Text('$selectedCount'),
        child: Material(
          color: hasSelection ? dir.accent.withAlpha(48) : const Color(0xFF1A2233),
          borderRadius: BorderRadius.circular(10),
          child: InkWell(
            onTap: onPressed,
            borderRadius: BorderRadius.circular(10),
            child: Container(
              width: 72,
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: hasSelection ? dir.accent : dir.accent.withAlpha(90),
                  width: hasSelection ? 1.5 : 1,
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (!isLeftToRight) ...[
                        Icon(arrowIcon, size: 17, color: dir.accent),
                        const SizedBox(width: 2),
                      ],
                      Icon(dir.typeIcon, size: 17, color: dir.accent),
                      if (isLeftToRight) ...[
                        const SizedBox(width: 2),
                        Icon(arrowIcon, size: 17, color: dir.accent),
                      ],
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    dir.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.bold,
                      color: hasSelection ? Colors.white : Colors.white70,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCenterTransferStrip(CloudAccount leftAccount, CloudAccount rightAccount) {
    final leftCount = _leftSelected.length;
    final rightCount = _rightSelected.length;

    return SizedBox(
      width: 82,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _buildCenterTransferButton(
            isLeftToRight: true,
            selectedCount: leftCount,
            sourceAccount: leftAccount,
            targetAccount: rightAccount,
            targetStack: _rightStack,
            onPressed: () => _handleTransferToOpposite(
              selectedItems: _leftSelected,
              sourceAccount: leftAccount,
              targetAccount: rightAccount,
              targetStack: _rightStack,
              sourcePaneKey: _leftPaneKey,
              targetPaneKey: _rightPaneKey,
            ),
          ),
          const SizedBox(height: 14),
          Tooltip(
            message: '왼쪽/오른쪽 창 위치 스왑',
            child: OutlinedButton(
              onPressed: _swapPanes,
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(72, 42),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                side: const BorderSide(color: Colors.white24),
                backgroundColor: const Color(0xFF161D2B),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              child: const Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.swap_horiz_rounded, size: 18, color: Colors.white70),
                  SizedBox(height: 2),
                  Text(
                    '창 스왑',
                    style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: Colors.white70),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),
          _buildCenterTransferButton(
            isLeftToRight: false,
            selectedCount: rightCount,
            sourceAccount: rightAccount,
            targetAccount: leftAccount,
            targetStack: _leftStack,
            onPressed: () => _handleTransferToOpposite(
              selectedItems: _rightSelected,
              sourceAccount: rightAccount,
              targetAccount: leftAccount,
              targetStack: _leftStack,
              sourcePaneKey: _rightPaneKey,
              targetPaneKey: _leftPaneKey,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMobilePaneSwitcher(CloudAccount leftAccount, CloudAccount rightAccount) {
    final leftFolder = _leftStack.isNotEmpty ? _leftStack.last.value : '홈';
    final rightFolder = _rightStack.isNotEmpty ? _rightStack.last.value : '내 기기';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      color: const Color(0xFF131924),
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => setState(() => _focusedPaneIndex = 0),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: _focusedPaneIndex == 0
                      ? Colors.blueAccent.withAlpha(35)
                      : const Color(0xFF181F2C),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: _focusedPaneIndex == 0 ? Colors.blueAccent : Colors.white12,
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '좌측(원본): ${leftAccount.name}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                    ),
                    Text(
                      leftFolder,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 10.5, color: Colors.white60),
                    ),
                  ],
                ),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.swap_horiz_rounded, size: 20, color: Colors.white54),
            tooltip: '좌우 전환',
            onPressed: _swapPanes,
          ),
          Expanded(
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => setState(() => _focusedPaneIndex = 1),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: _focusedPaneIndex == 1
                      ? Colors.tealAccent.withAlpha(28)
                      : const Color(0xFF181F2C),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: _focusedPaneIndex == 1 ? Colors.tealAccent : Colors.white12,
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '우측(대상): ${rightAccount.name}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                    ),
                    Text(
                      rightFolder,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 10.5, color: Colors.white60),
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

  Widget _buildMiniTransferBar(TransferQueueManager queueMgr, int count) {
    return InkWell(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const TransferDashboardScreen()),
        );
      },
      child: Container(
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        color: const Color(0xFF1E283D),
        child: Row(
          children: [
            const Icon(Icons.sync, size: 18, color: Colors.blueAccent),
            const SizedBox(width: 8),
            Text(
              '$count개 작업 전송 중',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
            ),
            const Spacer(),
            Text(
              FormatUtils.formatSpeed(queueMgr.currentSpeedBytesPerSec),
              style: const TextStyle(fontSize: 12, color: Colors.blueAccent, fontWeight: FontWeight.w600),
            ),
            const SizedBox(width: 8),
            const Icon(Icons.chevron_right, size: 16, color: Colors.white54),
          ],
        ),
      ),
    );
  }
}
