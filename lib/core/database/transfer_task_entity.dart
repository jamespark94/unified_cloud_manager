enum TransferTaskType {
  upload('업로드'),
  download('다운로드'),
  cloudToCloud('클라우드 간 전송');

  final String label;
  const TransferTaskType(this.label);

  static TransferTaskType fromString(String val) {
    return TransferTaskType.values.firstWhere(
      (e) => e.name == val,
      orElse: () => TransferTaskType.download,
    );
  }
}

enum TransferStatus {
  pending('대기 중'),
  active('전송 중'),
  paused('일시정지'),
  completed('완료'),
  failed('실패');

  final String label;
  const TransferStatus(this.label);

  static TransferStatus fromString(String val) {
    return TransferStatus.values.firstWhere(
      (e) => e.name == val,
      orElse: () => TransferStatus.pending,
    );
  }
}

class TransferTask {
  final String id;
  final String? groupId;
  final String? groupName;
  final String? relativePath;
  final String providerType;
  final String sourceAccountId;
  final String destAccountId;
  final TransferTaskType taskType;
  final String fileName;
  final String sourcePath;
  final String destinationPath;
  final int totalBytes;
  final int transferredBytes;
  final TransferStatus status;
  final int retryCount;
  final String? errorMessage;
  final DateTime createdAt;
  final DateTime updatedAt;

  const TransferTask({
    required this.id,
    this.groupId,
    this.groupName,
    this.relativePath,
    required this.providerType,
    required this.sourceAccountId,
    required this.destAccountId,
    required this.taskType,
    required this.fileName,
    required this.sourcePath,
    required this.destinationPath,
    this.totalBytes = 0,
    this.transferredBytes = 0,
    this.status = TransferStatus.pending,
    this.retryCount = 0,
    this.errorMessage,
    required this.createdAt,
    required this.updatedAt,
  });

  double get progress => totalBytes > 0 ? (transferredBytes / totalBytes).clamp(0.0, 1.0) : 0.0;

  TransferTask copyWith({
    String? id,
    String? groupId,
    String? groupName,
    String? relativePath,
    String? providerType,
    String? sourceAccountId,
    String? destAccountId,
    TransferTaskType? taskType,
    String? fileName,
    String? sourcePath,
    String? destinationPath,
    int? totalBytes,
    int? transferredBytes,
    TransferStatus? status,
    int? retryCount,
    String? errorMessage,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return TransferTask(
      id: id ?? this.id,
      groupId: groupId ?? this.groupId,
      groupName: groupName ?? this.groupName,
      relativePath: relativePath ?? this.relativePath,
      providerType: providerType ?? this.providerType,
      sourceAccountId: sourceAccountId ?? this.sourceAccountId,
      destAccountId: destAccountId ?? this.destAccountId,
      taskType: taskType ?? this.taskType,
      fileName: fileName ?? this.fileName,
      sourcePath: sourcePath ?? this.sourcePath,
      destinationPath: destinationPath ?? this.destinationPath,
      totalBytes: totalBytes ?? this.totalBytes,
      transferredBytes: transferredBytes ?? this.transferredBytes,
      status: status ?? this.status,
      retryCount: retryCount ?? this.retryCount,
      errorMessage: errorMessage ?? this.errorMessage,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toMap() => {
        'id': id,
        'group_id': groupId,
        'group_name': groupName,
        'relative_path': relativePath,
        'provider_type': providerType,
        'source_account_id': sourceAccountId,
        'dest_account_id': destAccountId,
        'task_type': taskType.name,
        'file_name': fileName,
        'source_path': sourcePath,
        'destination_path': destinationPath,
        'total_bytes': totalBytes,
        'transferred_bytes': transferredBytes,
        'status': status.name,
        'retry_count': retryCount,
        'error_message': errorMessage,
        'created_at': createdAt.millisecondsSinceEpoch,
        'updated_at': updatedAt.millisecondsSinceEpoch,
      };

  factory TransferTask.fromMap(Map<String, dynamic> map) => TransferTask(
        id: map['id'] as String,
        groupId: map['group_id'] as String?,
        groupName: map['group_name'] as String?,
        relativePath: map['relative_path'] as String?,
        providerType: map['provider_type'] as String,
        sourceAccountId: map['source_account_id'] as String? ?? 'local',
        destAccountId: map['dest_account_id'] as String? ?? 'local',
        taskType: TransferTaskType.fromString(map['task_type'] as String? ?? 'download'),
        fileName: map['file_name'] as String,
        sourcePath: map['source_path'] as String,
        destinationPath: map['destination_path'] as String,
        totalBytes: map['total_bytes'] as int? ?? 0,
        transferredBytes: map['transferred_bytes'] as int? ?? 0,
        status: TransferStatus.fromString(map['status'] as String? ?? 'pending'),
        retryCount: map['retry_count'] as int? ?? 0,
        errorMessage: map['error_message'] as String?,
        createdAt: DateTime.fromMillisecondsSinceEpoch(map['created_at'] as int? ?? 0),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(map['updated_at'] as int? ?? 0),
      );
}
