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
import '../widgets/target_picker_sheet.dart';
import 'add_account_dialog.dart';
import 'explorer_tab_view.dart';
import 'settings_dialog.dart';
import 'transfer_dashboard_screen.dart';

class MainShellScreen extends ConsumerStatefulWidget {
  const MainShellScreen({super.key});

  @override
  ConsumerState<MainShellScreen> createState() => _MainShellScreenState();
}

class _MainShellScreenState extends ConsumerState<MainShellScreen> with SingleTickerProviderStateMixin {
  TabController? _tabController;

  @override
  void dispose() {
    _tabController?.dispose();
    super.dispose();
  }

  void _updateTabController(int count) {
    if (_tabController?.length != count) {
      _tabController?.dispose();
      _tabController = TabController(length: count, vsync: this);
    }
  }

  Future<void> _showAddAccountDialog() async {
    final newAccount = await showDialog<CloudAccount>(
      context: context,
      builder: (_) => const AddAccountDialog(),
    );
    if (newAccount != null) {
      await ref.read(accountsProvider.notifier).saveAccount(newAccount);
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
      final currentIdx = _tabController?.index ?? 0;
      if (currentIdx > 0) {
        _tabController?.animateTo(currentIdx - 1);
      }
      await ref.read(accountsProvider.notifier).removeAccount(account.id);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('\'${account.name}\' 계정이 삭제되었습니다.')),
        );
      }
    }
  }

  void _handleTransferRequest(List<CloudItem> selectedItems, CloudAccount sourceAccount) {
    final accounts = ref.read(accountsProvider);
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => TargetPickerSheet(
        accounts: accounts,
        currentAccountId: sourceAccount.id,
        onSelectAccount: (targetAccount) => _executeTransfer(selectedItems, sourceAccount, targetAccount),
      ),
    );
  }

  Future<void> _executeTransfer(
    List<CloudItem> items,
    CloudAccount sourceAccount,
    CloudAccount targetAccount,
  ) async {
    final queueMgr = ref.read(transferQueueManagerProvider);
    final settings = ref.read(settingsProvider);
    final List<TransferTask> plannedTasks = [];

    final targetProvider = queueMgr.getProvider(targetAccount.id);
    final sourceProvider = queueMgr.getProvider(sourceAccount.id);
    if (targetProvider == null || sourceProvider == null) return;

    // Determine destination directory
    String destRoot = '';
    if (targetAccount.type == CloudProviderType.local) {
      if (settings.askDownloadPathEveryTime) {
        final chosenDir = await FilePicker.getDirectoryPath(
          dialogTitle: '다운로드할 대상 폴더 선택',
          initialDirectory: settings.defaultDownloadPath.isNotEmpty ? settings.defaultDownloadPath : null,
        );
        if (chosenDir == null || chosenDir.isEmpty) return; // User cancelled
        destRoot = chosenDir;
      } else {
        destRoot = settings.defaultDownloadPath.isNotEmpty ? settings.defaultDownloadPath : '';
      }
    } else {
      destRoot = 'root';
    }

    for (final item in items) {
      if (item.isFolder) {
        // Recursive folder handling
        final handler = RecursiveFolderHandler({
          sourceAccount.id: sourceProvider,
          targetAccount.id: targetProvider,
        });
        final groupId = 'group_${DateTime.now().millisecondsSinceEpoch}_${item.name.hashCode}';
        final folderTasks = await handler.planFolderTransfer(
          sourceAccountId: sourceAccount.id,
          destAccountId: targetAccount.id,
          sourceFolderIdOrPath: item.id,
          sourceFolderName: item.name,
          destParentFolderIdOrPath: destRoot,
          groupId: groupId,
        );
        plannedTasks.addAll(folderTasks);
      } else {
        // Single file handling
        TransferTaskType taskType = TransferTaskType.download;
        if (sourceAccount.type == CloudProviderType.local && targetAccount.type != CloudProviderType.local) {
          taskType = TransferTaskType.upload;
        } else if (sourceAccount.type != CloudProviderType.local && targetAccount.type == CloudProviderType.local) {
          taskType = TransferTaskType.download;
        } else {
          taskType = TransferTaskType.cloudToCloud;
        }

        final taskId = 'task_${DateTime.now().microsecondsSinceEpoch}_${item.name.hashCode}';
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${plannedTasks.length}개 전송 작업이 큐에 추가되었습니다.')),
        );
      }
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

    _updateTabController(accounts.length);

    final activeCount = activeTasksAsync.valueOrNull?.length ?? 0;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Unified Cloud Manager', style: TextStyle(fontWeight: FontWeight.bold)),
        actions: [
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
        bottom: TabBar(
          controller: _tabController,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          indicatorColor: Colors.blueAccent,
          tabs: accounts.map((acc) {
            final isLocal = acc.id == 'local';
            return Tab(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(_getAccountIcon(acc.type), size: 16),
                  const SizedBox(width: 8),
                  Text(acc.name),
                  if (!isLocal) ...[
                    const SizedBox(width: 4),
                    InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () => _confirmRemoveAccount(acc),
                      child: const Padding(
                        padding: EdgeInsets.all(2),
                        child: Icon(Icons.close, size: 14, color: Colors.white54),
                      ),
                    ),
                  ],
                ],
              ),
            );
          }).toList(),
        ),
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: accounts.map((acc) {
                  return ExplorerTabView(
                    account: acc,
                    onRequestTransfer: _handleTransferRequest,
                    onRemoveAccount: () => _confirmRemoveAccount(acc),
                  );
                }).toList(),
              ),
            ),
            if (activeCount > 0) _buildMiniTransferBar(queueMgr, activeCount),
          ],
        ),
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
