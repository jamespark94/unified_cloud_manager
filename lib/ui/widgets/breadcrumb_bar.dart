import 'package:flutter/material.dart';

class BreadcrumbBar extends StatelessWidget {
  final List<MapEntry<String, String>> folderStack;
  final ValueChanged<int> onSelectIndex;

  const BreadcrumbBar({
    super.key,
    required this.folderStack,
    required this.onSelectIndex,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 40,
      color: const Color(0xFF131924),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: folderStack.length,
        separatorBuilder: (_, _) => const Icon(
          Icons.chevron_right,
          size: 16,
          color: Colors.white38,
        ),
        itemBuilder: (context, index) {
          final isLast = index == folderStack.length - 1;
          final title = folderStack[index].value;

          return InkWell(
            onTap: isLast ? null : () => onSelectIndex(index),
            borderRadius: BorderRadius.circular(4),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (index == 0) ...[
                    const Icon(Icons.home_outlined, size: 16, color: Colors.blueAccent),
                    const SizedBox(width: 4),
                  ],
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: isLast ? FontWeight.w600 : FontWeight.normal,
                      color: isLast ? Colors.white : Colors.blueAccent,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
