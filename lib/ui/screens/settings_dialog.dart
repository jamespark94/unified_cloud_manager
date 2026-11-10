import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../state/settings_provider.dart';

class SettingsDialog extends ConsumerWidget {
  const SettingsDialog({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final notifier = ref.read(settingsProvider.notifier);

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        width: 480,
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Row(
                  children: [
                    Icon(Icons.settings_outlined, color: Colors.blueAccent),
                    SizedBox(width: 8),
                    Text('다운로드 및 전송 설정', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  ],
                ),
                IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
              ],
            ),
            const SizedBox(height: 16),
            const Text(
              '기본 다운로드 경로',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.white70),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      color: const Color(0xFF131924),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.white12),
                    ),
                    child: Text(
                      settings.defaultDownloadPath.isNotEmpty
                          ? settings.defaultDownloadPath
                          : '설정된 기본 경로 없음',
                      style: const TextStyle(fontSize: 13),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton.icon(
                  onPressed: () async {
                    final selected = await FilePicker.getDirectoryPath(
                      dialogTitle: '기본 다운로드 폴더 선택',
                      initialDirectory: settings.defaultDownloadPath,
                    );
                    if (selected != null && selected.isNotEmpty) {
                      await notifier.setDefaultDownloadPath(selected);
                    }
                  },
                  icon: const Icon(Icons.folder_open, size: 16),
                  label: const Text('변경'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blueAccent,
                    foregroundColor: Colors.white,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('다운로드할 때마다 대상 폴더 묻기', style: TextStyle(fontSize: 14)),
              subtitle: const Text(
                '체크 해제 시 위 기본 다운로드 경로로 즉시 저장됩니다.',
                style: TextStyle(fontSize: 12, color: Colors.white54),
              ),
              value: settings.askDownloadPathEveryTime,
              onChanged: (val) => notifier.setAskDownloadPathEveryTime(val),
            ),
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerRight,
              child: ElevatedButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('확인'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
