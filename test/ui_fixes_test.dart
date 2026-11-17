import 'dart:async';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unified_cloud_manager/core/cloud/cloud_item.dart';
import 'package:unified_cloud_manager/core/cloud/cloud_storage_provider.dart';
import 'package:unified_cloud_manager/core/database/app_database.dart';
import 'package:unified_cloud_manager/core/database/transfer_task_entity.dart';
import 'package:unified_cloud_manager/core/transfer/transfer_queue_manager.dart';
import 'package:unified_cloud_manager/ui/screens/transfer_dashboard_screen.dart';
import 'package:unified_cloud_manager/ui/widgets/cloud_item_tile.dart';

class _StreamingTestSourceProvider implements CloudStorageProvider {
  final int totalBytes;
  final StreamController<List<int>> controller = StreamController<List<int>>();

  _StreamingTestSourceProvider({required this.totalBytes});

  @override
  String get providerId => 'terabox_stream_test';

  @override
  String get providerName => 'TeraBox Stream Test';

  @override
  CloudProviderType get providerType => CloudProviderType.terabox;

  @override
  Future<List<CloudItem>> listItems({required String folderIdOrPath}) async => [];

  @override
  Future<CloudItem> createFolder({required String parentId, required String folderName}) async =>
      throw UnimplementedError();

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
    return controller.stream;
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

class _CountingSinkProvider implements CloudStorageProvider {
  @override
  String get providerId => 'sink_stream_test';

  @override
  String get providerName => 'Sink Stream Test';

  @override
  CloudProviderType get providerType => CloudProviderType.local;

  @override
  Future<List<CloudItem>> listItems({required String folderIdOrPath}) async => [];

  @override
  Future<CloudItem> createFolder({required String parentId, required String folderName}) async =>
      throw UnimplementedError();

  @override
  Future<void> deleteItem({required String idOrPath, required bool isFolder}) async {}

  @override
  Future<Stream<List<int>>> downloadStream({
    required String fileId,
    int? startByte,
    int? endByte,
    CancelToken? cancelToken,
    void Function(int actualStartByte)? onActualStartByte,
  }) async =>
      throw UnimplementedError();

  @override
  Future<void> uploadStream({
    required String parentId,
    required String fileName,
    required Stream<List<int>> stream,
    required int length,
    Function(int bytesSent, int totalBytes)? onProgress,
  }) async {
    int sent = 0;
    await for (final chunk in stream) {
      sent += chunk.length;
      onProgress?.call(sent, length);
    }
  }
}

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

    testWidgets('TransferDashboardScreen updates live progress past 10% through completion across ProviderScope lifecycles',
        (tester) async {
      const total = 1000;
      final src = _StreamingTestSourceProvider(totalBytes: total);
      final dst = _CountingSinkProvider();
      final mgr = TransferQueueManager.instance;
      mgr.registerProvider(src);
      mgr.registerProvider(dst);

      try {
        final now = DateTime.now();
        final task = TransferTask(
          id: 'terabox_live_progress_task',
          providerType: 'terabox',
          sourceAccountId: src.providerId,
          destAccountId: dst.providerId,
          taskType: TransferTaskType.download,
          fileName: 'terabox_video.mp4',
          sourcePath: '101|/terabox_video.mp4',
          destinationPath: '/tmp',
          totalBytes: total,
          transferredBytes: 0,
          status: TransferStatus.pending,
          createdAt: now,
          updatedAt: now,
        );

        await tester.runAsync(() async {
          await mgr.enqueueTask(task);
          // Deliver initial 10% (100 bytes) before mounting dashboard
          src.controller.add(Uint8List(100));
          await Future.delayed(const Duration(milliseconds: 250));
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

        expect(find.text('terabox_video.mp4'), findsOneWidget);
        expect(find.textContaining('10.0%'), findsOneWidget);

        // Deliver next 40% (to 50%) after 220ms so UI throttle emits
        await tester.runAsync(() async {
          await Future.delayed(const Duration(milliseconds: 220));
          src.controller.add(Uint8List(400));
          await Future.delayed(const Duration(milliseconds: 50));
        });
        await tester.pump();
        expect(find.textContaining('50.0%'), findsOneWidget);

        // Complete the transfer (remaining 500 bytes + close)
        await tester.runAsync(() async {
          await Future.delayed(const Duration(milliseconds: 220));
          src.controller.add(Uint8List(500));
          await src.controller.close();
          await Future.delayed(const Duration(milliseconds: 150));
        });
        await tester.pump();
        await tester.pumpAndSettle();

        expect(find.textContaining('100.0%'), findsOneWidget);
        expect(find.text('완료'), findsOneWidget);
      } finally {
        await tester.runAsync(() async {
          if (!src.controller.isClosed) await src.controller.close();
          await mgr.clearCompleted();
          mgr.unregisterProvider(src.providerId);
          mgr.unregisterProvider(dst.providerId);
        });
      }
    });
  });
}
