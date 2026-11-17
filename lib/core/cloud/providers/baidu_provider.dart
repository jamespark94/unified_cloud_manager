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
  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 20),
    ),
  );

  static const String appId = '250528';
  static const String defaultUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';
  static const String pcsUserAgent = 'LogStatistic';

  String? _cachedJsToken;
  DateTime? _jsTokenExpiry;

  BaiduProvider({required this.account, this.onAccountUpdated}) {
    if (account.refreshToken != null &&
        account.refreshToken!.isNotEmpty &&
        account.tokenExpiry != null &&
        DateTime.now().isBefore(account.tokenExpiry!)) {
      _cachedJsToken = account.refreshToken;
      _jsTokenExpiry = account.tokenExpiry;
    }
  }

  @override
  String get providerId => account.id;

  @override
  String get providerName => account.name;

  @override
  CloudProviderType get providerType => CloudProviderType.baidu;

  String get _cookieHeader {
    final token = account.accessToken.trim();
    var cookie = token.contains('=') ? token : 'BDUSS=$token';
    if (!cookie.contains('PANWEB=')) {
      cookie = 'PANWEB=1; $cookie';
    }
    return cookie;
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

  void _throwIfCancelled(CancelToken? cancelToken) {
    if (cancelToken != null && cancelToken.isCancelled) {
      throw DioException.requestCancelled(
        requestOptions: RequestOptions(path: 'baidu_download'),
        reason: cancelToken.cancelError ?? 'Cancelled',
      );
    }
  }

  Future<String?> _ensureJsToken({CancelToken? cancelToken}) async {
    _throwIfCancelled(cancelToken);
    if (_cachedJsToken != null &&
        _jsTokenExpiry != null &&
        DateTime.now().isBefore(_jsTokenExpiry!)) {
      return _cachedJsToken;
    }

    const urls = [
      'https://pan.baidu.com/disk/main',
      'https://pan.baidu.com/disk/home',
    ];

    for (final url in urls) {
      _throwIfCancelled(cancelToken);
      try {
        final res = await _dio.get<String>(
          url,
          cancelToken: cancelToken,
          options: Options(
            headers: {
              'User-Agent': defaultUserAgent,
              'Cookie': _cookieHeader,
              'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
              'Referer': 'https://pan.baidu.com/',
            },
            responseType: ResponseType.plain,
            receiveTimeout: const Duration(seconds: 10),
            validateStatus: (_) => true,
          ),
        );

        if (res.statusCode == 200 && res.data != null) {
          final token = _parseJsTokenFromHtml(res.data!);
          if (token != null && token.isNotEmpty) {
            _cachedJsToken = token;
            _jsTokenExpiry = DateTime.now().add(const Duration(hours: 4));
            account.refreshToken = token;
            account.tokenExpiry = _jsTokenExpiry;
            await onAccountUpdated?.call(account);
            return token;
          }
        }
      } on DioException catch (e) {
        if (e.type == DioExceptionType.cancel) rethrow;
        debugPrint('[BaiduProvider] jsToken fetch failed ($url): $e');
      } catch (e) {
        debugPrint('[BaiduProvider] jsToken fetch failed ($url): $e');
      }
    }
    return _cachedJsToken;
  }

  String? _parseJsTokenFromHtml(String html) {
    final mUrlEnc = RegExp(r'fn%28%22([a-zA-Z0-9_]+)%22%29').firstMatch(html);
    if (mUrlEnc != null) return mUrlEnc.group(1);

    final m1 = RegExp(r'window\.jsToken\s*=\s*[\x22\x27]([a-zA-Z0-9_]+)[\x22\x27]').firstMatch(html);
    if (m1 != null) return m1.group(1);

    final m2 = RegExp(r'[\x22\x27]jsToken[\x22\x27]\s*:\s*[\x22\x27]([a-zA-Z0-9_]+)[\x22\x27]').firstMatch(html);
    if (m2 != null) return m2.group(1);

    final m3 = RegExp(r'fn\s*\(\s*[\x22\x27]([a-zA-Z0-9_]{32,})[\x22\x27]\s*\)').firstMatch(html);
    if (m3 != null) return m3.group(1);

    try {
      final decoded = Uri.decodeComponent(html);
      final mDec = RegExp(r'fn\s*\(\s*[\x22\x27]([a-zA-Z0-9_]{32,})[\x22\x27]\s*\)').firstMatch(decoded);
      if (mDec != null) return mDec.group(1);
    } catch (_) {}

    return null;
  }

  @override
  Future<Stream<List<int>>> downloadStream({
    required String fileId,
    int? startByte,
    int? endByte,
    CancelToken? cancelToken,
    void Function(int actualStartByte)? onActualStartByte,
  }) async {
    _throwIfCancelled(cancelToken);
    if (account.accessToken.isEmpty) {
      onActualStartByte?.call(0);
      return Stream.fromIterable([utf8.encode('Mock Baidu Download Stream Content')]);
    }

    String fsId = '';
    String filePath = '';
    if (fileId.contains('|')) {
      final idx = fileId.indexOf('|');
      fsId = fileId.substring(0, idx).trim();
      filePath = fileId.substring(idx + 1).trim();
    } else if (fileId.startsWith('/')) {
      filePath = fileId.trim();
    } else {
      fsId = fileId.trim();
    }

    final jsToken = await _ensureJsToken(cancelToken: cancelToken);
    final candidateUrls = await _collectCandidateDownloadUrls(
      fsId: fsId,
      filePath: filePath,
      jsToken: jsToken,
      cancelToken: cancelToken,
    );

    const userAgents = [
      pcsUserAgent,
      'netdisk;12.1.2;android;android-android;12;SM-A908N',
      defaultUserAgent,
    ];

    for (final url in candidateUrls) {
      for (final ua in userAgents) {
        _throwIfCancelled(cancelToken);
        final stream = await _openValidatedStream(
          url,
          ua,
          startByte: startByte,
          endByte: endByte,
          cancelToken: cancelToken,
          onActualStartByte: onActualStartByte,
        );
        if (stream != null) {
          return stream;
        }
      }
    }

    throw Exception('Baidu 파일 다운로드 스트림 연결 실패 (모든 엔드포인트 거부)');
  }

  Future<Map<String, dynamic>?> _getJsonMap(
    String url, {
    Map<String, String>? headers,
    CancelToken? cancelToken,
  }) async {
    _throwIfCancelled(cancelToken);
    try {
      final res = await _dio.get<String>(
        url,
        cancelToken: cancelToken,
        options: Options(
          headers: headers ?? _headers,
          responseType: ResponseType.plain,
          receiveTimeout: const Duration(seconds: 12),
          validateStatus: (_) => true,
        ),
      );
      if (res.statusCode == 200 && res.data != null) {
        final decoded = jsonDecode(res.data!);
        if (decoded is Map<String, dynamic>) return decoded;
        if (decoded is Map) return Map<String, dynamic>.from(decoded);
      }
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) rethrow;
      debugPrint('[BaiduProvider] GET JSON failed ($url): $e');
    } catch (e) {
      debugPrint('[BaiduProvider] GET JSON failed ($url): $e');
    }
    return null;
  }

  Future<List<String>> _collectCandidateDownloadUrls({
    required String fsId,
    required String filePath,
    String? jsToken,
    CancelToken? cancelToken,
  }) async {
    final candidateUrls = <String>[];
    void addUrl(String? url) {
      if (url != null && url.startsWith('http') && !candidateUrls.contains(url)) {
        candidateUrls.add(url);
      }
    }

    // 1. PCS locatedownload (대용량 파일/비디오 고속 직링크 CDN 목록)
    if (filePath.isNotEmpty) {
      final pcsUrl =
          'https://d.pcs.baidu.com/rest/2.0/pcs/file?method=locatedownload&app_id=$appId&path=${Uri.encodeComponent(filePath)}&ver=2.0&dtype=1&esl=1';
      final data = await _getJsonMap(
        pcsUrl,
        headers: {
          'User-Agent': pcsUserAgent,
          'Cookie': _cookieHeader,
          'Referer': 'https://pan.baidu.com/',
        },
        cancelToken: cancelToken,
      );
      if (data != null) {
        final urls = data['urls'];
        if (urls is List) {
          for (final entry in urls) {
            if (entry is Map) {
              addUrl(entry['url']?.toString());
            }
          }
        }
        if (data['server'] != null && data['path'] != null) {
          addUrl('${data['server']}${data['path']}');
        }
      }
    }

    // 2. pan.baidu.com /api/filemetas (dlink 추출)
    if (fsId.isNotEmpty || filePath.isNotEmpty) {
      final queryParams = <String, String>{
        'app_id': appId,
        'web': '1',
        'channel': 'chunlei',
        'clienttype': '0',
        'dlink': '1',
        if (jsToken != null && jsToken.isNotEmpty) 'jsToken': jsToken,
      };
      if (fsId.isNotEmpty) {
        queryParams['fsids'] = '[$fsId]';
      } else {
        queryParams['target'] = jsonEncode([filePath]);
      }

      final metaUri = Uri.parse('https://pan.baidu.com/api/filemetas').replace(
        queryParameters: queryParams,
      );
      final data = await _getJsonMap(metaUri.toString(), cancelToken: cancelToken);
      if (data != null &&
          data['errno'] == 0 &&
          data['info'] is List &&
          (data['info'] as List).isNotEmpty) {
        addUrl(data['info'][0]['dlink']?.toString());
      } else if (data != null) {
        debugPrint('[BaiduProvider] filemetas unexpected response: $data');
      }
    }

    // 3. pan.baidu.com /api/download JSON API에서 dlink 추출 (JSON 자체를 파일로 저장하지 않음)
    if (fsId.isNotEmpty) {
      final dlUri = Uri.parse('https://pan.baidu.com/api/download').replace(
        queryParameters: {
          'app_id': appId,
          'web': '1',
          'channel': 'chunlei',
          'clienttype': '0',
          'type': 'dlink',
          'fidlist': '[$fsId]',
          if (jsToken != null && jsToken.isNotEmpty) 'jsToken': jsToken,
        },
      );
      final data = await _getJsonMap(dlUri.toString(), cancelToken: cancelToken);
      if (data != null &&
          data['errno'] == 0 &&
          data['dlink'] is List &&
          (data['dlink'] as List).isNotEmpty) {
        addUrl(data['dlink'][0]['dlink']?.toString());
      }
    }

    // 4. 폴백: PCS direct method=download (소용량 파일용)
    if (filePath.isNotEmpty) {
      addUrl(
        'https://d.pcs.baidu.com/rest/2.0/pcs/file?method=download&app_id=$appId&path=${Uri.encodeComponent(filePath)}',
      );
    }

    return candidateUrls;
  }

  @visibleForTesting
  Future<Stream<List<int>>?> openValidatedStreamForTest(
    String initialUrl,
    String userAgent, {
    int? startByte,
    int? endByte,
    CancelToken? cancelToken,
    void Function(int actualStartByte)? onActualStartByte,
  }) =>
      _openValidatedStream(
        initialUrl,
        userAgent,
        startByte: startByte,
        endByte: endByte,
        cancelToken: cancelToken,
        onActualStartByte: onActualStartByte,
      );

  Future<Stream<List<int>>?> _openValidatedStream(
    String initialUrl,
    String userAgent, {
    int? startByte,
    int? endByte,
    CancelToken? cancelToken,
    void Function(int actualStartByte)? onActualStartByte,
  }) async {
    var currentUrl = initialUrl;

    for (var hop = 0; hop < 6; hop++) {
      _throwIfCancelled(cancelToken);
      try {
        final headers = <String, dynamic>{
          'User-Agent': userAgent,
          'Cookie': _cookieHeader,
          'Referer': 'https://pan.baidu.com/',
          'Accept': '*/*',
        };
        if (startByte != null || endByte != null) {
          headers['Range'] = 'bytes=${startByte ?? 0}-${endByte ?? ''}';
        }

        final response = await _dio.get<ResponseBody>(
          currentUrl,
          cancelToken: cancelToken,
          options: Options(
            headers: headers,
            responseType: ResponseType.stream,
            followRedirects: false,
            validateStatus: (status) => status != null && status >= 200 && status < 400,
          ),
        );

        final statusCode = response.statusCode ?? 0;
        if (statusCode >= 300 && statusCode < 400) {
          final location = response.headers.value('location');
          await _cancelStream(response.data?.stream);
          if (location == null || location.isEmpty) {
            return null;
          }
          currentUrl = Uri.parse(currentUrl).resolve(location).toString();
          continue;
        }

        if (statusCode != 200 && statusCode != 206) {
          await _cancelStream(response.data?.stream);
          return null;
        }

        final actualStart = resolveActualStartByte(
          statusCode: statusCode,
          contentRangeHeader: response.headers.value('content-range'),
          requestedStartByte: startByte,
        );
        if (startByte != null && actualStart > startByte) {
          await _cancelStream(response.data?.stream);
          debugPrint('[BaiduProvider] Rejected Content-Range start $actualStart > requested $startByte');
          return null;
        }

        final contentType = (response.headers.value('content-type') ?? '').toLowerCase();
        final contentDisposition = (response.headers.value('content-disposition') ?? '').toLowerCase();
        final isAttachment = contentDisposition.contains('attachment');

        // JSON/HTML/XML 에러 응답 필터링 (실제 파일이 아닌 오류 페이지 차단)
        if (!isAttachment &&
            (contentType.contains('application/json') ||
                contentType.contains('text/html') ||
                contentType.contains('text/xml'))) {
          await _cancelStream(response.data?.stream);
          debugPrint('[BaiduProvider] Rejected non-file content-type ($contentType) from $currentUrl');
          return null;
        }

        final contentLengthStr = response.headers.value('content-length');
        final contentLength = contentLengthStr != null ? int.tryParse(contentLengthStr) : null;
        if (!isAttachment && (contentLength == null || contentLength < 8192)) {
          final iterator = StreamIterator<List<int>>(response.data!.stream);
          final initialBuffer = <int>[];
          try {
            while (initialBuffer.length < 512 && await iterator.moveNext()) {
              initialBuffer.addAll(iterator.current);
            }
          } catch (e) {
            await iterator.cancel();
            rethrow;
          }

          if (initialBuffer.isEmpty && contentLength == null) {
            await iterator.cancel();
            return null;
          }

          if (_looksLikeErrorPayload(initialBuffer)) {
            await iterator.cancel();
            debugPrint(
              '[BaiduProvider] Rejected error payload ($currentUrl, $userAgent): '
              '${utf8.decode(initialBuffer, allowMalformed: true)}',
            );
            return null;
          }

          onActualStartByte?.call(actualStart);

          Stream<List<int>> passthrough() async* {
            try {
              while (await iterator.moveNext()) {
                yield iterator.current;
              }
            } finally {
              await iterator.cancel();
            }
          }

          return _wrapWithCancelToken(
            passthrough(),
            cancelToken,
            prefixBytes: initialBuffer,
            onAbort: iterator.cancel,
          );
        }

        onActualStartByte?.call(actualStart);
        return _wrapWithCancelToken(response.data!.stream, cancelToken);
      } on DioException catch (e) {
        if (e.type == DioExceptionType.cancel || cancelToken?.isCancelled == true) {
          rethrow;
        }
        debugPrint('[BaiduProvider] Stream try failed ($currentUrl, $userAgent): $e');
        return null;
      } catch (e) {
        debugPrint('[BaiduProvider] Stream try failed ($currentUrl, $userAgent): $e');
        return null;
      }
    }

    return null;
  }

  Stream<List<int>> _wrapWithCancelToken(
    Stream<List<int>> source,
    CancelToken? cancelToken, {
    List<int> prefixBytes = const [],
    Future<void> Function()? onAbort,
  }) {
    if (cancelToken == null && prefixBytes.isEmpty) return source;
    late final StreamController<List<int>> controller;
    StreamSubscription<List<int>>? sub;
    var closed = false;

    Future<void> cleanup() async {
      if (closed) return;
      closed = true;
      final s = sub;
      sub = null;
      if (s != null) {
        try {
          await s.cancel();
        } catch (_) {}
      }
      if (onAbort != null) {
        try {
          await onAbort();
        } catch (_) {}
      }
      if (!controller.isClosed) {
        await controller.close();
      }
    }

    controller = StreamController<List<int>>(
      onListen: () {
        if (cancelToken?.isCancelled == true) {
          controller.addError(
            DioException.requestCancelled(
              requestOptions: RequestOptions(path: 'baidu_download'),
              reason: cancelToken?.cancelError ?? 'Cancelled',
            ),
          );
          cleanup();
          return;
        }
        if (prefixBytes.isNotEmpty) {
          controller.add(prefixBytes);
        }
        sub = source.listen(
          (chunk) {
            if (!controller.isClosed) controller.add(chunk);
          },
          onError: (Object err, StackTrace st) {
            if (!controller.isClosed) {
              controller.addError(err, st);
            }
            cleanup();
          },
          onDone: cleanup,
          cancelOnError: true,
        );
      },
      onPause: () => sub?.pause(),
      onResume: () => sub?.resume(),
      onCancel: cleanup,
    );

    cancelToken?.whenCancel.then((err) {
      if (!controller.isClosed) {
        controller.addError(err);
      }
      cleanup();
    });

    return controller.stream;
  }

  Future<void> _cancelStream(Stream<List<int>>? stream) async {
    if (stream == null) return;
    try {
      final sub = stream.listen((_) {}, onError: (_) {});
      await sub.cancel();
    } catch (_) {}
  }

  bool _looksLikeErrorPayload(List<int> bytes) {
    if (bytes.isEmpty) return false;
    final sample = utf8.decode(bytes, allowMalformed: true).trim().toLowerCase();
    if (sample.startsWith('{') &&
        (sample.contains('"errno"') || sample.contains('"error_code"'))) {
      return true;
    }
    if (sample.startsWith('<') &&
        (sample.contains('<!doctype') || sample.contains('<html'))) {
      return true;
    }
    return false;
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
