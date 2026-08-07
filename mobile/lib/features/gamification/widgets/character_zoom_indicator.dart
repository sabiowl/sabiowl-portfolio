import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';

/// 【新規 (2026-06-26)】キャラクター画像をタップで全画面表示できることを
/// 視覚的に示すズームアイコンバッジ。
///
/// 配置: 円形キャラ画像の右下に `Stack + Positioned` で重ねる。
/// 色設計: 黒丸 + 白い zoom_in アイコン + 紫アクセント縁 (AppTheme.primary)。
/// サイズ: 24×24 px (Material 推奨のミニアクションバッジサイズ)。
///
/// ## 使い方
///
/// ```dart
/// Stack(
///   clipBehavior: Clip.none,
///   children: [
///     // ... 円形キャラ画像 ...
///     const Positioned(
///       right: -2,
///       bottom: -2,
///       child: CharacterZoomIndicator(),
///     ),
///   ],
/// )
/// ```
///
/// 親 `GestureDetector` のタップ判定領域内に置くため、本ウィジェット自身は
/// `IgnorePointer` 相当 (純粋な表示用)。タップ ↦ 全画面遷移は親側で実装する。
class CharacterZoomIndicator extends StatelessWidget {
  const CharacterZoomIndicator({super.key, this.size = 24});

  /// バッジ全体の直径。default 24 px (Material 推奨)。
  final double size;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.78),
          shape: BoxShape.circle,
          border: Border.all(
            color: AppTheme.primary.withValues(alpha: 0.85),
            width: 1.5,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.45),
              blurRadius: 4,
              offset: const Offset(0, 1),
            ),
          ],
        ),
        child: Center(
          child: Icon(
            Icons.zoom_in_outlined,
            color: Colors.white,
            size: size * 0.66,  // アイコンは containerサイズの 2/3
          ),
        ),
      ),
    );
  }
}
