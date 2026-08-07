import 'package:flutter/material.dart';

import '../../../core/utils/character_asset.dart';

/// 【新規 (2026-06-26)】キャラクター全画面表示ビュー。
///
/// キャラ選択画面の詳細シート (`_CharacterDetailSheet`) で円形のキャラ画像を
/// タップすると本画面に遷移し、キャラを画面いっぱいに表示する。左上 ✕ ボタン
/// または背景タップで dismiss。
///
/// 設計:
///   - 黒背景でキャラのドット絵を引き立てる
///   - [BoxFit.contain] でキャラ全身を画面に収める (上下空白許容、デフォルメ
///     ドット絵を切らない)
///   - `FilterQuality.none` でピクセルアートを保持 (`CharacterAsset` と整合)
///   - 詳細シート側の円形画像と `Hero` タグで接続し、滑らかな拡大演出
///   - 左上 ✕ ボタンは Material Design 標準位置、SafeArea で notch / status
///     bar を避ける
class CharacterFullscreenView extends StatelessWidget {
  const CharacterFullscreenView({
    super.key,
    required this.imagePath,
    required this.keyFallback,
    required this.heroTag,
    this.characterName,
  });

  /// `Character.imagePath` (例: 'beatrix', '/character_m_normal.png' 等)。
  /// [CharacterAsset.assetPath] で解決される。
  final String imagePath;

  /// `Character.key` (imagePath 未移行時の補助)。
  final String keyFallback;

  /// Hero アニメーション用タグ (詳細シート側と一致させる)。
  final Object heroTag;

  /// キャラクター名 (画面下部に小さく表示、null なら非表示)。
  final String? characterName;

  /// 全画面表示への遷移ヘルパ。
  ///
  /// 詳細シート側から `CharacterFullscreenView.push(context, ...)` で呼び出す。
  /// `PageRouteBuilder` で fade transition + opaque false (背景透過) で
  /// Hero アニメーションをスムーズに描画する。
  static Future<void> push(
    BuildContext context, {
    required String imagePath,
    required String keyFallback,
    required Object heroTag,
    String? characterName,
  }) {
    return Navigator.of(context, rootNavigator: true).push(
      PageRouteBuilder(
        opaque: false,
        barrierColor: Colors.black87,
        transitionDuration: const Duration(milliseconds: 240),
        reverseTransitionDuration: const Duration(milliseconds: 180),
        pageBuilder: (_, animation, __) {
          return FadeTransition(
            opacity: animation,
            child: CharacterFullscreenView(
              imagePath:     imagePath,
              keyFallback:   keyFallback,
              heroTag:       heroTag,
              characterName: characterName,
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final resolvedPath = CharacterAsset.assetPath(imagePath);

    return Scaffold(
      backgroundColor: Colors.black,
      // ── 背景タップでも dismiss (×ボタン以外の余白タップを許容) ────────────
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => Navigator.of(context).maybePop(),
        child: Stack(
          fit: StackFit.expand,
          children: [
            // ── キャラクター全身画像 (中央、BoxFit.contain、ピクセル保持) ──
            Center(
              child: Hero(
                tag: heroTag,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Image.asset(
                    resolvedPath,
                    fit: BoxFit.contain,
                    filterQuality: FilterQuality.none,
                    errorBuilder: (_, __, ___) => const Icon(
                      Icons.person_outline,
                      color: Colors.white54,
                      size: 120,
                    ),
                  ),
                ),
              ),
            ),

            // ── 左上 ✕ ボタン (SafeArea 内、Material Design 推奨位置) ───────
            Positioned(
              top: 0,
              left: 0,
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Material(
                    color: Colors.black54,
                    shape: const CircleBorder(),
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: () => Navigator.of(context).maybePop(),
                      child: const Padding(
                        padding: EdgeInsets.all(8),
                        child: Icon(
                          Icons.close,
                          color: Colors.white,
                          size: 24,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),

            // ── キャラクター名 (画面下部、控えめに、null なら非表示) ────────
            if (characterName != null)
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 24, vertical: 16),
                    child: Text(
                      characterName!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        letterSpacing: 1.0,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
