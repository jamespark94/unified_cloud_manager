import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../cloud_credentials.dart';
import '../cloud_item.dart';
import '../cloud_storage_provider.dart';

class BaiduProvider implements CloudStorageProvider {
  final CloudAccount account;
  final Future<void> Function(CloudAccount)? onAccountUpdated;
  final Dio _dio = Dio();

  static const String appId = '250528';
  static const String defaultUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';
  static const String pcsUserAgent = 'LogStatistic';

  BaiduProvider({required this.account, this.onAccountUpdated});

  @override
  String get providerId => account.id;

  @override
  String get providerName => account.name;

  @override
  CloudProviderType get providerType => CloudProviderType.baidu;

  String get _cookieHeader {
    final token = account.accessToken.trim();
    return token.contains('=') ? token : 'BDUSS=$token; PANWEB=1';
  }

  Map<String, String> get _headers => {
        'User-Agent': defaultUserAgent,
        'Cookie': _cookieHeader,
        'Referer': 'https://pan.baidu.com/',
      };

  @override
  Future<List<CloudItem>> listItems({required String folderIdOrPath}) async {
    if (account.accessToken.isEmpty) {
      return _getSkeletonItems(folderIdOrPath);
    }

    final dirPath = (folderIdOrPath.isEmpty || folderIdOrPath == 'root') ? '/' : folderIdOrPath;
    final uri = Uri.parse('https://pan.baidu.com/api/list').replace(
      queryParameters: {
        'app_id': appId,
        'web': '1',
        'channel': 'chunlei',
        'clienttype': '0',
        'dir': dirPath,
        'num': '1000',
        'page': '1',
        'order': 'name',
        'desc': '0',
      },
    );

    final res = await http.get(uri, headers: _headers);
    if (res.statusCode != 200) {
      throw Exception('Baidu 목록 조회 실패 (${res.statusCode}): ${res.body}');
    }

    final data = jsonDecode(res.body);
    if (data is! Map || data['errno'] != 0) {
      throw Exception('Baidu API 오류: ${data['errno']}');
    }

    final list = data['list'] as List<dynamic>? ?? [];
    return list.map((item) {
      final isDir = (item['isdir'] == 1 || item['isdir'] == '1');
      final path = item['path'] as String? ?? '';
      final fsId = item['fs_id']?.toString() ?? '';
      final name = item['server_filename'] as String? ?? (path.split('/').last);
      final size = item['size'] != null ? int.tryParse(item['size'].toString()) : null;

      final itemId = isDir ? path : '$fsId|$path';
      return CloudItem(
        id: itemId,
        name: name,
        parentId: dirPath,
        path: path,
        isFolder: isDir,
        size: size,
        providerType: CloudProviderType.baidu,
        accountId: account.id,
      );
    }).toList();
  }

  @override
  Future<CloudItem> createFolder({required String parentId, required String folderName}) async {
    if (account.accessToken.isEmpty) {
      return CloudItem(
        id: '$parentId/$folderName',
        name: folderName,
        parentId: parentId,
        isFolder: true,
        providerType: CloudProviderType.baidu,
        accountId: account.id,
      );
    }

    final parentPath = (parentId.isEmpty || parentId == 'root') ? '/' : parentId;
    final fullPath = parentPath.endsWith('/') ? '$parentPath$folderName' : '$parentPath/$folderName';

    final uri = Uri.parse('https://pan.baidu.com/api/create').replace(
      queryParameters: {
        'app_id': appId,
        'web': '1',
        'channel': 'chunlei',
        'clienttype': '0',
      },
    );

    final res = await http.post(
      uri,
      headers: {
        ..._headers,
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: {
        'path': fullPath,
        'isdir': '1',
        'size': '',
        'block_list': '[]',
      },
    );

    final data = jsonDecode(res.body);
    if (res.statusCode != 200 || (data is Map && data['errno'] != 0)) {
      throw Exception('Baidu 폴더 생성 실패: ${res.body}');
    }

    return CloudItem(
      id: fullPath,
      name: folderName,
      parentId: parentPath,
      path: fullPath,
      isFolder: true,
      providerType: CloudProviderType.baidu,
      accountId: account.id,
    );
  }

  @override
  Future<void> deleteItem({required String idOrPath, required bool isFolder}) async {
    if (account.accessToken.isEmpty) return;
    final path = idOrPath.contains('|') ? idOrPath.split('|').last : idOrPath;

    final uri = Uri.parse('https://pan.baidu.com/api/filemanager').replace(
      queryParameters: {
        'opera': 'delete',
        'app_id': appId,
        'web': '1',
        'channel': 'chunlei',
        'clienttype': '0',
      },
    );

    await http.post(
      uri,
      headers: {
        ..._headers,
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: {'filelist': jsonEncode([path])},
    );
  }

  @override
  Future<Stream<List<int>>> downloadStream({
    required String fileId,
    int? startByte,
    int? endByte,
  }) async {
    if (account.accessToken.isEmpty) {
      return Stream.fromIterable([utf8.encode('Mock Baidu Download Stream Content')]);
    }

    final filePath = fileId.contains('|') ? fileId.split('|').last : fileId;
    final fsId = fileId.contains('|') ? fileId.split('|').first : '';

    // 후보 URL 리스트 (PCS download -> pan.baidu.com download)
    final candidateUrls = <String>[];
    if (filePath.isNotEmpty) {
      candidateUrls.add(
        'https://d.pcs.baidu.com/rest/2.0/pcs/file?method=download&app_id=$appId&path=${Uri.encodeComponent(filePath)}',
      );
    }
    if (fsId.isNotEmpty) {
      candidateUrls.add(
        'https://pan.baidu.com/api/download?app_id=$appId&web=1&channel=chunlei&clienttype=0&fidlist=[$fsId]',
      );
    }

    final userAgents = [
      pcsUserAgent,
      defaultUserAgent,
      'netdisk;12.1.2;android;android-android;12;SM-A908N',
    ];

    for (final url in candidateUrls) {
      for (final ua in userAgents) {
        try {
          final headers = {
            'User-Agent': ua,
            'Cookie': _cookieHeader,
            'Referer': 'https://pan.baidu.com/',
            'Accept': '*/*',
          };
          if (startByte != null || endByte != null) {
            headers['Range'] = 'bytes=${startByte ?? 0}-${endByte ?? ''}';
          }

          final response = await _dio.get<ResponseBody>(
            url,
            options: Options(
              headers: headers,
              responseType: ResponseType.stream,
              followRedirects: true,
            ),
          );

          if (response.statusCode == 200 || response.statusCode == 206) {
            return response.data!.stream;
          }
        } catch (e) {
          debugPrint('[BaiduProvider] Stream try failed ($url, $ua): $e');
        }
      }
    }

    throw Exception('Baidu 파일 다운로드 스트림 연결 실패 (모든 엔드포인트 거부)');
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
        id: '/BaiduSharedFolder',
        name: '📁 Baidu Cloud Library',
        parentId: folderId,
        isFolder: true,
        providerType: CloudProviderType.baidu,
        accountId: account.id,
      ),
      CloudItem(
        id: '987654321|/Baidu_Archive.7z',
        name: '📦 Baidu_Archive_2026.7z',
        parentId: folderId,
        isFolder: false,
        size: 1024 * 1024 * 50, // 50MB
        modifiedTime: DateTime.now(),
        providerType: CloudProviderType.baidu,
        accountId: account.id,
      ),
    ];
  }
}
