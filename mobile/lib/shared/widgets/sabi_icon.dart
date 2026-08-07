import 'package:flutter/material.dart';

/// サビの感情タグ定義
enum SabiEmotion {
  normal,     // 通常・待機
  happy,      // 軽い称賛
  excited,    // 達成・祝福
  sparkling,  // 特別達成（30日・100日等）
  wise,       // 豆知識披露
  proud,      // 賢者として深く語る
  awkward,    // 失敗談
  pity,       // 休息日・寄り添い
  sad,        // 復帰・共感
  surprise,   // 予想外の達成
}

/// 感情タグ → アセットパス のマッピング（一元管理）
///
/// 【FEAT-316】キャラドット絵 92×92 統一の一環で、旧 AI イラスト 10 種類
/// （sabi_normal/smile/laugh/eyes_sparkling/inspiration/proudly/trouble/sleep/
///  sad/surprise）を `sabi_unified.png` (PixelLab 92×92 ドット絵、ファイル
/// 自体は PixelLab Standard 出力で 1254×1254 PNG だが内容は 92×92 グリッド) に
/// 統一。SabiEmotion enum は維持し、メッセージ分岐ロジックは引き続き利用するが、
/// 表示画像は全感情で同一スプライトを使用する（ユーザー判断 2026-05-26、
/// 「画像での感情表現は捨て、メッセージで感情表現を残す」方針）。
/// 旧 AI イラストは `assets/images/sabi/archive_ai_illustrations/` に退避。
const Map<SabiEmotion, String> kSabiAssetMap = {
  SabiEmotion.normal:    'assets/images/sabi/sabi_unified.webp',
  SabiEmotion.happy:     'assets/images/sabi/sabi_unified.webp',
  SabiEmotion.excited:   'assets/images/sabi/sabi_unified.webp',
  SabiEmotion.sparkling: 'assets/images/sabi/sabi_unified.webp',
  SabiEmotion.wise:      'assets/images/sabi/sabi_unified.webp',
  SabiEmotion.proud:     'assets/images/sabi/sabi_unified.webp',
  SabiEmotion.awkward:   'assets/images/sabi/sabi_unified.webp',
  SabiEmotion.pity:      'assets/images/sabi/sabi_unified.webp',
  SabiEmotion.sad:       'assets/images/sabi/sabi_unified.webp',
  SabiEmotion.surprise:  'assets/images/sabi/sabi_unified.webp',
};

/// サビ表情アイコン（基本版）
///
/// 感情タグに対応する画像アセットを表示する。
/// [SabiMessagePanel] 等のセリフ表示ウィジェット内で使用する。
class SabiIcon extends StatelessWidget {
  const SabiIcon({
    super.key,
    this.emotion = SabiEmotion.normal,
    this.size = 80,
  });

  final SabiEmotion emotion;
  final double size;

  @override
  Widget build(BuildContext context) {
    final assetPath =
        kSabiAssetMap[emotion] ?? kSabiAssetMap[SabiEmotion.normal]!;

    return ClipRRect(
      borderRadius: BorderRadius.circular(size / 2),
      child: Image.asset(
        assetPath,
        width: size,
        height: size,
        fit: BoxFit.cover,
        // 【FEAT-316】Nearest Neighbor 補間でドット感維持。
        // sabi_unified.png は内容 92×92 のドット絵 (PNG は 1254×1254 で書き出し)、
        // size = 80 以上で大きく表示しても Linear 補間でぼやけないように明示指定。
        filterQuality: FilterQuality.none,
        // フォールバック: アセット読み込み失敗時は normal を表示
        errorBuilder: (_, __, ___) => Image.asset(
          kSabiAssetMap[SabiEmotion.normal]!,
          width: size,
          height: size,
          fit: BoxFit.cover,
          filterQuality: FilterQuality.none,
        ),
      ),
    );
  }
}

/// サビ表情アイコン（フェードアニメーション付き）
///
/// [emotion] が変化するたびに 200ms のフェードで画像を切り替える。
/// ホーム画面・習慣詳細画面のサビメッセージエリアで使用する。
///
/// [ValueKey(emotion)] が必要な理由:
/// AnimatedSwitcher は child の Key が変わったときにアニメーションを発動する。
/// Key を付けないと同じウィジェット型と判断され、画像が切り替わっても
/// アニメーションが発動しない。
class SabiIconAnimated extends StatelessWidget {
  const SabiIconAnimated({
    super.key,
    this.emotion = SabiEmotion.normal,
    this.size = 80,
  });

  final SabiEmotion emotion;
  final double size;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 200),
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: child,
      ),
      child: SabiIcon(
        key: ValueKey(emotion), // ← emotion が変わると新しいウィジェットとして扱われる
        emotion: emotion,
        size: size,
      ),
    );
  }
}
