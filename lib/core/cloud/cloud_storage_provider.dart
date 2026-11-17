import 'dart:async';
import 'package:dio/dio.dart';
import 'cloud_item.dart';

/// Parses the starting byte offset from an HTTP `Content-Range` header (e.g. `bytes 1024-2047/4096`).
int? parseContentRangeStart(String? contentRangeHeader) {
  if (contentRangeHeader == null || contentRangeHeader.isEmpty) return null;
  final match = RegExp(r'bytes\s+(\d+)-', caseSensitive: false).firstMatch(contentRangeHeader);
  if (match == null) return null;
  return int.tryParse(match.group(1)!);
}

/// Resolves the actual byte offset a server stream starts from based on HTTP status and `Content-Range`.
int resolveActualStartByte({
  required int statusCode,
  required String? contentRangeHeader,
  int? requestedStartByte,
}) {
  if (statusCode == 206) {
    return parseContentRangeStart(contentRangeHeader) ?? (requestedStartByte ?? 0);
  }
  return 0;
}

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

  /// 다운로드 바이트 스트림 (Range 옵션 및 취소 토큰 지원)
  Future<Stream<List<int>>> downloadStream({
    required String fileId,
    int? startByte,
    int? endByte,
    CancelToken? cancelToken,
    void Function(int actualStartByte)? onActualStartByte,
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
