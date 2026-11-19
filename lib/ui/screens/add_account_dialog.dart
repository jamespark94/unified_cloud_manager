import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import '../../core/cloud/cloud_credentials.dart';
import '../../core/cloud/cloud_item.dart';
import '../../core/cloud/providers/google_drive_provider.dart';
import '../../core/utils/battery_utils.dart';
import '../../core/utils/google_auth_manager.dart';
import '../../core/utils/oauth_helper.dart';
import '../widgets/google_login_button.dart';

class AddAccountDialog extends StatefulWidget {
  const AddAccountDialog({super.key});

  @override
  State<AddAccountDialog> createState() => _AddAccountDialogState();
}

class _AddAccountDialogState extends State<AddAccountDialog> with WidgetsBindingObserver {
  CloudProviderType? _selectedType;
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _tokenController = TextEditingController();
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();

  // Google OAuth / BYOK
  final TextEditingController _clientIdController = TextEditingController();
  final TextEditingController _clientSecretController = TextEditingController();
  final TextEditingController _manualUrlController = TextEditingController();

  bool _isLoading = false;
  String? _statusMessage;
  String? _errorMessage;
  bool _showManualInput = false;
  Timer? _manualRevealTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _isLoading && _showManualInput) {
      _checkClipboardForAuthCode();
    }
  }

  Future<void> _checkClipboardForAuthCode() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text?.trim();
      if (text != null && text.isNotEmpty && (text.contains('code=') || text.contains('localhost'))) {
        _manualUrlController.text = text;
        final ok = OAuthHelper.submitManualCallback(text);
        if (ok && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('클립보드에서 인증 코드를 감지하여 로그인을 완료합니다!')),
          );
        }
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    OAuthHelper.cancelAuthentication();
    _manualRevealTimer?.cancel();
    _nameController.dispose();
    _tokenController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _clientIdController.dispose();
    _clientSecretController.dispose();
    _manualUrlController.dispose();
    super.dispose();
  }

  void _cancelOAuth() {
    OAuthHelper.cancelAuthentication();
    _manualRevealTimer?.cancel();
    if (mounted) {
      setState(() {
        _isLoading = false;
        _statusMessage = null;
        _showManualInput = false;
      });
    }
  }

  void _submit() {
    if (_selectedType == null) return;

    final name = _nameController.text.trim().isNotEmpty
        ? _nameController.text.trim()
        : _selectedType!.displayName;
    final id = '${_selectedType!.code}_${DateTime.now().millisecondsSinceEpoch}';

    final account = CloudAccount(
      id: id,
      name: name,
      type: _selectedType!,
      email: _emailController.text.trim(),
      accessToken: _tokenController.text.trim(),
      refreshToken: _passwordController.text.trim(),
    );

    Navigator.pop(context, account);
  }

  Future<void> _startGoogleBrowserOAuth() async {
    // 이전 클립보드 code 간섭 방지
    try {
      final clip = await Clipboard.getData(Clipboard.kTextPlain);
      if (clip?.text != null && (clip!.text!.contains('code=') || clip.text!.contains('localhost:8999'))) {
        await Clipboard.setData(const ClipboardData(text: ''));
      }
    } catch (_) {}

    _manualRevealTimer?.cancel();
    _manualRevealTimer = Timer(const Duration(seconds: 2), () {
      if (mounted && _isLoading && !_showManualInput) {
        setState(() => _showManualInput = true);
      }
    });

    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _showManualInput = false;
      _statusMessage = 'Google 로그인 페이지를 여는 중입니다...';
    });

    try {
      if (Platform.isAndroid) {
        final isIgnoring = await BatteryUtils.isIgnoringBatteryOptimizations();
        if (!isIgnoring) {
          await BatteryUtils.requestIgnoreBatteryOptimizations();
          await Future.delayed(const Duration(milliseconds: 500));
        }
      }

      final customClientId = _clientIdController.text.trim();
      final customClientSecret = _clientSecretController.text.trim();
      final clientId = customClientId.isNotEmpty
          ? customClientId
          : GoogleDriveProvider.defaultClientId;
      final clientSecret = customClientSecret.isNotEmpty
          ? customClientSecret
          : (clientId == GoogleDriveProvider.defaultClientId
              ? GoogleDriveProvider.defaultClientSecret
              : null);

      final codeVerifier = OAuthHelper.generateRandomString();
      final codeChallenge = OAuthHelper.generateCodeChallenge(codeVerifier);

      final params = <String, String>{
        'client_id': clientId,
        'response_type': 'code',
        'scope':
            'https://www.googleapis.com/auth/drive.readonly https://www.googleapis.com/auth/drive.file https://www.googleapis.com/auth/userinfo.email',
        'access_type': 'offline',
        'prompt': 'consent',
        'code_challenge': codeChallenge,
        'code_challenge_method': 'S256',
      };

      final code = await OAuthHelper.authenticateWithLoopback(
        authUrlWithoutParams: GoogleDriveProvider.authEndpoint,
        params: params,
        port: 8999,
        redirectPath: '/callback',
      );

      if (code == null) {
        throw Exception('인증 코드가 수신되지 않았거나 취소되었습니다.');
      }

      if (mounted) {
        setState(() => _statusMessage = '인증이 확인되었습니다. 토큰 발급 중...');
      }

      final tokenData = await OAuthHelper.exchangeGoogleToken(
        code: code,
        redirectUri: params['redirect_uri']!,
        clientId: clientId,
        clientSecret: clientSecret,
        codeVerifier: codeVerifier,
      );

      final accessToken = tokenData['access_token'] as String? ?? '';
      final refreshToken = tokenData['refresh_token'] as String?;
      final expiresIn = tokenData['expires_in'] as int? ?? 3600;

      String email = '';
      try {
        final userRes = await http.get(
          Uri.parse('https://www.googleapis.com/oauth2/v2/userinfo'),
          headers: {'Authorization': 'Bearer $accessToken'},
        ).timeout(const Duration(seconds: 5));
        if (userRes.statusCode == 200) {
          final userJson = jsonDecode(userRes.body) as Map<String, dynamic>;
          email = userJson['email'] as String? ?? '';
        }
      } catch (_) {}

      final customName = _nameController.text.trim();
      final displayName = (customName.isNotEmpty && customName != CloudProviderType.googleDrive.displayName)
          ? customName
          : (email.isNotEmpty
              ? 'Google Drive ($email)'
              : 'Google Drive (${DateTime.now().month}/${DateTime.now().day})');

      final account = CloudAccount(
        id: 'gdrive_${DateTime.now().millisecondsSinceEpoch}',
        name: displayName,
        type: CloudProviderType.googleDrive,
        email: email,
        accessToken: accessToken,
        refreshToken: refreshToken,
        tokenExpiry: DateTime.now().add(Duration(seconds: expiresIn)),
        customClientId: customClientId,
        customClientSecret: customClientSecret,
      );

      _manualRevealTimer?.cancel();
      if (mounted) {
        Navigator.pop(context, account);
      }
    } catch (e) {
      _manualRevealTimer?.cancel();
      if (mounted) {
        setState(() {
          _isLoading = false;
          _statusMessage = null;
          _showManualInput = false;
          _errorMessage = 'Google OAuth 로그인 실패: $e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        width: 460,
        padding: const EdgeInsets.all(20),
        child: SingleChildScrollView(
          child: _selectedType == null ? _buildSelectionList() : _buildDetailForm(),
        ),
      ),
    );
  }

  Widget _buildSelectionList() {
    final types = [
      CloudProviderType.googleDrive,
      CloudProviderType.terabox,
      CloudProviderType.baidu,
      CloudProviderType.naver,
      CloudProviderType.mega,
    ];

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text('클라우드 스토리지 추가', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
          ],
        ),
        const SizedBox(height: 6),
        const Text('연결할 클라우드 서비스를 선택하세요.', style: TextStyle(fontSize: 12, color: Colors.white54)),
        const SizedBox(height: 16),
        ...types.map((t) => ListTile(
              leading: Icon(_getTypeIcon(t), color: Colors.blueAccent),
              title: Text(t.displayName, style: const TextStyle(fontWeight: FontWeight.w600)),
              trailing: const Icon(Icons.chevron_right, color: Colors.white38),
              onTap: () {
                setState(() {
                  _selectedType = t;
                  _nameController.text = t.displayName;
                  _errorMessage = null;
                });
              },
            )),
      ],
    );
  }

  Widget _buildDetailForm() {
    final t = _selectedType!;

    if (_isLoading && t == CloudProviderType.googleDrive) {
      return _buildOAuthLoadingView();
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: () => setState(() {
                _selectedType = null;
                _errorMessage = null;
              }),
            ),
            Text('${t.displayName} 계정 연결', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          ],
        ),
        const SizedBox(height: 16),
        if (_errorMessage != null) ...[
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.red.withAlpha(30),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.redAccent),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.error_outline, color: Colors.redAccent, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _errorMessage!,
                    style: const TextStyle(color: Colors.redAccent, fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
        ],
        TextField(
          controller: _nameController,
          decoration: const InputDecoration(labelText: '계정 표시 이름', border: OutlineInputBorder()),
        ),
        const SizedBox(height: 12),
        if (t == CloudProviderType.googleDrive) ...[
          _buildGoogleDriveSection(),
        ] else if (t == CloudProviderType.terabox) ...[
          const Text('TeraBox 웹 쿠키 ndus 값을 입력하세요.', style: TextStyle(fontSize: 12, color: Colors.white54)),
          const SizedBox(height: 8),
          TextField(
            controller: _tokenController,
            decoration: const InputDecoration(labelText: 'ndus 쿠키 값', border: OutlineInputBorder()),
          ),
        ] else if (t == CloudProviderType.baidu) ...[
          const Text('Baidu Netdisk BDUSS 쿠키 또는 전체 Cookie 문자열(BDUSS=...; STOKEN=...)을 입력하세요.',
              style: TextStyle(fontSize: 12, color: Colors.white54)),
          const SizedBox(height: 8),
          TextField(
            controller: _tokenController,
            decoration: const InputDecoration(labelText: 'BDUSS 또는 Cookie 문자열', border: OutlineInputBorder()),
          ),
        ] else if (t == CloudProviderType.naver) ...[
          const Text('Naver MYBOX 개인 액세스 토큰(PAT)을 입력하세요.', style: TextStyle(fontSize: 12, color: Colors.white54)),
          const SizedBox(height: 8),
          TextField(
            controller: _tokenController,
            decoration: const InputDecoration(labelText: 'MYBOX Bearer Token', border: OutlineInputBorder()),
          ),
        ] else if (t == CloudProviderType.mega) ...[
          TextField(
            controller: _emailController,
            decoration: const InputDecoration(labelText: 'MEGA 계정 이메일', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _passwordController,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'MEGA 비밀번호', border: OutlineInputBorder()),
          ),
        ],
        if (t != CloudProviderType.googleDrive) ...[
          const SizedBox(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(onPressed: () => Navigator.pop(context), child: const Text('취소')),
              const SizedBox(width: 8),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: Colors.blueAccent),
                onPressed: _submit,
                child: const Text('연결 및 저장', style: TextStyle(color: Colors.white)),
              ),
            ],
          ),
        ] else ...[
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(onPressed: () => Navigator.pop(context), child: const Text('취소')),
          ),
        ],
      ],
    );
  }

  Widget _buildGoogleDriveSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Google 계정으로 OAuth 로그인하여 Drive에 연결합니다.',
          style: TextStyle(fontSize: 12, color: Colors.white70),
        ),
        const SizedBox(height: 12),
        if (Platform.isAndroid) ...[
          SizedBox(
            width: double.infinity,
            child: GoogleLoginButton(
              label: 'Google 계정으로 원터치 연결',
              onSuccess: (googleAccount) async {
                final navigator = Navigator.of(context);
                final token = await GoogleAuthManager().getAccessToken() ?? '';
                final customName = _nameController.text.trim();
                final displayName = (customName.isNotEmpty &&
                        customName != CloudProviderType.googleDrive.displayName)
                    ? customName
                    : 'Google Drive (${googleAccount.displayName ?? googleAccount.email})';

                final account = CloudAccount(
                  id: 'gdrive_${googleAccount.id}',
                  name: displayName,
                  type: CloudProviderType.googleDrive,
                  email: googleAccount.email,
                  accessToken: token,
                  refreshToken: 'google_sign_in',
                  tokenExpiry: DateTime.now().add(const Duration(minutes: 55)),
                );
                if (mounted) {
                  navigator.pop(account);
                }
              },
              onError: (err) {
                if (mounted) {
                  setState(() {
                    _errorMessage = 'Google 네이티브 로그인 실패: $err';
                  });
                }
              },
            ),
          ),
          const SizedBox(height: 10),
        ],
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: const Text(
            '커스텀 OAuth API 키 설정 (선택 사항)',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
          ),
          subtitle: const Text(
            '직접 발급한 OAuth 2.0 Client ID / Secret이 있는 경우 입력',
            style: TextStyle(fontSize: 11, color: Colors.white54),
          ),
          children: [
            const SizedBox(height: 6),
            TextField(
              controller: _clientIdController,
              decoration: const InputDecoration(
                labelText: 'OAuth 2.0 Client ID (선택)',
                hintText: 'xxxx.apps.googleusercontent.com',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _clientSecretController,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Client Secret (선택)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          height: 46,
          child: Platform.isAndroid
              ? OutlinedButton.icon(
                  onPressed: _startGoogleBrowserOAuth,
                  icon: const Icon(Icons.open_in_browser, size: 18),
                  label: const Text('브라우저로 OAuth 로그인 (커스텀 키 / 일반)'),
                )
              : ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.blueAccent),
                  onPressed: _startGoogleBrowserOAuth,
                  icon: const Icon(Icons.open_in_browser, color: Colors.white),
                  label: const Text(
                    '브라우저 열어 로그인 및 연결',
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                  ),
                ),
        ),
        const SizedBox(height: 8),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: const Text(
            '고급: Access Token 직접 입력 / 샘플 모드',
            style: TextStyle(fontSize: 12, color: Colors.white70),
          ),
          children: [
            const SizedBox(height: 4),
            const Text(
              'OAuth Client ID가 아닌 발급된 Bearer Access Token(ya29....)을 입력하세요. 공백 저장 시 샘플 모드로 동작합니다.',
              style: TextStyle(fontSize: 11, color: Colors.white54),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _tokenController,
              decoration: const InputDecoration(
                labelText: 'Bearer Access Token (선택)',
                hintText: 'ya29....',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: OutlinedButton(
                onPressed: _submit,
                child: const Text('직접 입력으로 저장'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildOAuthLoadingView() {
    return Container(
      padding: const EdgeInsets.all(16),
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 18),
          Text(
            _statusMessage ?? '로그인 진행 중...',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 14),
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: _cancelOAuth,
            icon: const Icon(Icons.cancel_outlined, color: Colors.redAccent),
            label: const Text('로그인 취소', style: TextStyle(color: Colors.redAccent)),
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: Colors.redAccent),
            ),
          ),
          if (_showManualInput) ...[
            const SizedBox(height: 18),
            const Divider(),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.amber.withAlpha(25),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.amber.withAlpha(80)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.info_outline, color: Colors.amber, size: 18),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '브라우저에서 자동 복귀가 안 되나요?',
                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.amber),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    '브라우저 상단 주소창(URL)을 복사한 후 아래 버튼을 누르면 즉시 연결됩니다.',
                    style: TextStyle(fontSize: 12, color: Colors.white70, height: 1.4),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.amber.shade700,
                        foregroundColor: Colors.white,
                      ),
                      icon: const Icon(Icons.content_paste, size: 18),
                      label: const Text('클립보드 주소 붙여넣고 등록'),
                      onPressed: () async {
                        final data = await Clipboard.getData(Clipboard.kTextPlain);
                        final text = data?.text?.trim();
                        if (text != null && text.isNotEmpty) {
                          _manualUrlController.text = text;
                          final ok = OAuthHelper.submitManualCallback(text);
                          if (!ok && mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('유효한 인증 코드를 찾을 수 없습니다. 주소 전체를 다시 복사해주세요.')),
                            );
                          }
                        } else if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('클립보드가 비어있습니다.')),
                          );
                        }
                      },
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _manualUrlController,
              decoration: const InputDecoration(
                hintText: 'http://localhost:8999/callback?code=...',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 8),
            ElevatedButton(
              onPressed: () {
                final input = _manualUrlController.text.trim();
                if (input.isNotEmpty) {
                  final ok = OAuthHelper.submitManualCallback(input);
                  if (!ok && mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('유효한 인증 코드를 찾을 수 없습니다.')),
                    );
                  }
                }
              },
              child: const Text('수동 코드 등록'),
            ),
          ],
        ],
      ),
    );
  }

  IconData _getTypeIcon(CloudProviderType type) {
    switch (type) {
      case CloudProviderType.googleDrive:
        return Icons.add_to_drive;
      case CloudProviderType.terabox:
        return Icons.cloud_circle_outlined;
      case CloudProviderType.baidu:
        return Icons.cloud_done_outlined;
      case CloudProviderType.naver:
        return Icons.cloud_queue_rounded;
      case CloudProviderType.mega:
        return Icons.lock_outline_rounded;
      case CloudProviderType.local:
      default:
        return Icons.storage_rounded;
    }
  }
}
