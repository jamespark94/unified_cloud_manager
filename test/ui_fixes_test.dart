import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unified_cloud_manager/core/cloud/cloud_item.dart';
import 'package:unified_cloud_manager/core/database/app_database.dart';
import 'package:unified_cloud_manager/core/database/transfer_task_entity.dart';
import 'package:unified_cloud_manager/core/transfer/transfer_queue_manager.dart';
import 'package:unified_cloud_manager/ui/screens/transfer_dashboard_screen.dart';
import 'package:unified_cloud_manager/ui/widgets/cloud_item_tile.dart';

void main() {
  setUpAll(() async {
    await AppDatabase.instance.initInMemoryForTest();
  });

  group('CloudItemTile more menu', () {
    testWidgets('clicking three dots opens action options instead of deleting', (tester) async {
      bool opened = false;
      bool transferred = false;
      bool selected = false;
      bool detailed = false;
      bool deleted = false;

      const folderItem = CloudItem(
        id: 'dir_1',
        name: 'Documents',
        isFolder: true,
        providerType: CloudProviderType.googleDrive,
        accountId: 'gdrive_1',
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CloudItemTile(
              item: folderItem,
              onTap: () {},
              onLongPress: () {},
              onOpen: () => opened = true,
              onTransfer: () => transferred = true,
              onSelect: () => selected = true,
              onDetails: () => detailed = true,
              onDelete: () => deleted = true,
            ),
          ),
        ),
      );

      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();

      expect(deleted, isFalse);
      expect(find.text('열기'), findsOneWidget);
      expect(find.text('전송하기 (다운로드/복사)'), findsOneWidget);
      expect(find.text('선택'), findsOneWidget);
      expect(find.text('상세 정보'), findsOneWidget);
      expect(find.text('삭제'), findsOneWidget);

      await tester.tap(find.text('전송하기 (다운로드/복사)'));
      await tester.pumpAndSettle();
      expect(transferred, isTrue);
      expect(deleted, isFalse);
      expect(opened, isFalse);
      expect(selected, isFalse);
      expect(detailed, isFalse);

      // Reopen menu and test delete option explicitly
      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      await tester.tap(find.text('삭제'));
      await tester.pumpAndSettle();
      expect(deleted, isTrue);
    });
  });

  group('TransferQueueManager & AppDatabase cancelAll', () {
    test('cancelAll removes pending, active, paused tasks while preserving completed tasks', () async {
      final db = AppDatabase.instance;
      final now = DateTime.now();
      await db.insertTasksBatch([
        TransferTask(
          id: 't_pending',
          providerType: 'gdrive',
          sourceAccountId: 'gdrive_1',
          destAccountId: 'local',
          taskType: TransferTaskType.download,
          fileName: 'movie.mp4',
          sourcePath: 'src_1',
          destinationPath: '/tmp',
          totalBytes: 1000,
          status: TransferStatus.pending,
          createdAt: now,
          updatedAt: now,
        ),
        TransferTask(
          id: 't_paused',
          providerType: 'gdrive',
          sourceAccountId: 'gdrive_1',
          destAccountId: 'local',
          taskType: TransferTaskType.download,
          fileName: 'archive.zip',
          sourcePath: 'src_2',
          destinationPath: '/tmp',
          totalBytes: 2000,
          status: TransferStatus.paused,
          createdAt: now,
          updatedAt: now,
        ),
        TransferTask(
          id: 't_done',
          providerType: 'gdrive',
          sourceAccountId: 'gdrive_1',
          destAccountId: 'local',
          taskType: TransferTaskType.download,
          fileName: 'done.txt',
          sourcePath: 'src_3',
          destinationPath: '/tmp',
          totalBytes: 500,
          transferredBytes: 500,
          status: TransferStatus.completed,
          createdAt: now,
          updatedAt: now,
        ),
      ]);

      await TransferQueueManager.instance.cancelAll();
      final remaining = await db.getAllTasks();
      expect(remaining.map((t) => t.id).toList(), ['t_done']);

      await TransferQueueManager.instance.clearCompleted();
    });
  });

  group('Android bottom navigation inset & cancel all UI', () {
    testWidgets('TransferDashboardScreen respects bottom system padding and supports cancel all', (tester) async {
      final db = AppDatabase.instance;
      final now = DateTime.now();
      await tester.runAsync(() async {
        await db.insertTasksBatch([
          TransferTask(
            id: 'ui_pending',
            providerType: 'gdrive',
            sourceAccountId: 'gdrive_1',
            destAccountId: 'local',
            taskType: TransferTaskType.download,
            fileName: 'movie.mp4',
            sourcePath: 'src_1',
            destinationPath: '/tmp',
            totalBytes: 1000,
            status: TransferStatus.pending,
            createdAt: now,
            updatedAt: now,
          ),
          TransferTask(
            id: 'ui_done',
            providerType: 'gdrive',
            sourceAccountId: 'gdrive_1',
            destAccountId: 'local',
            taskType: TransferTaskType.download,
            fileName: 'done.txt',
            sourcePath: 'src_2',
            destinationPath: '/tmp',
            totalBytes: 500,
            transferredBytes: 500,
            status: TransferStatus.completed,
            createdAt: now,
            updatedAt: now,
          ),
        ]);
      });

      await tester.pumpWidget(
        const ProviderScope(
          child: MediaQuery(
            data: MediaQueryData(
              size: Size(400, 800),
              padding: EdgeInsets.only(top: 24, bottom: 48),
            ),
            child: MaterialApp(
              home: TransferDashboardScreen(),
            ),
          ),
        ),
      );

      // Let sqflite FFI isolate complete initial fetch
      await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 100)));
      await tester.pumpAndSettle();

      // Verify bottom SafeArea keeps list above 48px Android nav bar inset
      final listFinder = find.byType(ListView);
      expect(listFinder, findsOneWidget);
      final listRect = tester.getRect(listFinder);
      expect(listRect.bottom, lessThanOrEqualTo(800 - 48));

      // Verify tasks and "전체 취소" button are rendered
      expect(find.text('movie.mp4'), findsOneWidget);
      expect(find.text('done.txt'), findsOneWidget);
      expect(find.text('전체 취소'), findsOneWidget);

      // Tap "전체 취소" and confirm in dialog
      await tester.tap(find.text('전체 취소'));
      await tester.pumpAndSettle();
      expect(find.text('전체 취소 확인'), findsOneWidget);

      await tester.tap(find.widgetWithText(ElevatedButton, '전체 취소'));
      for (int i = 0; i < 6; i++) {
        await tester.pump();
        await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 30)));
      }
      await tester.pumpAndSettle();

      expect(find.text('movie.mp4'), findsNothing);
      expect(find.text('done.txt'), findsOneWidget);

      await tester.runAsync(() => TransferQueueManager.instance.clearCompleted());
    });
  });
}
