import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import '../cloud_item.dart';
import '../cloud_storage_provider.dart';
import '../../utils/permission_utils.dart';

class LocalStorageProvider implements CloudStorageProvider {
  @override
  final String providerId;

  LocalStorageProvider({this.providerId = 'local'});

  @override
  String get providerName => '내 기기 (로컬 저장소)';

  @override
  CloudProviderType get providerType => CloudProviderType.local;

  @override
  Future<List<CloudItem>> listItems({required String folderIdOrPath}) async {
    if (Platform.isAndroid) {
      await PermissionUtils.ensureStoragePermission();
    }

    if (folderIdOrPath.isEmpty || folderIdOrPath == 'root') {
      return await _getRootSources();
    }

    final targetDir = Directory(folderIdOrPath);
    if (!await targetDir.exists()) return [];

    final List<CloudItem> folders = [];
    final List<CloudItem> files = [];

    try {
      final entities = targetDir.listSync(followLinks: false);
      for (final entity in entities) {
        final name = _getBasename(entity.path);
        if (name.startsWith('.') || name.startsWith('\$')) continue;

        final isDir = entity is Directory;
        int? size;
        DateTime? modified;
        try {
          final stat = entity.statSync();
          if (!isDir) size = stat.size;
          modified = stat.modified;
        } catch (_) {}

        final item = CloudItem(
          id: entity.path,
          name: name,
          parentId: folderIdOrPath,
          path: entity.path,
          isFolder: isDir,
          size: size,
          modifiedTime: modified,
          providerType: CloudProviderType.local,
          accountId: providerId,
        );

        if (isDir) {
          folders.add(item);
        } else {
          files.add(item);
        }
      }
    } catch (e) {
      debugPrint('[LocalStorageProvider] listItems error: $e');
    }

    folders.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    files.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return [...folders, ...files];
  }

  Future<List<CloudItem>> _getRootSources() async {
    final List<CloudItem> items = [];

    if (Platform.isWindows) {
      final userProfile = Platform.environment['USERPROFILE'];
      if (userProfile != null && userProfile.isNotEmpty) {
        final quickFolders = [
          {'name': '📁 다운로드', 'path': '$userProfile\\Downloads'},
          {'name': '📁 문서', 'path': '$userProfile\\Documents'},
          {'name': '📁 바탕 화면', 'path': '$userProfile\\Desktop'},
          {'name': '📁 동영상', 'path': '$userProfile\\Videos'},
        ];
        for (final q in quickFolders) {
          if (Directory(q['path']!).existsSync()) {
            items.add(CloudItem(
              id: q['path']!,
              name: q['name']!,
              path: q['path']!,
              isFolder: true,
              providerType: CloudProviderType.local,
              accountId: providerId,
            ));
          }
        }
      }

      for (final drive in ['C', 'D', 'E', 'F', 'G']) {
        final p = '$drive:\\';
        if (Directory(p).existsSync()) {
          items.add(CloudItem(
            id: p,
            name: '💾 로컬 디스크 ($drive:)',
            path: p,
            isFolder: true,
            providerType: CloudProviderType.local,
            accountId: providerId,
          ));
        }
      }
    } else if (Platform.isAndroid) {
      final androidPaths = [
        {'name': '📱 다운로드 (Download)', 'path': '/storage/emulated/0/Download'},
        {'name': '📱 동영상 (Movies)', 'path': '/storage/emulated/0/Movies'},
        {'name': '📱 카메라 (DCIM)', 'path': '/storage/emulated/0/DCIM'},
        {'name': '📱 내부 저장소 전체', 'path': '/storage/emulated/0'},
      ];
      for (final ap in androidPaths) {
        if (Directory(ap['path']!).existsSync()) {
          items.add(CloudItem(
            id: ap['path']!,
            name: ap['name']!,
            path: ap['path']!,
            isFolder: true,
            providerType: CloudProviderType.local,
            accountId: providerId,
          ));
        }
      }
    } else {
      final home = Platform.environment['HOME'] ?? '';
      if (home.isNotEmpty && Directory(home).existsSync()) {
        items.add(CloudItem(
          id: home,
          name: '📁 홈 폴더',
          path: home,
          isFolder: true,
          providerType: CloudProviderType.local,
          accountId: providerId,
        ));
      }
    }
    return items;
  }

  @override
  Future<CloudItem> createFolder({required String parentId, required String folderName}) async {
    final parent = (parentId.isEmpty || parentId == 'root')
        ? (await getApplicationDocumentsDirectory()).path
        : parentId;
    final newPath = '$parent${Platform.pathSeparator}$folderName';
    final dir = Directory(newPath);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return CloudItem(
      id: newPath,
      name: folderName,
      parentId: parent,
      path: newPath,
      isFolder: true,
      providerType: CloudProviderType.local,
      accountId: providerId,
    );
  }

  @override
  Future<void> deleteItem({required String idOrPath, required bool isFolder}) async {
    if (isFolder) {
      final d = Directory(idOrPath);
      if (await d.exists()) await d.delete(recursive: true);
    } else {
      final f = File(idOrPath);
      if (await f.exists()) await f.delete();
    }
  }

  @override
  Future<Stream<List<int>>> downloadStream({
    required String fileId,
    int? startByte,
    int? endByte,
  }) async {
    final file = File(fileId);
    if (!await file.exists()) {
      throw Exception('로컬 파일을 찾을 수 없습니다: $fileId');
    }
    return file.openRead(startByte, endByte);
  }

  @override
  Future<void> uploadStream({
    required String parentId,
    required String fileName,
    required Stream<List<int>> stream,
    required int length,
    Function(int bytesSent, int totalBytes)? onProgress,
  }) async {
    final parent = (parentId.isEmpty || parentId == 'root')
        ? (await getApplicationDocumentsDirectory()).path
        : parentId;
    final destFile = File('$parent${Platform.pathSeparator}$fileName');
    final sink = destFile.openWrite(mode: FileMode.writeOnly);

    int sent = 0;
    try {
      await for (final chunk in stream) {
        sink.add(chunk);
        sent += chunk.length;
        onProgress?.call(sent, length);
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
  }

  String _getBasename(String path) {
    var clean = path;
    if (clean.endsWith('\\') || clean.endsWith('/')) {
      clean = clean.substring(0, clean.length - 1);
    }
    final lastSep = clean.lastIndexOf(RegExp(r'[\\/]'));
    return lastSep == -1 ? clean : clean.substring(lastSep + 1);
  }
}
