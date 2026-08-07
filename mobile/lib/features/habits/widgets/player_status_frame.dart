import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';  // 【FEAT-445】コイン残高 watch
import '../../../core/theme/app_theme.dart';
import '../../../l10n/app_localizations.dart';
import '../../../core/utils/character_asset.dart';
import '../../gamification/providers/gamification_provider.dart';  // 【FEAT-445】shopNotifierProvider
import '../models/player.dart';

// ─────────────────────────────────────────────────────────────────────────────
// 公開定数
// ─────────────────────────────────────────────────────────────────────────────

/// ステータス枠が表示されている間、CustomScrollView の先頭に挿入するスペーサー高さ。
/// PlayerStatusFrame の実測高さ（約 118dp）+ 余白 6dp = 124dp。
/// Positioned オーバーレイの下端から WorldFrameSection 上辺まで自然な距離を確保する。
const double kPlayerStatusFrameSpacerHeight = 124.0;

// ─────────────────────────────────────────────────────────────────────────────
// PlayerStatusFrame
// ─────────────────────────────────────────────────────────────────────────────

/// ホーム画面上部に固定表示されるステータスオーバーレイパネル。
///
/// - 表示/非表示のアニメーションは呼び出し元（home_page.dart）が制御する。
/// - [onLongPress] : 長押し時に呼ばれるコールバック（`/stats` へ遷移）。
class PlayerStatusFrame extends StatelessWidget {
  const PlayerStatusFrame({
    super.key,
    required this.player,
    required this.onLongPress,
  });

  final Player player;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: GestureDetector(
        onLongPress: onLongPress,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                AppTheme.card,
                Color.lerp(AppTheme.card, AppTheme.primary, 0.08)!,
              ],
            ),
            border: Border.all(
              color: AppTheme.primary.withValues(alpha: 0.35),
              width: 1.2,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.40),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
              BoxShadow(
                color: AppTheme.primary.withValues(alpha: 0.12),
                blurRadius: 20,
                spreadRadius: -2,
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // ── メインコンテンツ行 ───────────────────────────────────
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    // ── キャラクター画像 ────────────────────────────
                    _CharacterAvatar(character: player.activeCharacter),
                    const SizedBox(width: 14),
                    // ── ステータス列 ────────────────────────────────
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // 名前 + レベル
                          _NameLevelRow(player: player),
                          const SizedBox(height: 5),
                          // EXP バー
                          _ExpProgressBar(player: player),
                          const SizedBox(height: 7),
                          // リソース行（モード・ダイヤ・ポイント）
                          _ResourceRow(player: player),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

              // ── 長押しヒント ────────────────────────────────────────
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      width: 20,
                      height: 1,
                      color: Colors.white.withValues(alpha: 0.10),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      AppLocalizations.of(context)!.habitStatusFrameLongPressHint,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.22),
                        fontSize: 9,
                        letterSpacing: 1.6,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      width: 20,
                      height: 1,
                      color: Colors.white.withValues(alpha: 0.10),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// サブウィジェット
// ─────────────────────────────────────────────────────────────────────────────

/// キャラクターのサムネイル画像。未設定時はデフォルトアイコン。
class _CharacterAvatar extends StatelessWidget {
  const _CharacterAvatar({required this.character});
  final ActiveCharacter? character;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 68,
      height: 68,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        color: AppTheme.surface,
        border: Border.all(
          color: AppTheme.primary.withValues(alpha: 0.30),
          width: 1,
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(9),
        child: Image.asset(
          // CharacterAsset.assetPath() が識別子 → フルパスに変換する。
          // identifier が null または未知のキーの場合は zenon のフォールバックを返す。
          CharacterAsset.assetPath(character?.imagePath),
          width: 68,
          height: 68,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => const _DefaultAvatarIcon(),
        ),
      ),
    );
  }
}

class _DefaultAvatarIcon extends StatelessWidget {
  const _DefaultAvatarIcon();

  @override
  Widget build(BuildContext context) {
    return Icon(
      Icons.person,
      color: AppTheme.primary.withValues(alpha: 0.4),
      size: 36,
    );
  }
}

/// プレイヤー名 + Lv. バッジ行。
class _NameLevelRow extends StatelessWidget {
  const _NameLevelRow({required this.player});
  final Player player;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Text(
            player.name,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: Colors.white,
              height: 1.2,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: 8),
        // Lv. バッジ
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
          decoration: BoxDecoration(
            color: AppTheme.primary.withValues(alpha: 0.25),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: AppTheme.primary.withValues(alpha: 0.55),
              width: 1,
            ),
          ),
          child: Text(
            'Lv. ${player.level}',
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: Colors.white,
              letterSpacing: 0.5,
            ),
          ),
        ),
      ],
    );
  }
}

/// EXP プログレスバーと EXP 数値テキスト。
class _ExpProgressBar extends StatelessWidget {
  const _ExpProgressBar({required this.player});
  final Player player;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: player.expProgress,
            minHeight: 6,
            backgroundColor: Colors.white.withValues(alpha: 0.08),
            valueColor: const AlwaysStoppedAnimation<Color>(AppTheme.primary),
          ),
        ),
        const SizedBox(height: 3),
        Text(
          'EXP ${player.currentExp} / ${player.maxExp}',
          style: TextStyle(
            fontSize: 9,
            color: Colors.white.withValues(alpha: 0.40),
            letterSpacing: 0.3,
          ),
        ),
      ],
    );
  }
}

/// リソース行（ダイヤ・コイン・割り当てポイント）。
/// アイテム数が多い場合は Wrap で折り返す。
///
/// 【FEAT-445 (2026-06-20)】ガチャチケット 3 種 (daily/weekly/monthly) 表示を廃止し、
/// 代わりにコイン残高を常時表示する設計に変更。理由:
///   - チケット残数はガチャ画面側で別途明確に表示されており、ホーム画面では
///     重複情報だった (チケット 0 個時の非表示 if 文がレイアウトを揺らしていた)
///   - コインはショップ購入の主要通貨、ホーム画面で常時残高把握できる方が UX 良好
///
/// 【ConsumerWidget 化】コインは shopNotifierProvider 経由でしか取得できないため、
/// 旧 StatelessWidget → ConsumerWidget に変更。Player モデルには coins フィールド
/// なし (Backend で習慣 EXP // 10 + bonus - spent から動的計算する設計のため、
/// Mobile 側は shopNotifierProvider.coins を真実値とする)。
class _ResourceRow extends ConsumerWidget {
  const _ResourceRow({required this.player});
  final Player player;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 【FEAT-445】shopNotifierProvider からコイン残高を取得。
    // shop が未ロード時は 0 表示 (起動初回の数百 ms のみ、即更新される)。
    final coins = ref.watch(shopNotifierProvider).valueOrNull?.coins ?? 0;
    return Wrap(
      spacing: 8,
      runSpacing: 3,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        // ── ダイヤ（AppTheme.diamond = 青）──────────────────────────────
        _ResourceItem(
          icon: Icons.diamond,
          value: '${player.diamonds}',
          color: AppTheme.diamond,
        ),

        // ── コイン（AppTheme.gold = 金）─────────────────────────────────
        // 【FEAT-445 (2026-06-20)】チケット 3 種表示を本項目で置換。
        _ResourceItem(
          icon: Icons.monetization_on,
          value: '$coins',
          color: AppTheme.gold,
        ),

        // ── 割り当て可能ポイント（橙バッジ）─────────────────────────────
        if (player.allocatablePoints > 0)
          _AllocatablePointsBadge(points: player.allocatablePoints),
      ],
    );
  }
}

/// アイコン + テキストの 1 リソースアイテム。
class _ResourceItem extends StatelessWidget {
  // 【2026-07-02 dead code cleanup】未使用の super.key を削除。
  // 全呼び出し箇所で key を渡していない private widget (前回レビュー 6/29 継続指摘)。
  const _ResourceItem({
    required this.icon,
    required this.value,
    required this.color,
  });

  final IconData icon;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 11, color: color.withValues(alpha: 0.88)),
        const SizedBox(width: 3),
        Text(
          value,
          style: TextStyle(
            fontSize: 11,
            color: color.withValues(alpha: 0.88),
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

/// 割り当て可能ポイントのプロンプトバッジ。点滅なしのシンプル強調。
class _AllocatablePointsBadge extends StatelessWidget {
  const _AllocatablePointsBadge({required this.points});
  final int points;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.orangeAccent.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(
          color: Colors.orangeAccent.withValues(alpha: 0.50),
          width: 1,
        ),
      ),
      child: Text(
        '⬆ +$points pt',
        style: const TextStyle(
          fontSize: 9,
          color: Colors.orangeAccent,
          letterSpacing: 0.5,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
