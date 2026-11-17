import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:unified_cloud_manager/core/cloud/cloud_credentials.dart';
import 'package:unified_cloud_manager/core/cloud/cloud_item.dart';
import 'package:unified_cloud_manager/core/cloud/cloud_storage_provider.dart';
import 'package:unified_cloud_manager/core/database/app_database.dart';
import 'package:unified_cloud_manager/core/database/transfer_task_entity.dart';
import 'package:unified_cloud_manager/core/transfer/recursive_folder_handler.dart';
import 'package:unified_cloud_manager/core/transfer/speed_estimator.dart';
import 'package:unified_cloud_manager/core/transfer/transfer_queue_manager.dart';
import 'package:unified_cloud_manager/core/transfer/transfer_tree_builder.dart';
import 'package:unified_cloud_manager/state/accounts_provider.dart';
import 'package:unified_cloud_manager/ui/screens/main_shell_screen.dart';
import 'package:unified_cloud_manager/ui/screens/transfer_dashboard_screen.dart';

class _InMemoryTreeProvider implements CloudStorageProvider {
  @override
  final String providerId;
  @override
  final String providerName;
  @override
  final CloudProviderType providerType;

  final Map<String, List<CloudItem>> tree;
  final List<({String parentId, String folderName})> createdFolders = [];

  _InMemoryTreeProvider({
    required this.providerId,
    required this.providerName,
    required this.providerType,
    required this.tree,
  });

  @override
  Future<List<CloudItem>> listItems({required String folderIdOrPath}) async {
    return List<CloudItem>.from(tree[folderIdOrPath] ?? const []);
  }

  @override
  Future<CloudItem> createFolder({required String parentId, required String folderName}) async {
    createdFolders.add((parentId: parentId, folderName: folderName));
    final newId = '$parentId/$folderName';
    final item = CloudItem(
      id: newId,
      name: folderName,
      parentId: parentId,
      path: newId,
      isFolder: true,
      providerType: providerType,
      accountId: providerId,
    );
    tree.putIfAbsent(parentId, () => []).add(item);
    tree.putIfAbsent(newId, () => []);
    return item;
  }

  @override
  Future<void> deleteItem({required String idOrPath, required bool isFolder}) async {}

  @override
  Future<Stream<List<int>>> downloadStream({
    required String fileId,
    int? startByte,
    int? endByte,
    CancelToken? cancelToken,
    void Function(int actualStartByte)? onActualStartByte,
  }) async {
    onActualStartByte?.call(0);
    return const Stream.empty();
  }

  @override
  Future<void> uploadStream({
    required String parentId,
    required String fileName,
    required Stream<List<int>> stream,
    required int length,
    Function(int bytesSent, int totalBytes)? onProgress,
  }) async {}
}

class _TestAccountsNotifier extends AccountsNotifier {
  final Map<String, CloudStorageProvider> fakeProviders;
  final List<CloudAccount> initialAccounts;

  _TestAccountsNotifier({
    required this.initialAccounts,
    required this.fakeProviders,
  });

  @override
  Future<void> loadAccounts() async {
    for (final p in fakeProviders.values) {
      TransferQueueManager.instance.registerProvider(p);
    }
    state = initialAccounts;
  }

  @override
  CloudStorageProvider createProviderForAccount(CloudAccount acc) {
    return fakeProviders[acc.id]!;
  }
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await AppDatabase.instance.initInMemoryForTest();
  });

  group('SlidingWindowSpeedEstimator stability', () {
    test('smooths bursty chunks and brief 0-byte pauses without jumping to 0 or huge spikes', () {
      var now = DateTime(2026, 1, 1, 0, 0, 0);
      final estimator = SlidingWindowSpeedEstimator(
        windowDuration: const Duration(seconds: 4),
        emaAlpha: 0.35,
        clock: () => now,
      );

      final speeds = <double>[];
      // Simulate 10 seconds at ~1 MB/s average, where odd 500ms ticks deliver 1 MB and even ticks deliver 0 B
      for (int step = 1; step <= 20; step++) {
        now = now.add(const Duration(milliseconds: 500));
        if (step.isOdd) {
          estimator.recordBytes(1024 * 1024);
        }
        speeds.add(estimator.tick());
      }

      // After initial warm-up (step >= 6, i.e. 3s+), speed must never drop to 0 and stay near 1 MB/s
      final steadySpeeds = speeds.sublist(6);
      for (final s in steadySpeeds) {
        expect(s, greaterThan(650 * 1024));
        expect(s, lessThan(1500 * 1024));
      }

      // Simulate true stall for 5 seconds -> speed decays cleanly to 0
      for (int i = 0; i < 20; i++) {
        now = now.add(const Duration(milliseconds: 500));
        estimator.tick();
      }
      expect(estimator.currentSpeed, 0.0);
    });
  });

  group('RecursiveFolderHandler & TransferTreeBuilder', () {
    test('plans folder transfer with relativePath and builds nested tree with aggregate stats', () async {
      final src = _InMemoryTreeProvider(
        providerId: 'src_cloud',
        providerName: 'Source Cloud',
        providerType: CloudProviderType.googleDrive,
        tree: {
          'folder_root': [
            const CloudItem(
              id: 'sub_a',
              name: 'Season 1',
              isFolder: true,
              providerType: CloudProviderType.googleDrive,
              accountId: 'src_cloud',
            ),
            const CloudItem(
              id: 'file_readme',
              name: 'readme.txt',
              isFolder: false,
              size: 1000,
              providerType: CloudProviderType.googleDrive,
              accountId: 'src_cloud',
            ),
          ],
          'sub_a': [
            const CloudItem(
              id: 'sub_nested',
              name: 'Extras',
              isFolder: true,
              providerType: CloudProviderType.googleDrive,
              accountId: 'src_cloud',
            ),
            const CloudItem(
              id: 'file_ep1',
              name: 'ep01.mp4',
              isFolder: false,
              size: 4000,
              providerType: CloudProviderType.googleDrive,
              accountId: 'src_cloud',
            ),
          ],
          'sub_nested': [
            const CloudItem(
              id: 'file_op',
              name: 'opening.mp4',
              isFolder: false,
              size: 2000,
              providerType: CloudProviderType.googleDrive,
              accountId: 'src_cloud',
            ),
          ],
        },
      );
      final dst = _InMemoryTreeProvider(
        providerId: 'dst_cloud',
        providerName: 'Dest Cloud',
        providerType: CloudProviderType.naver,
        tree: {'dest_parent': []},
      );

      final handler = RecursiveFolderHandler({'src_cloud': src, 'dst_cloud': dst});
      final tasks = await handler.planFolderTransfer(
        sourceAccountId: 'src_cloud',
        destAccountId: 'dst_cloud',
        sourceFolderIdOrPath: 'folder_root',
        sourceFolderName: 'AnimePack',
        destParentFolderIdOrPath: 'dest_parent',
        groupId: 'grp_anime',
      );

      expect(tasks.length, 3);
      expect(tasks.every((t) => t.groupName == 'AnimePack'), isTrue);
      expect(
        tasks.map((t) => t.relativePath).toSet(),
        {'readme.txt', 'Season 1/ep01.mp4', 'Season 1/Extras/opening.mp4'},
      );

      final progressMap = <String, TaskProgressInfo>{
        tasks[0].id: const TaskProgressInfo(
          transferredBytes: 1000,
          totalBytes: 1000,
          speedBytesPerSec: 0,
          status: TransferStatus.completed,
        ),
        tasks[1].id: const TaskProgressInfo(
          transferredBytes: 2000,
          totalBytes: 4000,
          speedBytesPerSec: 500,
          status: TransferStatus.active,
        ),
        tasks[2].id: const TaskProgressInfo(
          transferredBytes: 500,
          totalBytes: 2000,
          speedBytesPerSec: 300,
          status: TransferStatus.active,
        ),
      };

      final entries = TransferTreeBuilder.buildDashboardEntries(tasks, progressMap);
      expect(entries.length, 1);
      final groupEntry = entries.first as TransferGroupEntry;
      final summary = groupEntry.group;

      expect(summary.groupName, 'AnimePack');
      expect(summary.totalFiles, 3);
      expect(summary.completedFiles, 1);
      expect(summary.activeFiles, 2);
      expect(summary.transferredBytes, 3500);
      expect(summary.totalBytes, 7000);
      expect(summary.progress, 0.5);
      expect(summary.speedBytesPerSec, 800.0);
      expect(summary.aggregateStatus, TransferStatus.active);

      final seasonNode = summary.rootNode.subfolders.single;
      expect(seasonNode.name, 'Season 1');
      expect(seasonNode.totalBytes, 6000);
      expect(seasonNode.transferredBytes, 2500);
      expect(seasonNode.speedBytesPerSec, 800.0);
      expect(seasonNode.subfolders.single.name, 'Extras');
    });

    testWidgets('TransferDashboardScreen renders folder summary and expands into tree view',
        (tester) async {
      final db = AppDatabase.instance;
      final now = DateTime.now();
      await tester.runAsync(() async {
        await db.cancelIncompleteTasks();
        await TransferQueueManager.instance.clearCompleted();
        await db.insertTasksBatch([
          TransferTask(
            id: 'tree_t1',
            groupId: 'grp_tree_ui',
            groupName: 'BackupFolder',
            relativePath: 'docs/report.pdf',
            providerType: 'gdrive',
            sourceAccountId: 'g1',
            destAccountId: 'local',
            taskType: TransferTaskType.download,
            fileName: 'report.pdf',
            sourcePath: 's1',
            destinationPath: 'D:/Downloads/BackupFolder/docs',
            totalBytes: 2048,
            transferredBytes: 1024,
            status: TransferStatus.active,
            createdAt: now,
            updatedAt: now,
          ),
          TransferTask(
            id: 'tree_t2',
            groupId: 'grp_tree_ui',
            groupName: 'BackupFolder',
            relativePath: 'photo.png',
            providerType: 'gdrive',
            sourceAccountId: 'g1',
            destAccountId: 'local',
            taskType: TransferTaskType.download,
            fileName: 'photo.png',
            sourcePath: 's2',
            destinationPath: 'D:/Downloads/BackupFolder',
            totalBytes: 1024,
            transferredBytes: 1024,
            status: TransferStatus.completed,
            createdAt: now,
            updatedAt: now,
          ),
        ]);
      });

      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(
            home: TransferDashboardScreen(),
          ),
        ),
      );
      await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 100)));
      await tester.pumpAndSettle();

      // Collapsed header shows overall folder summary
      expect(find.text('BackupFolder'), findsOneWidget);
      expect(find.textContaining('파일 1/2 완료'), findsOneWidget);
      // Child files are hidden until expanded
      expect(find.text('report.pdf'), findsNothing);

      // Expand the folder group
      await tester.tap(find.text('BackupFolder'));
      await tester.pumpAndSettle();

      // Tree shows subfolder and files
      expect(find.text('docs'), findsOneWidget);
      expect(find.text('report.pdf'), findsOneWidget);
      expect(find.text('photo.png'), findsOneWidget);

      await tester.runAsync(() async {
        await db.deleteGroupTasks('grp_tree_ui');
      });
    });
  });

  group('Dual-pane Air Explorer UI', () {
    testWidgets('shows unified single tree per pane, supports swap preserving folder, and shows direction arrows',
        (tester) async {
      final baiduAcc = CloudAccount(
        id: 'baidu_test',
        name: 'Baidu Cloud',
        type: CloudProviderType.baidu,
        email: 'user@example.com',
        accessToken: 'tok',
      );
      final localAcc = CloudAccount(
        id: 'local_test',
        name: '내 저장소',
        type: CloudProviderType.local,
        email: '',
        accessToken: '',
      );

      final srcProvider = _InMemoryTreeProvider(
        providerId: 'baidu_test',
        providerName: 'Baidu Cloud',
        providerType: CloudProviderType.baidu,
        tree: {
          'root': [
            const CloudItem(
              id: 'src_folder_1',
              name: 'Projects',
              isFolder: true,
              providerType: CloudProviderType.baidu,
              accountId: 'baidu_test',
            ),
            const CloudItem(
              id: 'src_file_1',
              name: 'notes.txt',
              isFolder: false,
              size: 512,
              providerType: CloudProviderType.baidu,
              accountId: 'baidu_test',
            ),
          ],
          'src_folder_1': [
            const CloudItem(
              id: 'src_sub_1',
              name: 'SubProject',
              isFolder: true,
              providerType: CloudProviderType.baidu,
              accountId: 'baidu_test',
            ),
          ],
        },
      );

      final dstProvider = _InMemoryTreeProvider(
        providerId: 'local_test',
        providerName: '내 저장소',
        providerType: CloudProviderType.local,
        tree: {
          'root': [
            const CloudItem(
              id: 'dst_target_dir',
              name: 'TargetInbox',
              isFolder: true,
              providerType: CloudProviderType.local,
              accountId: 'local_test',
            ),
          ],
          'dst_target_dir': [],
        },
      );

      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            accountsProvider.overrideWith(
              (ref) => _TestAccountsNotifier(
                initialAccounts: [baiduAcc, localAcc],
                fakeProviders: {
                  'baidu_test': srcProvider,
                  'local_test': dstProvider,
                },
              ),
            ),
          ],
          child: const MaterialApp(
            home: MainShellScreen(),
          ),
        ),
      );

      await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 100)));
      await tester.pumpAndSettle();

      // Both panes visible side-by-side with NO duplicate split '폴더 트리' header
      expect(find.text('좌측(원본)'), findsOneWidget);
      expect(find.text('우측(대상)'), findsOneWidget);
      expect(find.text('폴더 트리'), findsNothing);
      expect(find.text('Projects'), findsOneWidget);
      expect(find.text('TargetInbox'), findsOneWidget);

      // Center strip shows Download (Baidu -> Local), Swap, and Upload (Local -> Baidu)
      expect(find.text('다운로드'), findsOneWidget);
      expect(find.text('업로드'), findsOneWidget);
      expect(find.text('창 스왑'), findsOneWidget);
      expect(find.byIcon(Icons.arrow_forward_rounded), findsOneWidget);
      expect(find.byIcon(Icons.arrow_back_rounded), findsOneWidget);

      // Expand 'Projects' inline in the single unified tree and verify 'SubProject' appears
      final arrowButtons = find.byIcon(Icons.keyboard_arrow_right);
      expect(arrowButtons, findsAtLeastNWidgets(1));
      await tester.tap(arrowButtons.first);
      await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 50)));
      await tester.pumpAndSettle();
      expect(find.text('SubProject'), findsOneWidget);

      // Navigate into 'TargetInbox' in the right pane so destination becomes 'dst_target_dir'
      await tester.tap(find.text('TargetInbox').first);
      await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 50)));
      await tester.pumpAndSettle();

      // Select 'notes.txt' in the left pane and verify opposite target label updates to TargetInbox
      await tester.tap(find.text('notes.txt'));
      await tester.pumpAndSettle();
      expect(find.text('내 저장소: TargetInbox'), findsOneWidget);

      // Swap left/right panes and verify current folder & selection are preserved on swapped sides
      await tester.tap(find.text('창 스왑'));
      await tester.pumpAndSettle();
      // After swap: Left is Local (at TargetInbox), Right is Baidu (with notes.txt still selected)
      expect(find.text('내 저장소: TargetInbox'), findsOneWidget);

      // Trigger transfer from Right (Baidu) -> Left (Local TargetInbox) and verify SnackBar auto-dismisses
      await tester.tap(find.text('다운로드'));
      for (int i = 0; i < 6; i++) {
        await tester.pump();
        await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 30)));
      }
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('1개 전송 작업이 큐에 추가되었습니다.'), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      expect(find.text('1개 전송 작업이 큐에 추가되었습니다.'), findsNothing);

      await tester.runAsync(() async {
        await TransferQueueManager.instance.cancelAll();
      });
    });
  });
}
