import 'package:flutter_test/flutter_test.dart';
import 'package:unified_cloud_manager/core/cloud/cloud_item.dart';
import 'package:unified_cloud_manager/core/utils/sort_utils.dart';

void main() {
  final sampleItems = [
    CloudItem(
      id: 'f1',
      name: 'File 10.zip',
      isFolder: false,
      size: 500,
      modifiedTime: DateTime(2026, 1, 10),
      providerType: CloudProviderType.local,
      accountId: 'local',
    ),
    CloudItem(
      id: 'd2',
      name: 'Folder 2',
      isFolder: true,
      modifiedTime: DateTime(2026, 2, 1),
      providerType: CloudProviderType.local,
      accountId: 'local',
    ),
    CloudItem(
      id: 'f2',
      name: 'File 2.mp4',
      isFolder: false,
      size: 1500,
      modifiedTime: DateTime(2026, 3, 5),
      providerType: CloudProviderType.local,
      accountId: 'local',
    ),
    CloudItem(
      id: 'f3',
      name: 'File 2.aac',
      isFolder: false,
      size: 50,
      modifiedTime: DateTime(2026, 1, 1),
      providerType: CloudProviderType.local,
      accountId: 'local',
    ),
    CloudItem(
      id: 'd1',
      name: 'Folder 1',
      isFolder: true,
      modifiedTime: DateTime(2026, 1, 5),
      providerType: CloudProviderType.local,
      accountId: 'local',
    ),
  ];

  test('folders stay first and natural sort applies by name', () {
    final asc = SortUtils.sortCloudItems(sampleItems, field: SortField.name, ascending: true);
    expect(asc.map((e) => e.id).toList(), ['d1', 'd2', 'f3', 'f2', 'f1']);

    final desc = SortUtils.sortCloudItems(sampleItems, field: SortField.name, ascending: false);
    expect(desc.map((e) => e.id).toList(), ['d2', 'd1', 'f1', 'f2', 'f3']);
  });

  test('sort by size', () {
    final asc = SortUtils.sortCloudItems(sampleItems, field: SortField.size, ascending: true);
    expect(asc.skip(2).map((e) => e.id).toList(), ['f3', 'f1', 'f2']);

    final desc = SortUtils.sortCloudItems(sampleItems, field: SortField.size, ascending: false);
    expect(desc.skip(2).map((e) => e.id).toList(), ['f2', 'f1', 'f3']);
  });

  test('sort by modifiedDate', () {
    final desc = SortUtils.sortCloudItems(sampleItems, field: SortField.modifiedDate, ascending: false);
    expect(desc.map((e) => e.id).toList(), ['d2', 'd1', 'f2', 'f1', 'f3']);
  });

  test('sort by type', () {
    final asc = SortUtils.sortCloudItems(sampleItems, field: SortField.type, ascending: true);
    expect(asc.skip(2).map((e) => e.id).toList(), ['f3', 'f2', 'f1']);
  });
}
