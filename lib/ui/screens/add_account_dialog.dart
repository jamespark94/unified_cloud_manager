import 'package:flutter/material.dart';
import '../../core/cloud/cloud_credentials.dart';
import '../../core/cloud/cloud_item.dart';

class AddAccountDialog extends StatefulWidget {
  const AddAccountDialog({super.key});

  @override
  State<AddAccountDialog> createState() => _AddAccountDialogState();
}

class _AddAccountDialogState extends State<AddAccountDialog> {
  CloudProviderType? _selectedType;
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _tokenController = TextEditingController();
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();

  @override
  void dispose() {
    _nameController.dispose();
    _tokenController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
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

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        width: 440,
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
                });
              },
            )),
      ],
    );
  }

  Widget _buildDetailForm() {
    final t = _selectedType!;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: () => setState(() => _selectedType = null),
            ),
            Text('${t.displayName} 계정 연결', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          ],
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _nameController,
          decoration: const InputDecoration(labelText: '계정 표시 이름', border: OutlineInputBorder()),
        ),
        const SizedBox(height: 12),
        if (t == CloudProviderType.googleDrive) ...[
          const Text('Google Drive OAuth 또는 Access Token을 입력하세요. (공백 시 샘플 모드로 동작합니다)',
              style: TextStyle(fontSize: 12, color: Colors.white54)),
          const SizedBox(height: 8),
          TextField(
            controller: _tokenController,
            decoration: const InputDecoration(labelText: 'OAuth Access Token (선택)', border: OutlineInputBorder()),
          ),
        ] else if (t == CloudProviderType.terabox) ...[
          const Text('TeraBox 웹 쿠키 ndus 값을 입력하세요.', style: TextStyle(fontSize: 12, color: Colors.white54)),
          const SizedBox(height: 8),
          TextField(
            controller: _tokenController,
            decoration: const InputDecoration(labelText: 'ndus 쿠키 값', border: OutlineInputBorder()),
          ),
        ] else if (t == CloudProviderType.baidu) ...[
          const Text('Baidu Netdisk BDUSS 쿠키 값을 입력하세요.', style: TextStyle(fontSize: 12, color: Colors.white54)),
          const SizedBox(height: 8),
          TextField(
            controller: _tokenController,
            decoration: const InputDecoration(labelText: 'BDUSS 쿠키 값', border: OutlineInputBorder()),
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
      ],
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
