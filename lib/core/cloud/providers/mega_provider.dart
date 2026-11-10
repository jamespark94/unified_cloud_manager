import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import '../cloud_credentials.dart';
import '../cloud_item.dart';
import '../cloud_storage_provider.dart';
import '../../utils/mega_crypto_utils.dart';

class MegaProvider implements CloudStorageProvider {
  final CloudAccount account;
  final Future<void> Function(CloudAccount)? onAccountUpdated;
  final Dio _dio = Dio();
  int _sequenceId = Random().nextInt(0x10000000);

  MegaProvider({required this.account, this.onAccountUpdated}) {
    _dio.options.baseUrl = 'https://g.api.mega.co.nz';
  }

  @override
  String get providerId => account.id;

  @override
  String get providerName => account.name;

  @override
  CloudProviderType get providerType => CloudProviderType.mega;

  Uint8List? get _masterKey {
    if (account.refreshToken == null || account.refreshToken!.isEmpty) return null;
    try {
      return MegaCryptoUtils.base64UrlDecode(account.refreshToken!);
    } catch (_) {
      return null;
    }
  }

  Future<dynamic> _postCommand(Map<String, dynamic> command) async {
    final query = <String, String>{
      'id': (_sequenceId++).toString(),
      if (account.accessToken.isNotEmpty) 'sid': account.accessToken,
    };
    final response = await _dio.post('/cs', queryParameters: query, data: [command]);
    if (response.data is List && (response.data as List).isNotEmpty) {
      final res = (response.data as List).first;
      if (res is int && res < 0) {
        throw Exception('MEGA API 요청 에러 (코드: $res)');
      }
      return res;
    }
    return response.data;
  }

  @override
  Future<List<CloudItem>> listItems({required String folderIdOrPath}) async {
    final mk = _masterKey;
    if (account.accessToken.isEmpty || mk == null) {
      return _getSkeletonItems(folderIdOrPath);
    }

    final res = await _postCommand({'a': 'f', 'c': 1, 'r': 1});
    if (res is! Map<String, dynamic> || res['f'] == null) {
      return [];
    }

    final rawList = res['f'] as List<dynamic>;
    String? rootHandle;
    for (final item in rawList) {
      if (item is Map<String, dynamic> && item['t'] == 2) {
        rootHandle = item['h']?.toString();
        break;
      }
    }

    final targetParent = (folderIdOrPath.isEmpty || folderIdOrPath == 'root') ? rootHandle : folderIdOrPath;
    final List<CloudItem> items = [];

    for (final item in rawList) {
      if (item is! Map<String, dynamic>) continue;
      final handle = (item['h'] ?? '').toString();
      final parentId = (item['p'] ?? '').toString();
      final t = (item['t'] ?? 0) as int;
      final size = (item['s'] ?? 0) as int;
      final ts = (item['ts'] ?? 0) as int;
      final modTime = ts > 0 ? DateTime.fromMillisecondsSinceEpoch(ts * 1000) : null;
      final kStr = (item['k'] ?? '').toString();
      final aStr = (item['a'] ?? '').toString();
      final bool isFolder = t == 1 || t >= 2;

      if (targetParent != null && parentId != targetParent) continue;

      String name = '';
      if (kStr.isNotEmpty) {
        final colonIdx = kStr.indexOf(':');
        final encKey = (colonIdx >= 0 && colonIdx < kStr.length - 1) ? kStr.substring(colonIdx + 1) : kStr;
        try {
          final fileKey = MegaCryptoUtils.decryptAndUnpackNodeKey(encKey, mk, isFolder: isFolder);
          if (aStr.isNotEmpty) {
            final attrs = MegaCryptoUtils.decryptNodeAttributes(aStr, fileKey.aesKey);
            if (attrs != null && attrs['n'] != null) {
              name = attrs['n'].toString();
            }
          }
        } catch (_) {}
      }

      if (name.isEmpty) {
        name = isFolder ? '폴더 ($handle)' : '파일 ($handle)';
      }

      items.add(CloudItem(
        id: handle,
        name: name,
        parentId: parentId,
        isFolder: isFolder,
        size: isFolder ? null : size,
        modifiedTime: modTime,
        providerType: CloudProviderType.mega,
        accountId: account.id,
      ));
    }

    return items;
  }

  @override
  Future<CloudItem> createFolder({required String parentId, required String folderName}) async {
    return CloudItem(
      id: 'mega_f_${DateTime.now().millisecondsSinceEpoch}',
      name: folderName,
      parentId: parentId,
      isFolder: true,
      providerType: CloudProviderType.mega,
      accountId: account.id,
    );
  }

  @override
  Future<void> deleteItem({required String idOrPath, required bool isFolder}) async {
    if (account.accessToken.isEmpty) return;
    await _postCommand({'a': 'd', 'n': idOrPath});
  }

  @override
  Future<Stream<List<int>>> downloadStream({
    required String fileId,
    int? startByte,
    int? endByte,
  }) async {
    if (account.accessToken.isEmpty) {
      return Stream.fromIterable([utf8.encode('Mock MEGA E2EE Download Stream Content')]);
    }

    final res = await _postCommand({'a': 'g', 'g': 1, 'n': fileId});
    final downloadUrl = res['g'] as String;

    final response = await Dio().get<ResponseBody>(
      downloadUrl,
      options: Options(responseType: ResponseType.stream),
    );
    return response.data!.stream;
  }

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

  List<CloudItem> _getSkeletonItems(String folderId) {
    return [
      CloudItem(
        id: 'mega_folder_1',
        name: '📁 MEGA Secure Cloud Drive',
        parentId: folderId,
        isFolder: true,
        providerType: CloudProviderType.mega,
        accountId: account.id,
      ),
      CloudItem(
        id: 'mega_file_1',
        name: '🔒 Encrypted_Document.zip',
        parentId: folderId,
        isFolder: false,
        size: 1024 * 1024 * 12, // 12MB
        modifiedTime: DateTime.now(),
        providerType: CloudProviderType.mega,
        accountId: account.id,
      ),
    ];
  }
}
