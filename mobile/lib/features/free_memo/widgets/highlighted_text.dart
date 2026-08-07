import 'package:flutter/material.dart';

/// 【FEAT-508 (2026-07-29)】検索クエリに一致した箇所を黄色ハイライトする Text widget。
///
/// - 大文字/小文字を区別しない substring 照合
/// - regex ではなく indexOf ベース = 特殊文字も literal 扱い
/// - query 空なら通常 Text と等価 (highlight ロジック走らない)
/// - 一致箇所を全てハイライト (単一 content 内の複数マッチ対応)
class HighlightedText extends StatelessWidget {
  final String content;
  final String query;
  final TextStyle style;
  final int? maxLines;
  final TextOverflow? overflow;

  const HighlightedText({
    super.key,
    required this.content,
    required this.query,
    required this.style,
    this.maxLines,
    this.overflow,
  });

  @override
  Widget build(BuildContext context) {
    if (query.isEmpty) {
      return Text(
        content,
        style: style,
        maxLines: maxLines,
        overflow: overflow,
      );
    }

    final spans = _buildSpans(content, query, style);
    return Text.rich(
      TextSpan(style: style, children: spans),
      maxLines: maxLines,
      overflow: overflow,
    );
  }

  static List<TextSpan> _buildSpans(
    String content,
    String query,
    TextStyle baseStyle,
  ) {
    final lowerContent = content.toLowerCase();
    final lowerQuery = query.toLowerCase();
    final spans = <TextSpan>[];
    int lastEnd = 0;
    int index = lowerContent.indexOf(lowerQuery);

    while (index != -1) {
      if (index > lastEnd) {
        spans.add(TextSpan(text: content.substring(lastEnd, index)));
      }
      spans.add(TextSpan(
        text: content.substring(index, index + query.length),
        style: baseStyle.copyWith(
          backgroundColor: Colors.yellow.withValues(alpha: 0.4),
          color: Colors.black87,
        ),
      ));
      lastEnd = index + query.length;
      index = lowerContent.indexOf(lowerQuery, lastEnd);
    }
    if (lastEnd < content.length) {
      spans.add(TextSpan(text: content.substring(lastEnd)));
    }
    return spans;
  }
}
