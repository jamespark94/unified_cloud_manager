import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unified_cloud_manager/core/cloud/cloud_credentials.dart';
import 'package:unified_cloud_manager/core/cloud/cloud_item.dart';
import 'package:unified_cloud_manager/core/cloud/cloud_storage_provider.dart';
import 'package:unified_cloud_manager/core/cloud/providers/baidu_provider.dart';
import 'package:unified_cloud_manager/core/cloud/providers/local_storage_provider.dart';
import 'package:unified_cloud_manager/core/database/app_database.dart';
import 'package:unified_cloud_manager/core/database/transfer_task_entity.dart';
import 'package:unified_cloud_manager/core/transfer/transfer_queue_manager.dart';

class _FakeTruncatedSourceProvider implements CloudStorageProvider {
  @override
  String get providerId => 'fake_src';

  @override
  String get providerName => 'Fake Source';

  @override
  CloudProviderType get providerType => CloudProviderType.baidu;

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
    return Stream.value(Uint8List(1024));
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

class _FakeSinkProvider implements CloudStorageProvider {
  @override
  String get providerId => 'fake_dst';

  @override
  String get providerName => 'Fake Dest';

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

class _FakeSlowResumableSourceProvider implements CloudStorageProvider {
  final Uint8List fullData;
  final Duration chunkDelay;
  final bool supportRange;
  final List<int?> requestedStartBytes = [];
  bool cancelTokenWasTriggered = false;

  _FakeSlowResumableSourceProvider({
    required this.fullData,
    this.chunkDelay = const Duration(milliseconds: 25),
    this.supportRange = true,
  });

  @override
  String get providerId => 'fake_resumable_src';

  @override
  String get providerName => 'Fake Resumable Source';

  @override
  CloudProviderType get providerType => CloudProviderType.baidu;

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
    requestedStartBytes.add(startByte);
    final effectiveStart = (supportRange && startByte != null) ? startByte : 0;
    onActualStartByte?.call(effectiveStart);

    cancelToken?.whenCancel.then((_) {
      cancelTokenWasTriggered = true;
    });

    final controller = StreamController<List<int>>();
    () async {
      const chunkSize = 4096;
      var offset = effectiveStart;
      while (offset < fullData.length) {
        if (cancelToken?.isCancelled == true || controller.isClosed) {
          break;
        }
        final end = (offset + chunkSize > fullData.length) ? fullData.length : offset + chunkSize;
        controller.add(fullData.sublist(offset, end));
        offset = end;
        await Future.delayed(chunkDelay);
      }
      if (!controller.isClosed) {
        await controller.close();
      }
    }();
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

void main() {
  group('BaiduProvider stream validation & redirect handling', () {
    late HttpServer server;
    late BaiduProvider provider;

    setUpAll(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((HttpRequest req) async {
        if (req.uri.path == '/json-error') {
          req.response.statusCode = 200;
          req.response.headers.contentType = ContentType.json;
          req.response.write('{"errno":112,"errmsg":"param error"}');
          await req.response.close();
          return;
        }
        if (req.uri.path == '/plain-json-error') {
          req.response.statusCode = 200;
          req.response.headers.contentType = ContentType.text;
          req.response.write('{"error_code":31360,"error_msg":"expired"}');
          await req.response.close();
          return;
        }
        if (req.uri.path == '/redirect-dlink') {
          req.response.statusCode = 302;
          req.response.headers.set('Location', 'http://127.0.0.1:${server.port}/cdn-video');
          await req.response.close();
          return;
        }
        if (req.uri.path == '/cdn-video') {
          final ua = req.headers.value('user-agent') ?? '';
          final cookie = req.headers.value('cookie') ?? '';
          if (ua != BaiduProvider.pcsUserAgent ||
              !cookie.contains('BDUSS=my_bduss') ||
              !cookie.contains('PANWEB=1')) {
            req.response.statusCode = 403;
            await req.response.close();
            return;
          }
          req.response.statusCode = 200;
          req.response.headers.contentType = ContentType.binary;
          req.response.headers.set('Content-Disposition', 'attachment;filename="video.mp4"');
          final payload = List<int>.filled(16384, 0xAB);
          req.response.headers.contentLength = payload.length;
          req.response.add(payload);
          await req.response.close();
          return;
        }
        if (req.uri.path == '/range-file') {
          final payload = List<int>.generate(16384, (i) => i % 256);
          final range = req.headers.value('range');
          if (range != null && range.startsWith('bytes=')) {
            final start = int.parse(range.substring(6).split('-').first);
            final slice = payload.sublist(start);
            req.response.statusCode = 206;
            req.response.headers.contentType = ContentType.binary;
            req.response.headers.set('Content-Disposition', 'attachment;filename="range.bin"');
            req.response.headers.set('Content-Range', 'bytes $start-${payload.length - 1}/${payload.length}');
            req.response.headers.contentLength = slice.length;
            req.response.add(slice);
          } else {
            req.response.statusCode = 200;
            req.response.headers.contentType = ContentType.binary;
            req.response.headers.contentLength = payload.length;
            req.response.add(payload);
          }
          await req.response.close();
          return;
        }
        if (req.uri.path == '/stalled') {
          req.response.bufferOutput = false;
          req.response.statusCode = 200;
          req.response.headers.contentType = ContentType.binary;
          req.response.headers.set('Content-Disposition', 'attachment;filename="stalled.bin"');
          req.response.headers.contentLength = 1024 * 1024;
          req.response.add(List<int>.filled(1024, 0x55));
          await req.response.flush();
          // Intentionally keep connection open briefly until client cancels
          await Future.delayed(const Duration(seconds: 2));
          try {
            await req.response.close();
          } catch (_) {}
          return;
        }
        req.response.statusCode = 404;
        await req.response.close();
      });

      provider = BaiduProvider(
        account: CloudAccount(
          id: 'baidu_test',
          name: 'Baidu Test',
          type: CloudProviderType.baidu,
          email: '',
          accessToken: 'BDUSS=my_bduss; STOKEN=my_stoken',
        ),
      );
    });

    tearDownAll(() async {
      await server.close(force: true);
    });

    test('rejects application/json error response', () async {
      final stream = await provider.openValidatedStreamForTest(
        'http://127.0.0.1:${server.port}/json-error',
        BaiduProvider.pcsUserAgent,
      );
      expect(stream, isNull);
    });

    test('rejects small text/plain JSON error payload', () async {
      final stream = await provider.openValidatedStreamForTest(
        'http://127.0.0.1:${server.port}/plain-json-error',
        BaiduProvider.pcsUserAgent,
      );
      expect(stream, isNull);
    });

    test('follows 302 redirect preserving User-Agent and Cookie including PANWEB=1', () async {
      final stream = await provider.openValidatedStreamForTest(
        'http://127.0.0.1:${server.port}/redirect-dlink',
        BaiduProvider.pcsUserAgent,
      );
      expect(stream, isNotNull);
      final collected = await stream!.expand((e) => e).toList();
      expect(collected.length, 16384);
      expect(collected.first, 0xAB);
    });

    test('parses 206 Content-Range actualStartByte for resumed downloads', () async {
      int? reportedStart;
      final stream = await provider.openValidatedStreamForTest(
        'http://127.0.0.1:${server.port}/range-file',
        BaiduProvider.pcsUserAgent,
        startByte: 4096,
        onActualStartByte: (offset) => reportedStart = offset,
      );
      expect(stream, isNotNull);
      expect(reportedStart, 4096);
      final collected = await stream!.expand((e) => e).toList();
      expect(collected.length, 16384 - 4096);
      expect(collected.first, 4096 % 256);
    });

    test('aborts stalled HTTP download stream immediately via CancelToken', () async {
      final cancelToken = CancelToken();
      final stream = await provider.openValidatedStreamForTest(
        'http://127.0.0.1:${server.port}/stalled',
        BaiduProvider.pcsUserAgent,
        cancelToken: cancelToken,
      );
      expect(stream, isNotNull);

      final received = <int>[];
      final firstChunk = Completer<void>();
      final completer = Completer<void>();
      final sub = stream!.listen(
        (chunk) {
          received.addAll(chunk);
          if (!firstChunk.isCompleted) firstChunk.complete();
          if (!cancelToken.isCancelled) {
            cancelToken.cancel('User cancelled');
          }
        },
        onError: (e) {
          // Expected cancellation error
          if (!completer.isCompleted) completer.complete();
        },
        onDone: () {
          if (!completer.isCompleted) completer.complete();
        },
      );

      await firstChunk.future.timeout(
        const Duration(seconds: 1),
        onTimeout: () => throw TimeoutException('firstChunk timeout; received=${received.length}'),
      );
      await completer.future.timeout(
        const Duration(seconds: 1),
        onTimeout: () => throw TimeoutException('completer timeout; cancelled=${cancelToken.isCancelled}'),
      );
      await sub.cancel();
      expect(received.length, 1024);
    });
  });

  group('TransferQueueManager size integrity check', () {
    test('does not mark task completed when stream ends after 1KB for a 10MB file', () async {
      await AppDatabase.instance.initInMemoryForTest();
      final mgr = TransferQueueManager.instance;
      final src = _FakeTruncatedSourceProvider();
      final dst = _FakeSinkProvider();
      mgr.registerProvider(src);
      mgr.registerProvider(dst);

      final now = DateTime.now();
      final task = TransferTask(
        id: 'baidu_truncated_test',
        providerType: 'baidu',
        sourceAccountId: src.providerId,
        destAccountId: dst.providerId,
        taskType: TransferTaskType.download,
        fileName: 'big_video.mp4',
        sourcePath: '123|/big_video.mp4',
        destinationPath: '/tmp',
        totalBytes: 10 * 1024 * 1024,
        transferredBytes: 0,
        retryCount: 5, // fail immediately without waiting for backoff
        status: TransferStatus.pending,
        createdAt: now,
        updatedAt: now,
      );

      await mgr.enqueueTask(task);
      await Future.delayed(const Duration(milliseconds: 200));

      final tasks = await AppDatabase.instance.getAllTasks();
      final saved = tasks.firstWhere((t) => t.id == 'baidu_truncated_test');
      expect(saved.status, TransferStatus.failed);
      expect(saved.errorMessage, contains('불완전'));

      await mgr.clearCompleted();
      mgr.unregisterProvider(src.providerId);
      mgr.unregisterProvider(dst.providerId);
    });
  });

  group('TransferQueueManager local cancel & resume', () {
    test('cancelTask aborts active download immediately, releases local file handle, and cleans up .part', () async {
      await AppDatabase.instance.initInMemoryForTest();
      final tempDir = await Directory.systemTemp.createTemp('ucm_cancel_test_');
      final payload = Uint8List.fromList(List<int>.generate(128 * 1024, (i) => i % 251));
      final src = _FakeSlowResumableSourceProvider(
        fullData: payload,
        chunkDelay: const Duration(milliseconds: 40),
      );
      final local = LocalStorageProvider(providerId: 'local_cancel_test');
      final mgr = TransferQueueManager.instance;
      mgr.registerProvider(src);
      mgr.registerProvider(local);

      try {
        final now = DateTime.now();
        final task = TransferTask(
          id: 'cancel_local_task',
          providerType: 'baidu',
          sourceAccountId: src.providerId,
          destAccountId: local.providerId,
          taskType: TransferTaskType.download,
          fileName: 'movie.mp4',
          sourcePath: '123|/movie.mp4',
          destinationPath: tempDir.path,
          totalBytes: payload.length,
          transferredBytes: 0,
          status: TransferStatus.pending,
          createdAt: now,
          updatedAt: now,
        );

        await mgr.enqueueTask(task);
        await Future.delayed(const Duration(milliseconds: 140));

        final partFile = File('${tempDir.path}${Platform.pathSeparator}movie.mp4.part');
        expect(await partFile.exists(), isTrue);

        await mgr.cancelTask(task.id);

        expect(src.cancelTokenWasTriggered, isTrue);
        expect(await partFile.exists(), isFalse);
        expect(await File('${tempDir.path}${Platform.pathSeparator}movie.mp4').exists(), isFalse);
        final tasks = await AppDatabase.instance.getAllTasks();
        expect(tasks.where((t) => t.id == task.id), isEmpty);
        // Verify directory can be deleted without any open Windows file handles
        await tempDir.delete(recursive: true);
      } finally {
        mgr.unregisterProvider(src.providerId);
        mgr.unregisterProvider(local.providerId);
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      }
    });

    test('pausing, simulating restart (init), and resuming continues from saved .part bytes', () async {
      await AppDatabase.instance.initInMemoryForTest();
      final tempDir = await Directory.systemTemp.createTemp('ucm_resume_test_');
      final payload = Uint8List.fromList(List<int>.generate(64 * 1024, (i) => (i * 7 + 13) % 256));
      final src = _FakeSlowResumableSourceProvider(
        fullData: payload,
        chunkDelay: const Duration(milliseconds: 30),
        supportRange: true,
      );
      final local = LocalStorageProvider(providerId: 'local_resume_test');
      final mgr = TransferQueueManager.instance;
      mgr.registerProvider(src);
      mgr.registerProvider(local);

      try {
        final now = DateTime.now();
        final task = TransferTask(
          id: 'resume_local_task',
          providerType: 'baidu',
          sourceAccountId: src.providerId,
          destAccountId: local.providerId,
          taskType: TransferTaskType.download,
          fileName: 'archive.7z',
          sourcePath: '456|/archive.7z',
          destinationPath: tempDir.path,
          totalBytes: payload.length,
          transferredBytes: 0,
          status: TransferStatus.pending,
          createdAt: now,
          updatedAt: now,
        );

        await mgr.enqueueTask(task);
        await Future.delayed(const Duration(milliseconds: 120));
        await mgr.pauseTask(task.id);

        final partFile = File('${tempDir.path}${Platform.pathSeparator}archive.7z.part');
        expect(await partFile.exists(), isTrue);
        final pausedBytes = await partFile.length();
        expect(pausedBytes, greaterThan(0));
        expect(pausedBytes, lessThan(payload.length));

        final pausedTask = (await AppDatabase.instance.getTaskById(task.id))!;
        expect(pausedTask.status, TransferStatus.paused);
        expect(pausedTask.transferredBytes, pausedBytes);

        // Simulate app restart via init() and then resuming the paused task
        await mgr.init();
        await mgr.resumeTask(task.id);

        for (var i = 0; i < 40; i++) {
          final current = await AppDatabase.instance.getTaskById(task.id);
          if (current?.status == TransferStatus.completed) break;
          await Future.delayed(const Duration(milliseconds: 50));
        }

        final completedTask = (await AppDatabase.instance.getTaskById(task.id))!;
        expect(completedTask.status, TransferStatus.completed);
        expect(completedTask.transferredBytes, payload.length);

        // Second request must have used Range starting at pausedBytes (not null / 0)
        expect(src.requestedStartBytes.length, 2);
        expect(src.requestedStartBytes.first, isNull);
        expect(src.requestedStartBytes.last, pausedBytes);

        final finalFile = File('${tempDir.path}${Platform.pathSeparator}archive.7z');
        expect(await finalFile.exists(), isTrue);
        expect(await partFile.exists(), isFalse);
        expect(await finalFile.readAsBytes(), equals(payload));
      } finally {
        await mgr.clearCompleted();
        mgr.unregisterProvider(src.providerId);
        mgr.unregisterProvider(local.providerId);
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      }
    });

    test('falls back cleanly to offset 0 without corruption if server ignores Range (returns 200)', () async {
      await AppDatabase.instance.initInMemoryForTest();
      final tempDir = await Directory.systemTemp.createTemp('ucm_norange_test_');
      final payload = Uint8List.fromList(List<int>.generate(32 * 1024, (i) => (i * 3) % 256));
      final src = _FakeSlowResumableSourceProvider(
        fullData: payload,
        chunkDelay: const Duration(milliseconds: 25),
        supportRange: false,
      );
      final local = LocalStorageProvider(providerId: 'local_norange_test');
      final mgr = TransferQueueManager.instance;
      mgr.registerProvider(src);
      mgr.registerProvider(local);

      try {
        final now = DateTime.now();
        final task = TransferTask(
          id: 'norange_local_task',
          providerType: 'baidu',
          sourceAccountId: src.providerId,
          destAccountId: local.providerId,
          taskType: TransferTaskType.download,
          fileName: 'doc.bin',
          sourcePath: '789|/doc.bin',
          destinationPath: tempDir.path,
          totalBytes: payload.length,
          transferredBytes: 0,
          status: TransferStatus.pending,
          createdAt: now,
          updatedAt: now,
        );

        await mgr.enqueueTask(task);
        await Future.delayed(const Duration(milliseconds: 80));
        await mgr.pauseTask(task.id);
        await mgr.resumeTask(task.id);

        for (var i = 0; i < 40; i++) {
          final current = await AppDatabase.instance.getTaskById(task.id);
          if (current?.status == TransferStatus.completed) break;
          await Future.delayed(const Duration(milliseconds: 50));
        }

        final finalFile = File('${tempDir.path}${Platform.pathSeparator}doc.bin');
        expect(await finalFile.exists(), isTrue);
        expect(await finalFile.readAsBytes(), equals(payload));
      } finally {
        await mgr.clearCompleted();
        mgr.unregisterProvider(src.providerId);
        mgr.unregisterProvider(local.providerId);
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      }
    });
  });
}
