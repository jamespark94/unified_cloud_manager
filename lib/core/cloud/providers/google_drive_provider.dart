import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../../utils/google_auth_manager.dart';
import '../../utils/oauth_helper.dart';
import '../cloud_credentials.dart';
import '../cloud_item.dart';
import '../cloud_storage_provider.dart';

class GoogleDriveProvider implements CloudStorageProvider {
  final CloudAccount account;
  final Future<void> Function(CloudAccount)? onAccountUpdated;
  final String driveApiBaseUrl;
  final String tokenEndpointUrl;
  final Dio _dio = Dio();

  static const String defaultClientId =
      '952086025939-8rgvb7og9u671j4h14pu5kp52db72hve.apps.googleusercontent.com';
  static const String defaultClientSecret = '';
  static const String authEndpoint = 'https://accounts.google.com/o/oauth2/v2/auth';
  static const String tokenEndpoint = 'https://oauth2.googleapis.com/token';

  GoogleDriveProvider({
    required this.account,
    this.onAccountUpdated,
    this.driveApiBaseUrl = 'https://www.googleapis.com',
    this.tokenEndpointUrl = tokenEndpoint,
  });

  String get activeClientId => account.customClientId?.isNotEmpty == true
      ? account.customClientId!
      : defaultClientId;

  String? get activeClientSecret => account.customClientSecret?.isNotEmpty == true
      ? account.customClientSecret!
      : (activeClientId == defaultClientId ? defaultClientSecret : null);

  bool get _isSkeletonMode =>
      account.accessToken.isEmpty &&
      (account.refreshToken == null || account.refreshToken!.isEmpty);

  bool get _hasOAuthRefreshToken =>
      account.refreshToken != null &&
      account.refreshToken!.isNotEmpty &&
      account.refreshToken != 'google_sign_in';

  bool get _preferNativeSignIn =>
      account.refreshToken == 'google_sign_in' ||
      (!kIsWeb &&
          Platform.isAndroid &&
          (account.customClientId == null || account.customClientId!.isEmpty) &&
          !_hasOAuthRefreshToken);

  @override
  String get providerId => account.id;

  @override
  String get providerName => account.name;

  @override
  CloudProviderType get providerType => CloudProviderType.googleDrive;

  Map<String, String> get _authHeaders => {
        'Authorization': 'Bearer ${account.accessToken}',
      };

  /// 네이티브 GoogleSignIn 또는 OAuth Refresh Token을 통해 액세스 토큰을 최신 상태로 유지합니다.
  Future<bool> refreshTokensIfNeeded() async {
    if (_isSkeletonMode) return false;

    if (!account.isTokenExpired && account.accessToken.isNotEmpty) {
      return true;
    }

    // 1. 네이티브 GoogleSignIn 세션인 경우 GoogleAuthManager 우선 사용
    if (_preferNativeSignIn) {
      try {
        final token = await GoogleAuthManager().getAccessToken();
        if (token != null && token.isNotEmpty) {
          account.accessToken = token;
          account.refreshToken = 'google_sign_in';
          account.tokenExpiry = DateTime.now().add(const Duration(minutes: 50));
          await onAccountUpdated?.call(account);
          return true;
        }
      } catch (e) {
        debugPrint('[GoogleDriveProvider] GoogleAuthManager token check: $e');
      }
    }

    // 2. OAuth Refresh Token이 있는 경우 (PC 또는 브라우저 루프백 OAuth)
    if (_hasOAuthRefreshToken) {
      try {
        final body = <String, String>{
          'client_id': activeClientId,
          'refresh_token': account.refreshToken!,
          'grant_type': 'refresh_token',
        };
        if (activeClientSecret?.isNotEmpty == true) {
          body['client_secret'] = activeClientSecret!;
        }

        final res = await OAuthHelper.postWithRetry(
          Uri.parse(tokenEndpointUrl),
          headers: {'Content-Type': 'application/x-www-form-urlencoded'},
          body: body,
        );

        if (res.statusCode == 200) {
          final data = jsonDecode(res.body) as Map<String, dynamic>;
          final newAccessToken = data['access_token'] as String?;
          if (newAccessToken != null && newAccessToken.isNotEmpty) {
            account.accessToken = newAccessToken;
            final newRefresh = data['refresh_token'] as String?;
            if (newRefresh != null && newRefresh.isNotEmpty) {
              account.refreshToken = newRefresh;
            }
            final expiresIn = data['expires_in'] as int? ?? 3600;
            account.tokenExpiry = DateTime.now().add(Duration(seconds: expiresIn));
            await onAccountUpdated?.call(account);
            return true;
          }
        } else {
          debugPrint('[GoogleDriveProvider] Token refresh failed (${res.statusCode}): ${res.body}');
        }
      } catch (e) {
        debugPrint('[GoogleDriveProvider] Token refresh error: $e');
      }
    }

    // 3. 네이티브 GoogleSignIn 강제 갱신 폴백 (iOS 제외)
    if (!kIsWeb && Platform.isAndroid && _preferNativeSignIn) {
      try {
        final headers = await GoogleAuthManager().refreshAuthHeaders();
        final auth = headers['Authorization'];
        if (auth != null && auth.startsWith('Bearer ')) {
          account.accessToken = auth.substring(7).trim();
          account.refreshToken = 'google_sign_in';
          account.tokenExpiry = DateTime.now().add(const Duration(minutes: 50));
          await onAccountUpdated?.call(account);
          return true;
        }
      } catch (_) {}
    }

    return false;
  }

  /// 401 Unauthorized 발생 시 캐시 파기 또는 Refresh Token으로 강제 재발급합니다.
  Future<bool> _forceRefreshOn401() async {
    account.tokenExpiry = DateTime.now().subtract(const Duration(minutes: 5));
    if (_preferNativeSignIn) {
      try {
        final headers = await GoogleAuthManager().refreshAuthHeaders();
        final auth = headers['Authorization'];
        if (auth != null && auth.startsWith('Bearer ')) {
          account.accessToken = auth.substring(7).trim();
          account.refreshToken = 'google_sign_in';
          account.tokenExpiry = DateTime.now().add(const Duration(minutes: 50));
          await onAccountUpdated?.call(account);
          return true;
        }
      } catch (_) {}
    }
    return await refreshTokensIfNeeded();
  }

  @override
  Future<List<CloudItem>> listItems({required String folderIdOrPath}) async {
    // Skeleton fallback if no token and no refresh mechanism
    if (_isSkeletonMode) {
      return _getSkeletonItems(folderIdOrPath);
    }

    await refreshTokensIfNeeded();

    final parent = (folderIdOrPath.isEmpty || folderIdOrPath == 'root') ? 'root' : folderIdOrPath;
    final query = Uri.encodeComponent("'$parent' in parents and trashed = false");
    final url =
        '$driveApiBaseUrl/drive/v3/files?q=$query&fields=files(id,name,mimeType,size,modifiedTime)&orderBy=folder,name&pageSize=1000';

    var res = await http.get(Uri.parse(url), headers: _authHeaders);
    if (res.statusCode == 401) {
      final refreshed = await _forceRefreshOn401();
      if (refreshed) {
        res = await http.get(Uri.parse(url), headers: _authHeaders);
      }
    }
    if (res.statusCode != 200) {
      if (res.statusCode == 401) {
        throw Exception(
          'Google Drive 목록 조회 실패 (401): 인증 토큰이 만료되었거나 유효하지 않습니다. 계정을 삭제 후 OAuth 로그인으로 다시 연결해 주세요.',
        );
      }
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
    if (_isSkeletonMode) {
      return CloudItem(
        id: 'mock_gdrive_folder_${DateTime.now().millisecondsSinceEpoch}',
        name: folderName,
        parentId: parentId,
        isFolder: true,
        providerType: CloudProviderType.googleDrive,
        accountId: account.id,
      );
    }

    await refreshTokensIfNeeded();

    final parent = (parentId.isEmpty || parentId == 'root') ? 'root' : parentId;
    final url = '$driveApiBaseUrl/drive/v3/files';
    final requestBody = jsonEncode({
      'name': folderName,
      'mimeType': 'application/vnd.google-apps.folder',
      'parents': [parent],
    });

    var res = await http.post(
      Uri.parse(url),
      headers: {..._authHeaders, 'Content-Type': 'application/json'},
      body: requestBody,
    );
    if (res.statusCode == 401 && await _forceRefreshOn401()) {
      res = await http.post(
        Uri.parse(url),
        headers: {..._authHeaders, 'Content-Type': 'application/json'},
        body: requestBody,
      );
    }

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
    if (_isSkeletonMode) return;
    await refreshTokensIfNeeded();

    final url = '$driveApiBaseUrl/drive/v3/files/$idOrPath';
    var res = await http.delete(Uri.parse(url), headers: _authHeaders);
    if (res.statusCode == 401 && await _forceRefreshOn401()) {
      res = await http.delete(Uri.parse(url), headers: _authHeaders);
    }
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
    if (_isSkeletonMode) {
      onActualStartByte?.call(0);
      return Stream.fromIterable([utf8.encode('Mock Google Drive File Content')]);
    }

    await refreshTokensIfNeeded();

    final url = '$driveApiBaseUrl/drive/v3/files/$fileId?alt=media';
    Future<Response<ResponseBody>> doRequest() {
      final headers = Map<String, String>.from(_authHeaders);
      if (startByte != null || endByte != null) {
        headers['Range'] = 'bytes=${startByte ?? 0}-${endByte ?? ''}';
      }
      return _dio.get<ResponseBody>(
        url,
        cancelToken: cancelToken,
        options: Options(
          headers: headers,
          responseType: ResponseType.stream,
        ),
      );
    }

    Response<ResponseBody> response;
    try {
      response = await doRequest();
    } on DioException catch (e) {
      if (e.response?.statusCode == 401 && await _forceRefreshOn401()) {
        response = await doRequest();
      } else {
        rethrow;
      }
    }

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
    if (_isSkeletonMode) {
      // Mock upload
      int sent = 0;
      await for (final chunk in stream) {
        sent += chunk.length;
        onProgress?.call(sent, length);
      }
      return;
    }

    await refreshTokensIfNeeded();

    final parent = (parentId.isEmpty || parentId == 'root') ? 'root' : parentId;
    // 1. Resumable Upload Session 초기화
    final initUrl = '$driveApiBaseUrl/upload/drive/v3/files?uploadType=resumable';
    final initBody = jsonEncode({
      'name': fileName,
      'parents': [parent],
    });
    Future<http.Response> initSession() => http.post(
          Uri.parse(initUrl),
          headers: {
            ..._authHeaders,
            'Content-Type': 'application/json; charset=UTF-8',
            'X-Upload-Content-Type': 'application/octet-stream',
            'X-Upload-Content-Length': length.toString(),
          },
          body: initBody,
        );

    var initRes = await initSession();
    if (initRes.statusCode == 401 && await _forceRefreshOn401()) {
      initRes = await initSession();
    }

    if (initRes.statusCode != 200) {
      throw Exception('Google Drive Resumable 세션 생성 실패 (${initRes.statusCode}): ${initRes.body}');
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
