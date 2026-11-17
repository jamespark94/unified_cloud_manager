import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:http/http.dart' as http;
import '../cloud_credentials.dart';
import '../cloud_item.dart';
import '../cloud_storage_provider.dart';

class GoogleDriveProvider implements CloudStorageProvider {
  final CloudAccount account;
  final Future<void> Function(CloudAccount)? onAccountUpdated;
  final Dio _dio = Dio();

  GoogleDriveProvider({required this.account, this.onAccountUpdated});

  @override
  String get providerId => account.id;

  @override
  String get providerName => account.name;

  @override
  CloudProviderType get providerType => CloudProviderType.googleDrive;

  Map<String, String> get _authHeaders => {
        'Authorization': 'Bearer ${account.accessToken}',
      };

  @override
  Future<List<CloudItem>> listItems({required String folderIdOrPath}) async {
    // Skeleton fallback if token is empty
    if (account.accessToken.isEmpty) {
      return _getSkeletonItems(folderIdOrPath);
    }

    final parent = (folderIdOrPath.isEmpty || folderIdOrPath == 'root') ? 'root' : folderIdOrPath;
    final query = Uri.encodeComponent("'$parent' in parents and trashed = false");
    final url =
        'https://www.googleapis.com/drive/v3/files?q=$query&fields=files(id,name,mimeType,size,modifiedTime)&orderBy=folder,name&pageSize=1000';

    final res = await http.get(Uri.parse(url), headers: _authHeaders);
    if (res.statusCode != 200) {
      throw Exception('Google Drive 목록 조회 실패 (${res.statusCode}): ${res.body}');
    }

    final data = jsonDecode(utf8.decode(res.bodyBytes));
    final files = (data['files'] as List<dynamic>? ?? []);

    return files.map((f) {
      final mime = f['mimeType'] as String? ?? '';
      final isFolder = mime == 'application/vnd.google-apps.folder';
      final size = f['size'] != null ? int.tryParse(f['size'].toString()) : null;

      return CloudItem(
        id: f['id'] as String,
        name: f['name'] as String,
        parentId: parent,
        isFolder: isFolder,
        size: size,
        mimeType: mime,
        modifiedTime: f['modifiedTime'] != null ? DateTime.tryParse(f['modifiedTime'] as String) : null,
        providerType: CloudProviderType.googleDrive,
        accountId: account.id,
      );
    }).toList();
  }

  @override
  Future<CloudItem> createFolder({required String parentId, required String folderName}) async {
    if (account.accessToken.isEmpty) {
      return CloudItem(
        id: 'mock_gdrive_folder_${DateTime.now().millisecondsSinceEpoch}',
        name: folderName,
        parentId: parentId,
        isFolder: true,
        providerType: CloudProviderType.googleDrive,
        accountId: account.id,
      );
    }

    final parent = (parentId.isEmpty || parentId == 'root') ? 'root' : parentId;
    const url = 'https://www.googleapis.com/drive/v3/files';
    final res = await http.post(
      Uri.parse(url),
      headers: {..._authHeaders, 'Content-Type': 'application/json'},
      body: jsonEncode({
        'name': folderName,
        'mimeType': 'application/vnd.google-apps.folder',
        'parents': [parent],
      }),
    );

    if (res.statusCode != 200) {
      throw Exception('Google Drive 폴더 생성 실패 (${res.statusCode}): ${res.body}');
    }

    final data = jsonDecode(res.body);
    return CloudItem(
      id: data['id'] as String,
      name: folderName,
      parentId: parent,
      isFolder: true,
      providerType: CloudProviderType.googleDrive,
      accountId: account.id,
    );
  }

  @override
  Future<void> deleteItem({required String idOrPath, required bool isFolder}) async {
    if (account.accessToken.isEmpty) return;
    final url = 'https://www.googleapis.com/drive/v3/files/$idOrPath';
    final res = await http.delete(Uri.parse(url), headers: _authHeaders);
    if (res.statusCode != 204 && res.statusCode != 200) {
      throw Exception('Google Drive 삭제 실패 (${res.statusCode}): ${res.body}');
    }
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
      return Stream.fromIterable([utf8.encode('Mock Google Drive File Content')]);
    }

    final url = 'https://www.googleapis.com/drive/v3/files/$fileId?alt=media';
    final headers = Map<String, String>.from(_authHeaders);
    if (startByte != null || endByte != null) {
      headers['Range'] = 'bytes=${startByte ?? 0}-${endByte ?? ''}';
    }

    final response = await _dio.get<ResponseBody>(
      url,
      cancelToken: cancelToken,
      options: Options(
        headers: headers,
        responseType: ResponseType.stream,
      ),
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
    if (account.accessToken.isEmpty) {
      // Mock upload
      int sent = 0;
      await for (final chunk in stream) {
        sent += chunk.length;
        onProgress?.call(sent, length);
      }
      return;
    }

    final parent = (parentId.isEmpty || parentId == 'root') ? 'root' : parentId;
    // 1. Resumable Upload Session 초기화
    final initUrl = 'https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable';
    final initRes = await http.post(
      Uri.parse(initUrl),
      headers: {
        ..._authHeaders,
        'Content-Type': 'application/json; charset=UTF-8',
        'X-Upload-Content-Type': 'application/octet-stream',
        'X-Upload-Content-Length': length.toString(),
      },
      body: jsonEncode({
        'name': fileName,
        'parents': [parent],
      }),
    );

    if (initRes.statusCode != 200) {
      throw Exception('Google Drive Resumable 세션 생성 실패 (${initRes.statusCode})');
    }

    final uploadLocation = initRes.headers['location'];
    if (uploadLocation == null) {
      throw Exception('업로드 위치 URL을 수신하지 못했습니다.');
    }

    // 2. 스트림 전송
    await _dio.put(
      uploadLocation,
      data: stream,
      options: Options(
        headers: {
          'Content-Length': length.toString(),
          'Content-Type': 'application/octet-stream',
        },
      ),
      onSendProgress: onProgress,
    );
  }

  List<CloudItem> _getSkeletonItems(String folderId) {
    return [
      CloudItem(
        id: 'skeleton_gdrive_f1',
        name: '📁 Documents (Sample)',
        parentId: folderId,
        isFolder: true,
        providerType: CloudProviderType.googleDrive,
        accountId: account.id,
      ),
      CloudItem(
        id: 'skeleton_gdrive_file1',
        name: '📄 GDrive_Quick_Start.pdf',
        parentId: folderId,
        isFolder: false,
        size: 1024 * 1024 * 2, // 2MB
        modifiedTime: DateTime.now(),
        providerType: CloudProviderType.googleDrive,
        accountId: account.id,
      ),
    ];
  }
}
