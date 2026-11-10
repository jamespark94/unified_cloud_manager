import 'dart:async';
import 'cloud_item.dart';

abstract class CloudStorageProvider {
  String get providerId;
  String get providerName;
  CloudProviderType get providerType;

  /// 폴더 내 항목(파일 및 서브 폴더) 목록 조회
  Future<List<CloudItem>> listItems({required String folderIdOrPath});

  /// 새 폴더 생성
  Future<CloudItem> createFolder({
    required String parentId,
    required String folderName,
  });

  /// 파일 또는 폴더 삭제
  Future<void> deleteItem({
    required String idOrPath,
    required bool isFolder,
  });

  /// 다운로드 바이트 스트림 (Range 옵션 지원)
  Future<Stream<List<int>>> downloadStream({
    required String fileId,
    int? startByte,
    int? endByte,
  });

  /// 업로드 바이트 스트림 (진행률 콜백 지원)
  Future<void> uploadStream({
    required String parentId,
    required String fileName,
    required Stream<List<int>> stream,
    required int length,
    Function(int bytesSent, int totalBytes)? onProgress,
  });
}
