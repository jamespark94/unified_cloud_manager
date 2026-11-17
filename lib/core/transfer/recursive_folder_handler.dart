import 'dart:async';
import '../cloud/cloud_item.dart';
import '../cloud/cloud_storage_provider.dart';
import '../database/transfer_task_entity.dart';

class RecursiveFolderHandler {
  final Map<String, CloudStorageProvider> _providers;

  RecursiveFolderHandler(this._providers);

  /// 로컬 또는 원격 폴더를 재귀적으로 탐색하여 대상 스토리지에 폴더 구조를 자동 생성하고
  /// 모든 개별 파일 전송 작업을 `List<TransferTask>`로 반환
  Future<List<TransferTask>> planFolderTransfer({
    required String sourceAccountId,
    required String destAccountId,
    required String sourceFolderIdOrPath,
    required String sourceFolderName,
    required String destParentFolderIdOrPath,
    required String groupId,
  }) async {
    final srcProvider = _providers[sourceAccountId];
    final dstProvider = _providers[destAccountId];

    if (srcProvider == null || dstProvider == null) {
      throw Exception('전송에 필요한 스토리지를 찾을 수 없습니다.');
    }

    // 1. 대상 스토리지 최상위에 해당 루트 폴더 생성
    final rootDestFolder = await dstProvider.createFolder(
      parentId: destParentFolderIdOrPath,
      folderName: sourceFolderName,
    );

    final List<TransferTask> plannedTasks = [];
    int taskSeq = 0;

    // 2. 재귀 탐색 큐 (소스 폴더, 대상 폴더, 상대 경로)
    final queue = <({String srcPath, String dstPath, String relDir})>[
      (srcPath: sourceFolderIdOrPath, dstPath: rootDestFolder.id, relDir: '')
    ];

    while (queue.isNotEmpty) {
      final current = queue.removeAt(0);
      final items = await srcProvider.listItems(folderIdOrPath: current.srcPath);

      for (final item in items) {
        if (item.isFolder) {
          // 대상에 동일 이름 서브폴더 생성
          final subDstFolder = await dstProvider.createFolder(
            parentId: current.dstPath,
            folderName: item.name,
          );
          final nextRelDir = current.relDir.isEmpty ? item.name : '${current.relDir}/${item.name}';
          queue.add((srcPath: item.id, dstPath: subDstFolder.id, relDir: nextRelDir));
        } else {
          // 파일 전송 작업 큐에 등록
          final taskType = _determineTaskType(srcProvider, dstProvider);
          final relPath = current.relDir.isEmpty ? item.name : '${current.relDir}/${item.name}';
          final taskId = 'task_${DateTime.now().microsecondsSinceEpoch}_${taskSeq++}_${item.name.hashCode}';

          plannedTasks.add(
            TransferTask(
              id: taskId,
              groupId: groupId,
              groupName: sourceFolderName,
              relativePath: relPath,
              providerType: srcProvider.providerType.code,
              sourceAccountId: sourceAccountId,
              destAccountId: destAccountId,
              taskType: taskType,
              fileName: item.name,
              sourcePath: item.id,
              destinationPath: current.dstPath,
              totalBytes: item.size ?? 0,
              transferredBytes: 0,
              status: TransferStatus.pending,
              createdAt: DateTime.now(),
              updatedAt: DateTime.now(),
            ),
          );
        }
      }
    }

    return plannedTasks;
  }

  TransferTaskType _determineTaskType(CloudStorageProvider src, CloudStorageProvider dst) {
    if (src.providerType == CloudProviderType.local && dst.providerType != CloudProviderType.local) {
      return TransferTaskType.upload;
    } else if (src.providerType != CloudProviderType.local && dst.providerType == CloudProviderType.local) {
      return TransferTaskType.download;
    } else {
      return TransferTaskType.cloudToCloud;
    }
  }
}
