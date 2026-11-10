import 'package:flutter/material.dart';
import '../../core/cloud/cloud_credentials.dart';

class TargetPickerSheet extends StatelessWidget {
  final List<CloudAccount> accounts;
  final String currentAccountId;
  final ValueChanged<CloudAccount> onSelectAccount;

  const TargetPickerSheet({
    super.key,
    required this.accounts,
    required this.currentAccountId,
    required this.onSelectAccount,
  });

  @override
  Widget build(BuildContext context) {
    final eligibleAccounts = accounts.where((a) => a.id != currentAccountId).toList();

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
      decoration: const BoxDecoration(
        color: Color(0xFF181F2C),
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '전송 대상 스토리지 선택',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          const Text(
            '선택한 파일/폴더를 전송할 대상 클라우드 또는 로컬 스토리지를 지정하세요.',
            style: TextStyle(fontSize: 12, color: Colors.white54),
          ),
          const SizedBox(height: 16),
          if (eligibleAccounts.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 20),
              child: Center(
                child: Text('연결된 다른 클라우드 계정이 없습니다.\n새 계정을 먼저 연결해 주세요.',
                    textAlign: TextAlign.center, style: TextStyle(color: Colors.white54)),
              ),
            )
          else
            ListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: eligibleAccounts.length,
              itemBuilder: (context, index) {
                final acc = eligibleAccounts[index];
                return ListTile(
                  leading: const Icon(Icons.cloud_upload_outlined, color: Colors.blueAccent),
                  title: Text(acc.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text(acc.type.displayName, style: const TextStyle(fontSize: 12, color: Colors.white54)),
                  trailing: const Icon(Icons.chevron_right, color: Colors.white38),
                  onTap: () {
                    Navigator.pop(context);
                    onSelectAccount(acc);
                  },
                );
              },
            ),
        ],
      ),
    );
  }
}
