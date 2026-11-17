import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:http/http.dart' as http;
import '../cloud_credentials.dart';
import '../cloud_item.dart';
import '../cloud_storage_provider.dart';

class TeraBoxProvider implements CloudStorageProvider {
  final CloudAccount account;
  final Future<void> Function(CloudAccount)? onAccountUpdated;
  final Dio _dio = Dio();

  static const String appId = '250528';
  static const String pcUserAgent =
      'terabox;1.37.0.7;PC;PC-Windows;10.0.22631;WindowsTeraBox';
  static const String defaultUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

  TeraBoxProvider({required this.account, this.onAccountUpdated});

  @override
  String get providerId => account.id;

  @override
  String get providerName => account.name;

  @override
  CloudProviderType get providerType => CloudProviderType.terabox;

  String get _cookieHeader => 'ndus=${account.accessToken.trim()}';

  Map<String, String> get _headers => {
        'User-Agent': pcUserAgent,
        'Cookie': _cookieHeader,
        'Referer': 'https://www.terabox.com/',
        'Accept': 'application/json, text/plain, */*',
      };

  /// RC4 기반 TeraBox sign 알고리즘 (sign3, sign1을 조합하여 Base64 인코딩)
  String _calcSign(String s1, String s2) {
    if (s1.isEmpty || s2.isEmpty) return '';
    final a = List<int>.filled(256, 0);
    final p = List<int>.filled(256, 0);
    final o = <int>[];
    final v = s1.length;

    for (int q = 0; q < 256; q++) {
      a[q] = s1.codeUnitAt(q % v);
      p[q] = q;
    }

    int u = 0;
    for (int q = 0; q < 256; q++) {
      u = (u + p[q] + a[q]) % 256;
      final t = p[q];
      p[q] = p[u];
      p[u] = t;
    }

    int i = 0;
    u = 0;
    for (int q = 0; q < s2.length; q++) {
      i = (i + 1) % 256;
      u = (u + p[i]) % 256;
      final t = p[i];
      p[i] = p[u];
      p[u] = t;
      final k = p[(p[i] + p[u]) % 256];
      o.add(s2.codeUnitAt(q) ^ k);
    }

    return base64Encode(o);
  }

  /// /api/home/info 호출하여 sign1, sign3 추출 후 sign 생성
  Future<String> _genSign() async {
    try {
      final uri = Uri.parse('https://www.terabox.com/api/home/info').replace(
        queryParameters: {
          'app_id': appId,
          'web': '1',
          'channel': 'dubox',
          'clienttype': '0',
          'jsToken': account.refreshToken ?? '',
        },
      );
      final res = await http.get(uri, headers: _headers);
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        if (data is Map && data['data'] != null) {
          final sign1 = data['data']['sign1']?.toString() ?? '';
          final sign3 = data['data']['sign3']?.toString() ?? '';
          if (sign1.isNotEmpty && sign3.isNotEmpty) {
            return _calcSign(sign3, sign1);
          }
        }
      }
    } catch (e) {
      // ignore
    }
    return '';
  }

  @override
  Future<List<CloudItem>> listItems({required String folderIdOrPath}) async {
    if (account.accessToken.isEmpty) {
      return _getSkeletonItems(folderIdOrPath);
    }

    final dirPath = (folderIdOrPath.isEmpty || folderIdOrPath == 'root') ? '/' : folderIdOrPath;
    final uri = Uri.parse('https://www.terabox.com/api/list').replace(
      queryParameters: {
        'app_id': appId,
        'web': '1',
        'channel': 'dubox',
        'clienttype': '0',
        'jsToken': account.refreshToken ?? '',
        'dir': dirPath,
        'num': '1000',
        'page': '1',
        'order': 'name',
        'desc': '0',
      },
    );

    final res = await http.get(uri, headers: _headers);
    if (res.statusCode != 200) {
      throw Exception('TeraBox 목록 조회 실패 (${res.statusCode}): ${res.body}');
    }

    final data = jsonDecode(res.body);
    if (data is! Map || data['errno'] != 0) {
      throw Exception('TeraBox API 오류: ${data['errno']}');
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
        providerType: CloudProviderType.terabox,
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
        providerType: CloudProviderType.terabox,
        accountId: account.id,
      );
    }

    final parentPath = (parentId.isEmpty || parentId == 'root') ? '/' : parentId;
    final fullPath = parentPath.endsWith('/') ? '$parentPath$folderName' : '$parentPath/$folderName';

    final uri = Uri.parse('https://www.terabox.com/api/create').replace(
      queryParameters: {
        'app_id': appId,
        'web': '1',
        'channel': 'dubox',
        'clienttype': '0',
        'jsToken': account.refreshToken ?? '',
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
      throw Exception('TeraBox 폴더 생성 실패: ${res.body}');
    }

    return CloudItem(
      id: fullPath,
      name: folderName,
      parentId: parentPath,
      path: fullPath,
      isFolder: true,
      providerType: CloudProviderType.terabox,
      accountId: account.id,
    );
  }

  @override
  Future<void> deleteItem({required String idOrPath, required bool isFolder}) async {
    if (account.accessToken.isEmpty) return;
    final path = idOrPath.contains('|') ? idOrPath.split('|').last : idOrPath;

    final uri = Uri.parse('https://www.terabox.com/api/filemanager').replace(
      queryParameters: {
        'opera': 'delete',
        'app_id': appId,
        'web': '1',
        'channel': 'dubox',
        'clienttype': '0',
        'jsToken': account.refreshToken ?? '',
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
    CancelToken? cancelToken,
    void Function(int actualStartByte)? onActualStartByte,
  }) async {
    if (account.accessToken.isEmpty) {
      onActualStartByte?.call(0);
      return Stream.fromIterable([utf8.encode('Mock TeraBox Download Stream Content')]);
    }

    final fsId = fileId.contains('|') ? fileId.split('|').first : fileId;
    final filePath = fileId.contains('|') ? fileId.split('|').last : '';

    String? directDownloadUrl;

    // 방법 1: /api/filemetas (dlna crack 방식)
    if (filePath.isNotEmpty) {
      try {
        final uri = Uri.parse('https://www.terabox.com/api/filemetas').replace(
          queryParameters: {
            'app_id': appId,
            'web': '1',
            'channel': 'dubox',
            'clienttype': '0',
            'jsToken': account.refreshToken ?? '',
            'target': jsonEncode([filePath]),
            'dlink': '1',
            'origin': 'dlna',
          },
        );
        final res = await http.get(uri, headers: _headers);
        if (res.statusCode == 200) {
          final data = jsonDecode(res.body);
          if (data is Map && data['info'] is List && (data['info'] as List).isNotEmpty) {
            final dlink = data['info'][0]['dlink']?.toString();
            if (dlink != null && dlink.startsWith('http')) {
              directDownloadUrl = dlink;
            }
          }
        }
      } catch (e) {
        // ignore & fallback to method 2
      }
    }

    // 방법 2: /api/download (official dlink 방식)
    if (directDownloadUrl == null && fsId.isNotEmpty) {
      try {
        final sign = await _genSign();
        final timestamp = (DateTime.now().millisecondsSinceEpoch ~/ 1000).toString();
        final queryParams = <String, String>{
          'app_id': appId,
          'web': '1',
          'channel': 'dubox',
          'clienttype': '0',
          'jsToken': account.refreshToken ?? '',
          'type': 'dlink',
          'fidlist': '[$fsId]',
          'vip': '2',
          'timestamp': timestamp,
        };
        if (sign.isNotEmpty) {
          queryParams['sign'] = sign;
        }

        final uri = Uri.parse('https://www.terabox.com/api/download').replace(
          queryParameters: queryParams,
        );
        final res = await http.get(uri, headers: _headers);
        if (res.statusCode == 200) {
          final data = jsonDecode(res.body);
          if (data is Map && data['dlink'] is List && (data['dlink'] as List).isNotEmpty) {
            final dlink = data['dlink'][0]['dlink']?.toString();
            if (dlink != null && dlink.startsWith('http')) {
              directDownloadUrl = dlink;
            }
          }
        }
      } catch (e) {
        // ignore & fallback to PCS
      }
    }

    // 후보 URL 리스트 구성 (추출된 dlink 우선, 없을 시 PCS direct 주소)
    final candidateUrls = <String>[];
    if (directDownloadUrl != null) {
      candidateUrls.add(directDownloadUrl);
    }
    if (filePath.isNotEmpty) {
      candidateUrls.add('https://d.terabox.com/rest/2.0/pcs/file?method=download&app_id=$appId&path=${Uri.encodeComponent(filePath)}');
      candidateUrls.add('https://c-all.terabox.com/rest/2.0/pcs/file?method=download&app_id=$appId&path=${Uri.encodeComponent(filePath)}');
    }

    final userAgents = [
      pcUserAgent,
      'LogStatistic',
      defaultUserAgent,
      'netdisk;12.1.2;android;android-android;12;SM-A908N',
    ];

    for (final url in candidateUrls) {
      for (final ua in userAgents) {
        try {
          final headers = {
            'User-Agent': ua,
            'Cookie': _cookieHeader,
            'Referer': 'https://www.terabox.com/',
            'Accept': '*/*',
          };
          if (startByte != null || endByte != null) {
            headers['Range'] = 'bytes=${startByte ?? 0}-${endByte ?? ''}';
          }

          final response = await _dio.get<ResponseBody>(
            url,
            cancelToken: cancelToken,
            options: Options(
              headers: headers,
              responseType: ResponseType.stream,
              followRedirects: true,
              validateStatus: (status) => status != null && status >= 200 && status < 400,
            ),
          );

          if (response.statusCode == 200 || response.statusCode == 206) {
            // Content-Type 확인: json 응답(에러)이 아닐 때만 유효한 파일 바이너리로 판단
            final contentType = response.headers.value('content-type') ?? '';
            if (!contentType.contains('application/json')) {
              onActualStartByte?.call(
                resolveActualStartByte(
                  statusCode: response.statusCode ?? 200,
                  contentRangeHeader: response.headers.value('content-range'),
                  requestedStartByte: startByte,
                ),
              );
              return response.data!.stream;
            }
          }
        } on DioException catch (e) {
          if (e.type == DioExceptionType.cancel) rethrow;
        } catch (e) {
          // try next
        }
      }
    }

    throw Exception('TeraBox 파일 다운로드 스트림 연결 실패 (dlink 추출 불가 또는 거부됨)');
  }

  @override
  Future<void> uploadStream({
    required String parentId,
    required String fileName,
    required Stream<List<int>> stream,
    required int length,
    Function(int bytesSent, int totalBytes)? onProgress,
  }) async {
    // TeraBox chunked upload skeleton
    int sent = 0;
    await for (final chunk in stream) {
      sent += chunk.length;
      onProgress?.call(sent, length);
    }
  }

  List<CloudItem> _getSkeletonItems(String folderId) {
    return [
      CloudItem(
        id: '/SampleFolder',
        name: '📁 TeraBox Media Folder',
        parentId: folderId,
        isFolder: true,
        providerType: CloudProviderType.terabox,
        accountId: account.id,
      ),
      CloudItem(
        id: '123456789|/SampleVideo.mp4',
        name: '🎬 Sample_1080p_Video.mp4',
        parentId: folderId,
        isFolder: false,
        size: 1024 * 1024 * 15, // 15MB
        modifiedTime: DateTime.now(),
        providerType: CloudProviderType.terabox,
        accountId: account.id,
      ),
    ];
  }
}
