import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:unified_cloud_manager/core/cloud/cloud_credentials.dart';
import 'package:unified_cloud_manager/core/cloud/cloud_item.dart';
import 'package:unified_cloud_manager/core/cloud/providers/google_drive_provider.dart';

void main() {
  group('GoogleDriveProvider OAuth token refresh & 401 recovery', () {
    late HttpServer server;
    late String baseUrl;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      baseUrl = 'http://127.0.0.1:${server.port}';
    });

    tearDown(() async {
      await server.close(force: true);
    });

    test('refreshes expired token before calling listItems and persists update', () async {
      var refreshCalls = 0;
      var filesCalls = 0;

      server.listen((req) async {
        if (req.uri.path == '/token') {
          refreshCalls++;
          final body = await utf8.decoder.bind(req).join();
          expect(body, contains('grant_type=refresh_token'));
          expect(body, contains('refresh_token=rt_valid'));
          expect(body, contains('client_id=custom_cid'));
          expect(body, contains('client_secret=custom_csec'));

          req.response.statusCode = 200;
          req.response.write(jsonEncode({
            'access_token': 'fresh_token_123',
            'expires_in': 3600,
          }));
          await req.response.close();
        } else if (req.uri.path == '/drive/v3/files') {
          filesCalls++;
          expect(req.headers.value('authorization'), 'Bearer fresh_token_123');
          req.response.statusCode = 200;
          req.response.write(jsonEncode({
            'files': [
              {
                'id': 'file_1',
                'name': 'demo.txt',
                'mimeType': 'text/plain',
                'size': '128',
              },
            ],
          }));
          await req.response.close();
        } else {
          req.response.statusCode = 404;
          await req.response.close();
        }
      });

      CloudAccount? updatedAccount;
      final account = CloudAccount(
        id: 'gdrive_test',
        name: 'Google Drive',
        type: CloudProviderType.googleDrive,
        email: 'user@example.com',
        accessToken: 'stale_token',
        refreshToken: 'rt_valid',
        tokenExpiry: DateTime.now().subtract(const Duration(minutes: 10)),
        customClientId: 'custom_cid',
        customClientSecret: 'custom_csec',
      );

      final provider = GoogleDriveProvider(
        account: account,
        driveApiBaseUrl: baseUrl,
        tokenEndpointUrl: '$baseUrl/token',
        onAccountUpdated: (acc) async {
          updatedAccount = acc;
        },
      );

      final items = await provider.listItems(folderIdOrPath: 'root');

      expect(refreshCalls, 1);
      expect(filesCalls, 1);
      expect(items, hasLength(1));
      expect(items.first.name, 'demo.txt');
      expect(updatedAccount?.accessToken, 'fresh_token_123');
    });

    test('retries listItems once after refreshing token on 401 response', () async {
      var refreshCalls = 0;
      var filesCalls = 0;

      server.listen((req) async {
        if (req.uri.path == '/token') {
          refreshCalls++;
          req.response.statusCode = 200;
          req.response.write(jsonEncode({
            'access_token': 'recovered_token',
            'expires_in': 3600,
          }));
          await req.response.close();
        } else if (req.uri.path == '/drive/v3/files') {
          filesCalls++;
          if (req.headers.value('authorization') == 'Bearer revoked_token') {
            req.response.statusCode = 401;
            req.response.write('{"error":{"code":401,"message":"Invalid Credentials"}}');
          } else {
            expect(req.headers.value('authorization'), 'Bearer recovered_token');
            req.response.statusCode = 200;
            req.response.write(jsonEncode({
              'files': [
                {
                  'id': 'folder_1',
                  'name': 'Photos',
                  'mimeType': 'application/vnd.google-apps.folder',
                },
              ],
            }));
          }
          await req.response.close();
        }
      });

      final account = CloudAccount(
        id: 'gdrive_401_test',
        name: 'Google Drive',
        type: CloudProviderType.googleDrive,
        email: 'user@example.com',
        accessToken: 'revoked_token',
        refreshToken: 'rt_valid',
        tokenExpiry: DateTime.now().add(const Duration(minutes: 45)),
      );

      final provider = GoogleDriveProvider(
        account: account,
        driveApiBaseUrl: baseUrl,
        tokenEndpointUrl: '$baseUrl/token',
      );

      final items = await provider.listItems(folderIdOrPath: 'root');

      expect(refreshCalls, 1);
      expect(filesCalls, 2);
      expect(items, hasLength(1));
      expect(items.first.isFolder, isTrue);
      expect(items.first.name, 'Photos');
    });

    test('throws descriptive 401 exception when token is invalid and no refresh token exists', () async {
      server.listen((req) async {
        req.response.statusCode = 401;
        req.response.write('{"error":{"code":401}}');
        await req.response.close();
      });

      final account = CloudAccount(
        id: 'gdrive_invalid',
        name: 'Google Drive',
        type: CloudProviderType.googleDrive,
        email: '',
        accessToken: 'some-client-id-or-invalid-token',
      );

      final provider = GoogleDriveProvider(
        account: account,
        driveApiBaseUrl: baseUrl,
        tokenEndpointUrl: '$baseUrl/token',
      );

      expect(
        () => provider.listItems(folderIdOrPath: 'root'),
        throwsA(
          predicate((e) => e.toString().contains('Google Drive 목록 조회 실패 (401)')),
        ),
      );
    });
  });
}
