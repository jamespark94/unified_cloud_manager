import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../core/cloud/cloud_credentials.dart';
import '../core/cloud/cloud_item.dart';
import '../core/cloud/cloud_storage_provider.dart';
import '../core/cloud/providers/baidu_provider.dart';
import '../core/cloud/providers/google_drive_provider.dart';
import '../core/cloud/providers/local_storage_provider.dart';
import '../core/cloud/providers/mega_provider.dart';
import '../core/cloud/providers/naver_box_provider.dart';
import '../core/cloud/providers/terabox_provider.dart';
import '../core/transfer/transfer_queue_manager.dart';

final accountsProvider = StateNotifierProvider<AccountsNotifier, List<CloudAccount>>((ref) {
  return AccountsNotifier();
});

class AccountsNotifier extends StateNotifier<List<CloudAccount>> {
  static const String _prefKey = 'saved_cloud_accounts';

  AccountsNotifier() : super([]) {
    loadAccounts();
  }

  Future<void> loadAccounts() async {
    final prefs = await SharedPreferences.getInstance();
    final data = prefs.getString(_prefKey);
    List<CloudAccount> list = [];
    if (data != null && data.isNotEmpty) {
      list = CloudAccount.decodeList(data);
    }

    // Always ensure local device account exists
    if (!list.any((a) => a.id == 'local')) {
      final localAccount = CloudAccount(
        id: 'local',
        name: '내 기기 (Local)',
        type: CloudProviderType.local,
        email: '로컬 파일 시스템',
        accessToken: '',
      );
      list.insert(0, localAccount);
    }

    state = list;

    // Register providers to TransferQueueManager
    for (final acc in list) {
      final p = createProviderForAccount(acc);
      TransferQueueManager.instance.registerProvider(p);
    }

    // Resume any pending/interrupted tasks once all providers are registered
    TransferQueueManager.instance.processQueue();
  }

  Future<void> saveAccount(CloudAccount account) async {
    final index = state.indexWhere((a) => a.id == account.id);
    List<CloudAccount> updated;
    if (index >= 0) {
      updated = [...state];
      updated[index] = account;
    } else {
      updated = [...state, account];
    }
    state = updated;

    final p = createProviderForAccount(account);
    TransferQueueManager.instance.registerProvider(p);

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefKey, CloudAccount.encodeList(updated));
  }

  Future<void> removeAccount(String id) async {
    if (id == 'local') return; // Cannot delete local
    state = state.where((a) => a.id != id).toList();
    TransferQueueManager.instance.unregisterProvider(id);

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefKey, CloudAccount.encodeList(state));
  }

  CloudStorageProvider createProviderForAccount(CloudAccount acc) {
    switch (acc.type) {
      case CloudProviderType.googleDrive:
        return GoogleDriveProvider(account: acc, onAccountUpdated: saveAccount);
      case CloudProviderType.terabox:
        return TeraBoxProvider(account: acc, onAccountUpdated: saveAccount);
      case CloudProviderType.baidu:
        return BaiduProvider(account: acc, onAccountUpdated: saveAccount);
      case CloudProviderType.naver:
        return NaverBoxProvider(account: acc, onAccountUpdated: saveAccount);
      case CloudProviderType.mega:
        return MegaProvider(account: acc, onAccountUpdated: saveAccount);
      case CloudProviderType.local:
      default:
        return LocalStorageProvider(providerId: acc.id);
    }
  }
}
