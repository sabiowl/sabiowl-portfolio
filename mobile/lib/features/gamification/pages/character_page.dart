import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import '../../../l10n/app_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/character_asset.dart';
import '../../../shared/widgets/sabi_loading_skeleton.dart';  // FEAT-218
import '../../battle/models/job.dart';  // 【FEAT-430】Job (ジョブ修飾子表示用)
import '../../habits/providers/habits_provider.dart';  // 【FEAT-427】playerNotifierProvider
import '../models/gamification_models.dart';
import '../providers/gamification_provider.dart';
import '../widgets/job_mastery_bar.dart';          // 【FEAT-511 Phase A / 2026-08-09 共有化】
import '../widgets/job_mastery_info_dialog.dart';  // 【2026-08-09】熟練度の説明 ⓘ
import '../widgets/character_fullscreen_view.dart';  // 【新規 2026-06-26】全画面表示
import '../widgets/character_zoom_indicator.dart';   // 【新規 2026-06-26】ズームアイコン

// 【BUG-109 (2026-06-14)】SSR 判定は !character.isStarter に統一。
// BUG-108 で Backend 側の SSR 判定基準が price>=3000 から is_starter=False に
// 変更されたため、Mobile 側も同基準に揃える。旧 _ssrPriceMin=3000 は廃止
// (BUG-107 で全 non-starter 価格を 1500 に統一した結果、dead path 化していた)。

/// 【FEAT-430】ジョブの修飾子を読みやすい形式に整形する。
String _formatJobModifier(Job? job, AppLocalizations l10n) {
  if (job == null) return '——';
  final onHit = switch (job.onHitEffect) {
    'burn' => l10n.gamifCharacterJobModifierFireLabel,
    'heal' => l10n.gamifCharacterJobModifierAbsorbLabel,
    _ => '',
  };
  return '${l10n.gamifCharacterJobModifierStats(job.atbSpeedModifier, job.attackPowerModifier)}'
      '$onHit\n${l10n.gamifCharacterJobModifierUlt(job.ultCost)}';
}

class CharacterPage extends ConsumerWidget {
  const CharacterPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final charsAsync = ref.watch(charactersNotifierProvider);
    final tickets =
        ref.watch(playerNotifierProvider).valueOrNull?.characterExchangeTickets ?? 0;
    final l10n = AppLocalizations.of(context)!;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.gamifCharacterPageTitle),
        actions: [
          // 【BUG-97 (2026-06-12)】Monthly 天井 (FEAT-427) 廃止により新規発行なし。
          // 既存在庫保護のため field/endpoint は維持するが、残数 0 のユーザーには非表示。
          if (tickets > 0)
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppTheme.primary.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: AppTheme.primary.withValues(alpha: 0.4)),
                  ),
                  child: Text(
                    l10n.gamifCharacterPageExchangeTicketCount(tickets),
                    style: const TextStyle(
                        color: AppTheme.primary, fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ),
        ],
      ),
      body: charsAsync.when(
        data: (chars) => _buildGrid(context, ref, chars, tickets),
        loading: () => SabiWaitingPanel(message: l10n.gamifCharacterPageLoadingSabi_message),
        error: (e, _) => Center(
          child: Text(l10n.gamifCharacterPageErrorSabi_message, style: const TextStyle(color: Colors.red)),
        ),
      ),
    );
  }

  Widget _buildGrid(
      BuildContext context, WidgetRef ref, List<Character> chars, int tickets) {
    // 【2026-05-28 UX 修正】画面下部までスクロールできない問題を解消。
    // ShellRoute 外の push 遷移 (BottomNav なし) だが、iOS home indicator 領域
    // + 視覚的余白として bottom に +24px (safe area + 余裕分)。
    final bottomPadding = MediaQuery.of(context).padding.bottom + 24;
    return GridView.builder(
      padding: EdgeInsets.fromLTRB(16, 16, 16, bottomPadding),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
        childAspectRatio: 0.75,
      ),
      itemCount: chars.length,
      itemBuilder: (_, i) => _CharacterCard(
        character: chars[i],
        onTap: () => _onTap(context, ref, chars[i], tickets),
      ),
    );
  }

  void _onTap(BuildContext context, WidgetRef ref, Character character, int tickets) {
    // 【BUG-110 (2026-06-14)】sheet 最大高を画面の 85% に制限。
    // 旧実装は isScrollControlled: true + コンテンツが長い (画像+story+価格+ボタン)
    // ため画面 status bar 直下まで sheet が伸び、drag handle が画面最上部に貼り付いて
    // 「下げづらい」状態だった。0.85 で上部に ~15% の余白を確保し、handle 位置を
    // 視覚的に下げる + 余白部分タップでも dismiss できる (showModalBottomSheet 既定の
    // barrier tap dismiss が活きる)。
    final screenHeight = MediaQuery.of(context).size.height;
    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.surface,
      isScrollControlled: true,
      useSafeArea: true,
      constraints: BoxConstraints(maxHeight: screenHeight * 0.85),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => _CharacterDetailSheet(
        character: character,
        exchangeTickets: tickets,
        onSelect: () async {
          Navigator.pop(context);
          try {
            // 【FEAT-389 (2026-05-30)】Flutter 購入 bug 修正:
            // 旧: select のみ → Backend 未所持キャラに 403。
            // 新: 未所持 + 非スターター → purchase → select の 2 ステップ。
            if (!character.owned && !character.isStarter) {
              await ref
                  .read(charactersNotifierProvider.notifier)
                  .purchase(character.id);
            }
            await ref.read(charactersNotifierProvider.notifier).select(character.id);
            if (context.mounted) {
              final l10n = AppLocalizations.of(context)!;
              ScaffoldMessenger.of(context).showSnackBar(
                // 【FEAT-231】サビ口調規約遵守: CLAUDE.md 公式比喩「航路」
                SnackBar(content: Text(l10n.gamifCharacterActivateToastSabi_message(character.name))),
              );
            }
          } on DioException catch (e) {
            if (!context.mounted) return;
            // 400/403 でサーバー側エラーメッセージを表示 (ダイヤ不足 / Lv 不足)
            final detail = (e.response?.data is Map)
                ? (e.response?.data as Map)['detail'] as String?
                : null;
            final l10n = AppLocalizations.of(context)!;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  detail ?? l10n.gamifCharacterActivateErrorSabi_message,
                ),
                backgroundColor: AppTheme.primary,
              ),
            );
          }
        },
        onExchange: () async {
          Navigator.pop(context);
          try {
            await ref.read(charactersNotifierProvider.notifier).exchange(character.id);
            if (context.mounted) {
              final l10n = AppLocalizations.of(context)!;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(l10n.gamifCharacterExchangeToastSabi_message(character.name))),
              );
            }
          } on DioException catch (e) {
            if (!context.mounted) return;
            final detail = (e.response?.data is Map)
                ? (e.response?.data as Map)['detail'] as String?
                : null;
            final l10n = AppLocalizations.of(context)!;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  detail ?? l10n.gamifCharacterExchangeErrorSabi_message,
                ),
                backgroundColor: AppTheme.primary,
              ),
            );
          }
        },
      ),
    );
  }
}

class _CharacterCard extends StatelessWidget {
  final Character character;
  final VoidCallback onTap;
  const _CharacterCard({required this.character, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final locked = !character.owned && !character.isStarter;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          // 【FEAT-293】AppTheme.surface → AppTheme.card で視認性確保
          color: AppTheme.card,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: character.active
                ? AppTheme.primary
                : Colors.white.withValues(alpha: 0.12),
            width: character.active ? 2 : 1,
          ),
        ),
        child: Stack(
          // 【2026-06-13】Stack の default alignment は AlignmentDirectional.topStart
          // (左上) で、Padding 内の Column が children 最大幅 (= 円形 80px) に
          // 縮んで左上に貼り付いていた。Column 内の crossAxisAlignment.center は
          // Column 内テキストの中央揃え効果のみで、Column 自体は左寄りのまま。
          // alignment: Alignment.center で Stack の non-Positioned child (= Padding)
          // をカード中央に配置 = 円形枠が中央寄りになる。
          // Positioned (使用中バッジ / locked オーバーレイ) は影響なし。
          alignment: Alignment.center,
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                // 【2026-05-30】Column の crossAxisAlignment が default で start
                // (左寄せ) になっており、キャラ画像が左に寄って見えていた問題を修正。
                // center を明示してカード幅の中央に配置する。
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // キャラクター画像
                  CharacterAsset.circleWidget(
                    identifier:  character.imagePath,
                    keyFallback: character.key,
                    size: 80,
                  ),
                  const SizedBox(height: 10),
                  Text(
                    character.name,
                    style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 14),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    character.role,
                    style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.5), fontSize: 11),
                    textAlign: TextAlign.center,
                  ),
                  // 【FEAT-389 (2026-05-30)】コイン→ダイヤ表示 (💎N)
                  if (!character.owned && !character.isStarter) ...[
                    const SizedBox(height: 6),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Text('💎', style: TextStyle(fontSize: 11)),
                        const SizedBox(width: 2),
                        Text(
                          '${character.price}',
                          style: const TextStyle(
                              color: AppTheme.primary, fontSize: 11),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            if (character.active)
              Positioned(
                top: 8,
                right: 8,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: AppTheme.primary,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(AppLocalizations.of(context)!.gamifCharacterInUseLabel,
                      style: const TextStyle(color: Colors.white, fontSize: 9)),
                ),
              ),
            // 【2026-06-27】NEW バッジ (左上、新キャラ追加機能)。
            // 使用中 (右上) と被らないよう左上に配置、release_date 直近 30 日内に
            // 表示。使用中バッジと共存可 (新キャラを使用中の場合も両方表示)。
            if (character.isNew)
              Positioned(
                top: 8,
                left: 8,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.orange.withValues(alpha: 0.92),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Text(
                    'NEW',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 9,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
              ),
            if (locked)
              Positioned.fill(
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: const Center(
                    child: Icon(Icons.lock, color: Colors.white54, size: 32),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _CharacterDetailSheet extends StatelessWidget {
  final Character character;
  final int exchangeTickets;
  final VoidCallback onSelect;
  final VoidCallback onExchange;
  const _CharacterDetailSheet({
    required this.character,
    required this.exchangeTickets,
    required this.onSelect,
    required this.onExchange,
  });

  Future<void> _confirmExchange(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: Text(l10n.gamifCharacterExchangeDialogTitle, style: const TextStyle(color: Colors.white)),
        content: Text(
          l10n.gamifCharacterExchangeDialogBodySabi_message(character.name),
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(l10n.gamifCharacterExchangeDialogCancelButton),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(l10n.gamifCharacterExchangeDialogConfirmButton),
          ),
        ],
      ),
    );
    if (confirmed == true) onExchange();
  }

  @override
  Widget build(BuildContext context) {
    final locked = !character.owned && !character.isStarter;
    // 【BUG-109 (2026-06-14)】SSR 判定を !isStarter に変更 (BUG-108 と整合)。
    // 全 non-starter を SSR 扱いとする v1.0 設計、price proxy 廃止。
    final isSSR = !character.isStarter;

    // 【2026-05-30 UX 修正】Android 3-button NavBar / iOS home indicator で
    // 「選択する」ボタンが画面下端に被る問題を解消。`useSafeArea: true` でも
    // Flutter SDK の `showModalBottomSheet` は内部で `SafeArea(bottom: false)`
    // を適用するため、bottom system inset は Sheet builder 側で明示加算が必要。
    // （settings_page `_AccountLinkSheet` は FEAT-183 で SafeArea ラップ対応済）
    //
    // 【BUG-109 (2026-06-14)】drag handle を SingleChildScrollView の外に出し、
    // 下方向 drag が scrollview に吸われずシート dismiss できるように構造変更。
    // 旧実装は handle が scroll 内にあり「下げづらい」状態だった (showModalBottomSheet
    // の enableDrag が scrollview gesture と競合する典型罠)。
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // ── ドラッグハンドル (scroll 外、drag dismiss 専用) ──────────────
        const _SheetDragHandle(),
        Flexible(
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(
              24,
              12,
              24,
              32 + MediaQuery.of(context).viewPadding.bottom,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // ── キャラクター画像 ──────────────────────────────
                // 【BUG-109 (2026-06-14)】locked 時もキャラ画像を表示 (半透明黒 + lock
                // icon オーバーレイで「未開放」を示す)。旧実装は lock 一色でキャラが
                // 完全に隠れており「買う前に見たい」要求に応えていなかった。
                //
                // 【新規 (2026-06-26)】円形枠タップで全画面表示に遷移。
                // Hero アニメーションで滑らかに拡大 + 左上 ✕ で復帰可能。
                // locked キャラも見られる (BUG-109 と同様の UX: 買う前に確認)。
                // 右下に CharacterZoomIndicator バッジで「タップで詳細表示」を示す。
                _CharacterAvatar(character: character, locked: locked),
                const SizedBox(height: 14),

                // ── 名前 (NEW バッジ付き、新キャラ時のみ) ──────────
                // 【2026-06-27】release_date が直近 30 日以内の新キャラには NEW バッジ
                // を名前左に表示、ユーザーが「新キャラだ」と一目で分かる視覚効果。
                _CharacterNameRow(character: character),
                const SizedBox(height: 6),

                // ── 役職バッジ ────────────────────────────────────
                _RoleBadge(role: character.role),

                // ── キャッチコピー (tagline、設定済キャラのみ) ─────
                // 【2026-06-27】Backend Character.tagline (新キャラ追加機能) を役職バッジ
                // の下に小さく表示。空文字 (既存キャラの default) なら非表示。
                if (character.tagline.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  _CharacterTagline(text: character.tagline),
                ],

                // ── ジョブ修飾子セクション (FEAT-430、「キャラ = ジョブ」固定) ──────
                // character.job が null の場合は表示しない (Pre-mortem S4: migration 未適用等)。
                if (character.job != null) ...[
                  const SizedBox(height: 12),
                  _JobModifierSection(job: character.job!),
                ],
                const SizedBox(height: 20),

                // 【BUG-125 (2026-06-14)】ストーリーセクションを廃止 (PM 判断、ストーリー
                // 構成が固まっていないため将来追加予定)。
                // 旧実装は character.description を Container にラップして表示していたが、
                // 仮文言のままリリースされるリスクがあるため一旦非表示。
                // Backend Character.description フィールド自体は v1.1+ のストーリー
                // 拡張に備えて残置 (Mobile model も同様)。

                // ── 価格（未所持・非スターターのみ）──────────────
                if (locked) _LockedPriceSection(price: character.price),

                // ── アクションボタン ──────────────────────────────
                _DetailActionButtons(
                  character:       character,
                  isSSR:           isSSR,
                  exchangeTickets: exchangeTickets,
                  onSelect:        onSelect,
                  onExchangeTap:   () => _confirmExchange(context),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
// _CharacterDetailSheet の構成パーツ (2026-08-05 抽出)
//
// 抽出前は build() が 423 行あり、可読性だけでなく再構築コストの面でも
// 問題があった (Flutter は build() 単位で再構築するため、分割しない限り
// 変化していない部分まで作り直される)。純粋な表示部品として切り出し、
// 各 widget が必要な値だけを受け取る形にしている。
//
// 【重要】本抽出はレイアウト・スタイル値・条件分岐を一切変更していない。
// 変更したのは「どこに書かれているか」だけ。
// ═══════════════════════════════════════════════════════════════════

/// シート上端のドラッグハンドル。
///
/// 【BUG-109 (2026-06-14)】SingleChildScrollView の **外** に置くこと。
/// 内側に置くと下方向 drag が scrollview に吸われ、シートを下げられなくなる
/// (showModalBottomSheet の enableDrag が scroll gesture と競合する典型罠)。
class _SheetDragHandle extends StatelessWidget {
  const _SheetDragHandle();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 8),
      child: Container(
        width: 36,
        height: 4,
        decoration: BoxDecoration(
          color: Colors.white24,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }
}

/// 円形のキャラクター画像。タップで全画面表示へ遷移する。
///
/// 【BUG-109 (2026-06-14)】locked 時もキャラ画像を表示する (半透明黒 + lock
/// icon オーバーレイで「未開放」を示す)。旧実装は lock 一色でキャラが完全に
/// 隠れており「買う前に見たい」要求に応えていなかった。
class _CharacterAvatar extends StatelessWidget {
  const _CharacterAvatar({required this.character, required this.locked});

  final Character character;
  final bool locked;

  static const double _size = 96;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => CharacterFullscreenView.push(
        context,
        imagePath:     character.imagePath,
        keyFallback:   character.key,
        heroTag:       'character_${character.id}',
        characterName: character.name,
      ),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Hero(
            tag: 'character_${character.id}',
            child: Container(
              width: _size,
              height: _size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: locked ? Colors.white24 : AppTheme.primary,
                  width: 2,
                ),
              ),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  ClipOval(
                    child: CharacterAsset.circleWidget(
                      identifier:  character.imagePath,
                      keyFallback: character.key,
                      size: _size,
                    ),
                  ),
                  if (locked)
                    ClipOval(
                      child: Container(
                        width: _size, height: _size,
                        color: Colors.black.withValues(alpha: 0.45),
                        alignment: Alignment.center,
                        child: const Icon(
                          Icons.lock,
                          size: 32,
                          color: Colors.white70,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          // ズームアイコン (右下、タップで全画面表示できることを伝える)
          const Positioned(
            right: -2,
            bottom: -2,
            child: CharacterZoomIndicator(size: 28),
          ),
        ],
      ),
    );
  }
}

/// キャラクター名。新キャラ (release_date が直近 30 日以内) には NEW バッジを付ける。
class _CharacterNameRow extends StatelessWidget {
  const _CharacterNameRow({required this.character});

  final Character character;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (character.isNew) ...[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: Colors.orange.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: Colors.orange.withValues(alpha: 0.6)),
            ),
            child: const Text(
              'NEW',
              style: TextStyle(
                color: Colors.orange,
                fontSize: 11,
                fontWeight: FontWeight.w900,
                letterSpacing: 0.5,
              ),
            ),
          ),
          const SizedBox(width: 8),
        ],
        // 【CLAUDE.md Flutter 落とし穴】Row 内の可変長テキストは Flexible で
        // 囲まないと長い名前 (英語 locale) で overflow する。
        Flexible(
          child: Text(
            character.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
                color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold),
          ),
        ),
      ],
    );
  }
}

/// 役職バッジ (ピル型)。
class _RoleBadge extends StatelessWidget {
  const _RoleBadge({required this.role});

  final String role;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: AppTheme.primary.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppTheme.primary.withValues(alpha: 0.4)),
      ),
      child: Text(
        role,
        style: const TextStyle(
            color: AppTheme.primary, fontSize: 12, fontWeight: FontWeight.w600),
      ),
    );
  }
}

/// キャッチコピー (tagline)。
class _CharacterTagline extends StatelessWidget {
  const _CharacterTagline({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      textAlign: TextAlign.center,
      style: TextStyle(
        color: Colors.white.withValues(alpha: 0.72),
        fontSize: 12,
        fontStyle: FontStyle.italic,
        height: 1.4,
      ),
    );
  }
}

/// ジョブ修飾子セクション (FEAT-430、「キャラ = ジョブ」固定)。
///
/// 見出し + 修飾子の説明ボックス + 熟練度バーの 3 段構成。
class _JobModifierSection extends StatelessWidget {
  const _JobModifierSection({required this.job});

  final Job job;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Icon(Icons.shield, size: 14, color: Colors.white60),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                l10n.gamifCharacterJobModifierPrefix(job.jobName),
                style: const TextStyle(
                  color: Colors.white60,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1.0,
                ),
              ),
            ),
            // 【2026-08-09】熟練度の説明 ⓘ。見出し側に置く理由は
            // `JobSelectionOverlay` 側のコメントと同じ (バーは未バトルだと
            // 何も描画しないため、中に入れると説明が消える)。
            const JobMasteryInfoButton(),
          ],
        ),
        const SizedBox(height: 8),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.04),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
          ),
          child: Text(
            _formatJobModifier(job, l10n),
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 13,
              height: 1.6,
            ),
          ),
        ),
        const SizedBox(height: 8),
        JobMasteryBar(jobId: job.jobId, jobName: job.jobName),
      ],
    );
  }
}

/// 未所持・非スターターキャラの価格表示 + 無料入手経路のヒント。
///
/// 【FEAT-389 (2026-05-30)】コイン → ダイヤ表示に変更 (💎N 形式)。
/// 【BUG-133 (2026-06-17)】「Lv.X 解禁」テキスト + 鍵アイコンを削除。
/// ユーザー判断「キャラはレベルで開放する仕様ではない」採択により、ダイヤ価格
/// のみが入手障壁として有効。Backend の Lv チェックも同 BUG で撤去済。
class _LockedPriceSection extends StatelessWidget {
  const _LockedPriceSection({required this.price});

  final int price;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text('💎', style: TextStyle(fontSize: 16)),
            const SizedBox(width: 4),
            Text(
              '$price',
              style: const TextStyle(
                  color: AppTheme.primary,
                  fontSize: 14,
                  fontWeight: FontWeight.bold),
            ),
          ],
        ),
        const SizedBox(height: 10),
        // 【gameplay_review 20260530 §B-1 → Priority 1-②】
        // 課金壁の印象緩和: 「キャラ購入はターゲット経路、ガチャでも入手可」を明示。
        // 無料経路は Monthly 確定 + Weekly サプライズ + Shop ダイヤ購入の 3 経路。
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: AppTheme.primary.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: AppTheme.primary.withValues(alpha: 0.20),
              width: 0.8,
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.casino_outlined,
                size: 14,
                color: AppTheme.primary.withValues(alpha: 0.85),
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  l10n.gamifCharacterSsrHintSabi_message,
                  style: TextStyle(
                    color: AppTheme.primary.withValues(alpha: 0.85),
                    fontSize: 11.5,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
      ],
    );
  }
}

/// 詳細シート下部のアクションボタン群。
///
/// 使用中 / 選択可能 / 購入 の 3 状態を出し分ける。
class _DetailActionButtons extends StatelessWidget {
  const _DetailActionButtons({
    required this.character,
    required this.isSSR,
    required this.exchangeTickets,
    required this.onSelect,
    required this.onExchangeTap,
  });

  final Character character;
  final bool isSSR;
  final int exchangeTickets;
  final VoidCallback onSelect;
  final VoidCallback onExchangeTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    if (character.active) {
      return Text(
        l10n.gamifCharacterInUseChip,
        style: const TextStyle(
            color: AppTheme.primary, fontSize: 14, fontWeight: FontWeight.w600),
      );
    }

    // 【2026-05-30】starter キャラ (sol/aria) は owned=false の状態でも
    // is_starter=true で「無料解放済」扱い。詳細シートを開いた際 onSelect 内で
    // purchase をスキップ → select のみ呼ぶため、ボタンも「選択する」表示。
    if (character.owned || character.isStarter) {
      return SizedBox(
        width: double.infinity,
        child: ElevatedButton(
          onPressed: onSelect,
          child: Text(l10n.gamifCharacterSelectButton),
        ),
      );
    }

    // 【BUG-109 (2026-06-14)】locked (= unowned non-starter) でダイヤ購入ボタンを
    // 表示する。旧実装は「!locked」ブランチを通らず disabled「未解放のキャラクター」
    // に落ちており、ダイヤで開放できない致命バグだった (FEAT-389 onSelect の
    // purchase+select 2 ステップ実装が unreachable 状態)。
    // 【BUG-133 (2026-06-17)】Lv チェック撤去。ダイヤ不足のみ Backend 400 →
    // onSelect の DioException catch で SnackBar 表示する。
    return Column(
      children: [
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: onSelect,
            child: Text(l10n.gamifCharacterPurchaseButton(character.price)),
          ),
        ),
        // 【FEAT-427 (2026-06-11)】マンスリー天井で得たキャラ交換券での交換導線。
        // BUG-108/109 で isSSR 判定を !isStarter に変更済。
        if (isSSR && exchangeTickets >= 1) ...[
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: onExchangeTap,
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: AppTheme.primary.withValues(alpha: 0.6)),
              ),
              child: Text(
                l10n.gamifCharacterExchangeTicketButton(exchangeTickets),
                style: const TextStyle(color: AppTheme.primary),
              ),
            ),
          ),
        ],
      ],
    );
  }
}
