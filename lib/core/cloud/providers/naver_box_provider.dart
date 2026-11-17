import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import '../cloud_credentials.dart';
import '../cloud_item.dart';
import '../cloud_storage_provider.dart';

class NaverBoxProvider implements CloudStorageProvider {
  final CloudAccount account;
  final Future<void> Function(CloudAccount)? onAccountUpdated;
  final Dio _dio = Dio();

  static const String defaultUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36';

  NaverBoxProvider({required this.account, this.onAccountUpdated}) {
    _dio.options.baseUrl = 'https://open-api.mybox.naver.com';
    _dio.options.headers = {
      'User-Agent': defaultUserAgent,
      'Authorization': 'Bearer ${account.accessToken.trim()}',
      'Accept': 'application/json',
    };
  }

  @override
  String get providerId => account.id;

  @override
  String get providerName => account.name;

  @override
  CloudProviderType get providerType => CloudProviderType.naver;

  @override
  Future<List<CloudItem>> listItems({required String folderIdOrPath}) async {
    if (account.accessToken.isEmpty) {
      return _getSkeletonItems(folderIdOrPath);
    }

    final isRoot = folderIdOrPath.isEmpty || folderIdOrPath == 'root';
    final path = isRoot ? '/v1/drive/resources' : '/v1/drive/folders/$folderIdOrPath/resources';

    final res = await _dio.get(path, queryParameters: {'count': 1000, 'sort': 'name,asc'});
    final data = res.data;
    final List<dynamic> rawList = (data is Map && data['resources'] != null)
        ? (data['resources'] as List<dynamic>)
        : [];

    return rawList.map((item) {
      final isDir = (item['type'] ?? '').toString().toLowerCase() == 'folder';
      final id = (item['resourceId'] ?? item['id'] ?? '').toString();
      final name = (item['name'] ?? '').toString();
      final size = (item['size'] ?? 0) as int;
      final modifiedAt = item['modifiedAt'] != null ? DateTime.tryParse(item['modifiedAt'].toString()) : null;

      return CloudItem(
        id: id,
        name: name,
        parentId: folderIdOrPath,
        isFolder: isDir,
        size: isDir ? null : size,
        modifiedTime: modifiedAt,
        providerType: CloudProviderType.naver,
        accountId: account.id,
      );
    }).toList();
  }

  @override
  Future<CloudItem> createFolder({required String parentId, required String folderName}) async {
    if (account.accessToken.isEmpty) {
      return CloudItem(
        id: 'mock_naver_folder_${DateTime.now().millisecondsSinceEpoch}',
        name: folderName,
        parentId: parentId,
        isFolder: true,
        providerType: CloudProviderType.naver,
        accountId: account.id,
      );
    }

    final isRoot = parentId.isEmpty || parentId == 'root';
    final path = isRoot ? '/v1/drive/folders' : '/v1/drive/folders/$parentId/folders';

    final res = await _dio.post(path, data: {'name': folderName});
    final data = res.data;
    return CloudItem(
      id: (data['resourceId'] ?? data['id'] ?? '').toString(),
      name: folderName,
      parentId: parentId,
      isFolder: true,
      providerType: CloudProviderType.naver,
      accountId: account.id,
    );
  }

  @override
  Future<void> deleteItem({required String idOrPath, required bool isFolder}) async {
    if (account.accessToken.isEmpty) return;
    await _dio.delete('/v1/drive/resources/$idOrPath');
  }

  @override
  Future<Stream<List<int>>> downloadStream({
    required String fileId,
    int? startByte,
    int? endByte,
    CancelToken? cancelToken,
    void Function(int actualStartByte)? onActualStartByte,
  }) async {
    if (account.accessToken.isEmpty) {
      onActualStartByte?.call(0);
      return Stream.fromIterable([utf8.encode('Mock Naver MYBOX File Content')]);
    }

    final downloadUrlRes = await _dio.get(
      '/v1/drive/files/$fileId/download',
      cancelToken: cancelToken,
    );
    final directUrl = downloadUrlRes.data['downloadUrl'] as String;

    final headers = <String, dynamic>{};
    if (startByte != null || endByte != null) {
      headers['Range'] = 'bytes=${startByte ?? 0}-${endByte ?? ''}';
    }

    final response = await Dio().get<ResponseBody>(
      directUrl,
      cancelToken: cancelToken,
      options: Options(headers: headers, responseType: ResponseType.stream),
    );
    onActualStartByte?.call(
      resolveActualStartByte(
        statusCode: response.statusCode ?? 200,
        contentRangeHeader: response.headers.value('content-range'),
        requestedStartByte: startByte,
      ),
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
        id: 'naver_folder_1',
        name: '📁 내 사진 및 문서',
        parentId: folderId,
        isFolder: true,
        providerType: CloudProviderType.naver,
        accountId: account.id,
      ),
      CloudItem(
        id: 'naver_file_1',
        name: '📄 네이버_백업_노트.txt',
        parentId: folderId,
        isFolder: false,
        size: 1024 * 32, // 32KB
        modifiedTime: DateTime.now(),
        providerType: CloudProviderType.naver,
        accountId: account.id,
      ),
    ];
  }
}
