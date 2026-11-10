import 'package:flutter_test/flutter_test.dart';
import 'package:unified_cloud_manager/core/cloud/cloud_item.dart';
import 'package:unified_cloud_manager/core/database/transfer_task_entity.dart';
import 'package:unified_cloud_manager/core/utils/format_utils.dart';

void main() {
  test('FormatUtils file size format check', () {
    expect(FormatUtils.formatBytes(500), '500.0 B');
    expect(FormatUtils.formatBytes(1024 * 1024 * 5), '5.0 MB');
    expect(FormatUtils.formatSpeed(1024 * 1024 * 2.5), '2.5 MB/s');
  });

  test('TransferTask progress calculation', () {
    final task = TransferTask(
      id: 'test_1',
      providerType: 'local',
      sourceAccountId: 'local',
      destAccountId: 'gdrive_1',
      taskType: TransferTaskType.upload,
      fileName: 'test.mp4',
      sourcePath: '/tmp/test.mp4',
      destinationPath: 'root',
      totalBytes: 1000,
      transferredBytes: 500,
      status: TransferStatus.active,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );

    expect(task.progress, 0.5);
    expect(task.status.label, '전송 중');
  });

  test('CloudItem JSON serialization', () {
    final item = CloudItem(
      id: 'f_1',
      name: 'test_folder',
      isFolder: true,
      providerType: CloudProviderType.googleDrive,
      accountId: 'gdrive_1',
    );

    final json = item.toJson();
    final reconstructed = CloudItem.fromJson(json);

    expect(reconstructed.id, 'f_1');
    expect(reconstructed.name, 'test_folder');
    expect(reconstructed.isFolder, true);
    expect(reconstructed.providerType, CloudProviderType.googleDrive);
  });
}
