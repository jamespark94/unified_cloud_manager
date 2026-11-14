import 'package:flutter/material.dart';
import '../cloud/cloud_item.dart';

enum SortField {
  name('이름', Icons.sort_by_alpha_rounded),
  size('크기', Icons.data_usage_rounded),
  modifiedDate('변경날짜', Icons.schedule_rounded),
  type('유형', Icons.category_outlined);

  final String label;
  final IconData icon;

  const SortField(this.label, this.icon);

  bool get defaultAscending => this == name || this == type;
}

class NaturalSortUtils {
  static final RegExp _numRegex = RegExp(r'(\d+)');

  static int compare(String a, String b) {
    final aTokens = _tokenize(a.toLowerCase());
    final bTokens = _tokenize(b.toLowerCase());
    final minLength = aTokens.length < bTokens.length ? aTokens.length : bTokens.length;

    for (int i = 0; i < minLength; i++) {
      final aTok = aTokens[i];
      final bTok = bTokens[i];

      if (aTok.isNumber && bTok.isNumber) {
        final aVal = BigInt.tryParse(aTok.text) ?? BigInt.zero;
        final bVal = BigInt.tryParse(bTok.text) ?? BigInt.zero;
        final comp = aVal.compareTo(bVal);
        if (comp != 0) return comp;
        final lenComp = aTok.text.length.compareTo(bTok.text.length);
        if (lenComp != 0) return lenComp;
      } else {
        final comp = aTok.text.compareTo(bTok.text);
        if (comp != 0) return comp;
      }
    }

    return aTokens.length.compareTo(bTokens.length);
  }

  static List<_SortToken> _tokenize(String str) {
    final List<_SortToken> tokens = [];
    int lastEnd = 0;
    for (final match in _numRegex.allMatches(str)) {
      if (match.start > lastEnd) {
        tokens.add(_SortToken(str.substring(lastEnd, match.start), false));
      }
      tokens.add(_SortToken(match.group(0)!, true));
      lastEnd = match.end;
    }
    if (lastEnd < str.length) {
      tokens.add(_SortToken(str.substring(lastEnd), false));
    }
    return tokens;
  }
}

class _SortToken {
  final String text;
  final bool isNumber;
  const _SortToken(this.text, this.isNumber);
}

class SortUtils {
  static String getCloudItemTypeLabel(CloudItem item) {
    if (item.isFolder) return '폴더';
    final dotIndex = item.name.lastIndexOf('.');
    if (dotIndex > 0 && dotIndex + 1 < item.name.length) {
      return item.name.substring(dotIndex + 1).toUpperCase();
    }
    if (item.mimeType != null && item.mimeType!.isNotEmpty) {
      return item.mimeType!.toUpperCase();
    }
    return '파일';
  }

  static List<CloudItem> sortCloudItems(
    Iterable<CloudItem> items, {
    required SortField field,
    required bool ascending,
  }) {
    final list = List<CloudItem>.from(items);
    list.sort((a, b) => compareCloudItems(a, b, field: field, ascending: ascending));
    return list;
  }

  static int compareCloudItems(
    CloudItem a,
    CloudItem b, {
    required SortField field,
    required bool ascending,
  }) {
    // 폴더를 항상 파일보다 앞에 배치
    if (a.isFolder != b.isFolder) {
      return a.isFolder ? -1 : 1;
    }

    int cmp = 0;
    switch (field) {
      case SortField.name:
        cmp = NaturalSortUtils.compare(a.name, b.name);
        return ascending ? cmp : -cmp;

      case SortField.size:
        if (a.size == null && b.size == null) {
          return NaturalSortUtils.compare(a.name, b.name);
        }
        if (a.size == null) return 1;
        if (b.size == null) return -1;
        cmp = a.size!.compareTo(b.size!);
        if (cmp != 0) return ascending ? cmp : -cmp;
        return NaturalSortUtils.compare(a.name, b.name);

      case SortField.modifiedDate:
        if (a.modifiedTime == null && b.modifiedTime == null) {
          return NaturalSortUtils.compare(a.name, b.name);
        }
        if (a.modifiedTime == null) return 1;
        if (b.modifiedTime == null) return -1;
        cmp = a.modifiedTime!.compareTo(b.modifiedTime!);
        if (cmp != 0) return ascending ? cmp : -cmp;
        return NaturalSortUtils.compare(a.name, b.name);

      case SortField.type:
        cmp = getCloudItemTypeLabel(a).toLowerCase().compareTo(getCloudItemTypeLabel(b).toLowerCase());
        if (cmp != 0) return ascending ? cmp : -cmp;
        return NaturalSortUtils.compare(a.name, b.name);
    }
  }
}
