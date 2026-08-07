import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// キャラクター画像のローカルアセットを解決するユーティリティクラス。
///
/// Django の `Character.image_path` には識別子（例: `normal_1`, `archer`）が
/// 格納されており、`CharacterAsset.assetPath()` でフルパスに変換する。
///
/// 旧形式（`/character_m_normal.png` 等）は migration 0038 で変換済みのため
/// フォールバックとしてのみ対応する。
class CharacterAsset {
  CharacterAsset._();

  static const _basePath = 'assets/images/characters/character_';
  static const _ext = '.webp';
  static const _fallbackPath = 'assets/images/characters/character_zenon.webp';

  // 識別子 → アセットパス（BUG-19: 新キャラクター名に更新）
  // 【FEAT-316】faye_wear_glass を削除（Backend Character マスターには存在せず、
  // Flutter のみの dead asset だったため archive 退避済）。
  // 【FEAT-428】5 キャラ追加 (kyle/fia/irene/luna/aurum、migration 0128)。
  static const _identifiers = {
    'zenon',
    'aria',
    'beatrix',
    'faye',
    'lucia',
    'noir',
    'cyan',     // 【BUG-103 (2026-06-14)】旧 'rune' → 'cyan' に rename (migration 0137)
    'rune',     // 【BUG-104 (2026-06-14)】新キャラ「ルーン (黒魔導士)」追加 (migration 0138)
    'sol',
    'kyle',
    'fia',
    'irene',
    'luna',
    'aurum',
  };

  /// 識別子からアセットパスを返す。
  /// null または未知の識別子の場合はフォールバック画像を返す。
  static String assetPath(String? identifier) {
    if (identifier == null || identifier.isEmpty) return _fallbackPath;

    // 旧形式（/character_m_normal.png）が残っている場合の簡易変換
    String id = identifier;
    if (id.startsWith('/')) {
      // 例: /character_m_normal.webp → m_normal（未使用だが念のため）
      id = id.replaceFirst('/character_', '').replaceAll('.webp', '').replaceAll('.png', '');
    }

    if (_identifiers.contains(id)) {
      return '$_basePath$id$_ext';
    }
    return _fallbackPath;
  }

  /// `CircleAvatar` 相当の円形キャラクター画像ウィジェットを返す。
  ///
  /// - [identifier]: Django `Character.image_path` の値
  /// - [keyFallback]: `Character.key` の値（image_path が未移行の場合のフォールバック）
  /// - [size]: 直径（px）
  static Widget circleWidget({
    required String? identifier,
    String? keyFallback,
    double size = 56,
  }) {
    // identifier が既知識別子でなく keyFallback が既知なら keyFallback を使う
    final resolved = _identifiers.contains(identifier)
        ? identifier
        : (_identifiers.contains(keyFallback) ? keyFallback : identifier);
    final path = assetPath(resolved);
    return SizedBox(
      width: size,
      height: size,
      child: ClipOval(
        child: Image.asset(
          path,
          width: size,
          height: size,
          fit: BoxFit.cover,
          // 【FEAT-316】PixelLab 92×92 ドット絵を Nearest Neighbor 補間で
          // 表示してドット感維持（Linear だとぼやけて世界観破綻）。
          filterQuality: FilterQuality.none,
          errorBuilder: (_, __, ___) => _fallbackIcon(size),
        ),
      ),
    );
  }

  /// エラー時のフォールバックアイコン
  static Widget _fallbackIcon(double size) {
    return Container(
      width: size,
      height: size,
      color: AppTheme.card,
      child: Icon(
        Icons.person,
        size: size * 0.6,
        color: Colors.white54,
      ),
    );
  }
}
