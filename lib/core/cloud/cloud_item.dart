enum CloudProviderType {
  googleDrive('Google Drive', 'gdrive'),
  terabox('TeraBox', 'terabox'),
  baidu('Baidu Netdisk', 'baidu'),
  naver('Naver MYBOX', 'naver'),
  mega('MEGA', 'mega'),
  local('Local Device', 'local'),
  webdav('WebDAV', 'webdav');

  final String displayName;
  final String code;

  const CloudProviderType(this.displayName, this.code);

  static CloudProviderType fromCode(String code) {
    return CloudProviderType.values.firstWhere(
      (e) => e.code == code || e.name == code,
      orElse: () => CloudProviderType.local,
    );
  }
}

class CloudItem {
  final String id;
  final String name;
  final String? parentId;
  final String? path;
  final bool isFolder;
  final int? size;
  final DateTime? modifiedTime;
  final String? mimeType;
  final CloudProviderType providerType;
  final String accountId;

  const CloudItem({
    required this.id,
    required this.name,
    this.parentId,
    this.path,
    required this.isFolder,
    this.size,
    this.modifiedTime,
    this.mimeType,
    required this.providerType,
    required this.accountId,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'parentId': parentId,
        'path': path,
        'isFolder': isFolder,
        'size': size,
        'modifiedTime': modifiedTime?.toIso8601String(),
        'mimeType': mimeType,
        'providerType': providerType.code,
        'accountId': accountId,
      };

  factory CloudItem.fromJson(Map<String, dynamic> json) => CloudItem(
        id: json['id'] as String,
        name: json['name'] as String,
        parentId: json['parentId'] as String?,
        path: json['path'] as String?,
        isFolder: json['isFolder'] as bool? ?? false,
        size: json['size'] as int?,
        modifiedTime: json['modifiedTime'] != null
            ? DateTime.tryParse(json['modifiedTime'] as String)
            : null,
        mimeType: json['mimeType'] as String?,
        providerType: CloudProviderType.fromCode(json['providerType'] as String? ?? 'local'),
        accountId: json['accountId'] as String? ?? 'local',
      );
}
