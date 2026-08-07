import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../models/battle_state.dart';
import '../models/tactic.dart';
import '../providers/battle_provider.dart';
import '../services/battle_haptics_service.dart';  // 【gameplay_review 20260803 要素 A-1】
import 'combatant_sprite.dart';
import 'floating_damage_text.dart';  // 【FEAT-385】Floating Damage 数値表示
import 'hp_atb_combined_bar.dart';   // 【FEAT-384】案 Z HP|ATB 一体型バー
import 'potion_count_indicator.dart';
import 'ult_gauge.dart';

/// 【FEAT-297 Phase 1】WorldFrameSection 内に表示する戦闘ミニビュー。
///
/// レイアウト（Gemini 要件 §2 + 設計ノート §3.3 準拠）:
///   - 左 = 敵 / 右 = 味方 の対面構図
///   - sprite 48×48（フル画面 96×96 の半分）
///   - HP バー（細い、フォント 9-10）+ ATB ゲージ（高さ 3px）
///   - 作戦切替 UI は **本ビューに表示しない**（全画面 BattlePage 側で操作）
///   - 【FEAT-298】右上に PotionCountIndicator（plan > 0 のときのみ）
///
/// 戦闘なし時は `SizedBox.shrink()` で完全に消える（Pre-mortem #5 対応）。
///
/// `onTap` を渡すと WorldFrameSection 全体タップで BattlePage 遷移する。
class MiniBattleArena extends ConsumerWidget {
  const MiniBattleArena({super.key, this.onTap});

  /// タップで全画面 BattlePage 遷移。null ならタップ不可。
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 【gameplay_review 20260803 要素 A-1】ホーム経路にもバトル触覚を通す。
    //
    // `BattleHapticsService` は BattlePage / UltimateButton からしか呼ばれておらず、
    // FEAT-513 で主戦場になったこの MiniArena は完全に無振動だった。
    //
    // ただし **全打撃を振動させてはいけない** — 習慣リストを読んでいる最中に
    // 100 秒間震え続けることになる。クリティカルと必殺の 2 種だけを通し、
    // 「ながら見していたら手の中で 1 回だけドンと来る」体験にする。
    //
    // BattlePage が push されている間は本 widget も tree に残るため、
    // `isCurrent` で「今この画面が最前面か」を見て二重発火を防ぐ。
    ref.listen<BattleSession>(battleSessionProvider, (prev, next) {
      if (!(ModalRoute.of(context)?.isCurrent ?? true)) return;

      final nextUlt = next.state?.ultimateHitEvent;
      if (nextUlt != null && nextUlt != prev?.state?.ultimateHitEvent) {
        BattleHapticsService.instance.playUltimateHit();
        return;
      }

      final nextPlayer = next.state?.playerDamageEvent;
      final nextEnemy = next.state?.enemyDamageEvent;
      DamageEvent? fired;
      if (nextPlayer != null && nextPlayer != prev?.state?.playerDamageEvent) {
        fired = nextPlayer;
      } else if (nextEnemy != null && nextEnemy != prev?.state?.enemyDamageEvent) {
        fired = nextEnemy;
      }
      // 通常命中 (playNormalHit) は意図的に通さない。
      if (fired != null && fired.isCritical) {
        BattleHapticsService.instance.playCriticalHit();
      }
    });

    final session = ref.watch(battleSessionProvider);
    final state = session.state;
    if (state == null) return const SizedBox.shrink();

    // RepaintBoundary で WorldFrame 他レイヤーから隔離（Pre-mortem #5）。
    return RepaintBoundary(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Stack(
          children: [
            // 【FEAT-386 (2026-05-29)】MiniArena 内 Enemy 別背景 (FEAT-381 拡張)。
            // 旧 FEAT-381 は BattlePage 専用設計だったが、ユーザー情報「BattlePage
            // 廃止認識」を受けて、Enemy 別背景を体感できる経路を本 MiniArena に拡張。
            // 構造: WorldFrame 背景の上に Enemy 別画像を重ね (Positioned.fill)、
            // 半透明黒オーバーレイ alpha 0.25 で HP|ATB バー / sprite 視認性確保。
            // 戦闘終了時は session.state == null で MiniArena 全体が消えるため、
            // 背景も自動的に WorldFrame の世界画像に戻る (FEAT-381「元に戻す」原則)。
            if (state.enemyBackgroundImagePath.isNotEmpty) ...[
              Positioned.fill(
                child: Image.asset(
                  state.enemyBackgroundImagePath,
                  fit: BoxFit.cover,
                  filterQuality: FilterQuality.none,
                  errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                ),
              ),
              Positioned.fill(
                child: Container(
                  color: Colors.black.withValues(alpha: 0.25),
                ),
              ),
            ],
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // ── 敵（左）─────────────────────────────────────
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // 【FEAT-385】Stack で sprite + Floating Damage を重ね描画。
                        // 攻撃時のエフェクトは BattleState.enemyAction / playerAction で
                        // 制御 (FEAT-300 既基盤の SpriteAction enum 経路を発火化)。
                        SizedBox(
                          width: 48,
                          height: 48,
                          child: Stack(
                            clipBehavior: Clip.none,
                            alignment: Alignment.center,
                            children: [
                              CombatantSprite(
                                spriteKey: state.enemy.spriteKey,
                                size: 48,
                                // 【FEAT-387 hotfix 2026-05-30】敵 sprite (enemy_*.png) は
                                // PixelLab で既に右向き生成済 (全 14 体)。FEAT-387 当初指示書で
                                // 「flipHorizontal: true で右向きに反転」と PM が誤指示した結果、
                                // 逆に左向き (味方から離れる) になり対峙構図が崩れていた。
                                // default false で元の右向きを維持 = 画面右の味方を見据える。
                                // attackDirection: right で charge が右に動く (BattlePage 整合)。
                                flipHorizontal: false,
                                attackDirection: AttackDirection.right,
                                action: state.status == BattleStatus.won
                                    ? SpriteAction.fadeOut
                                    : state.enemyAction,
                              ),
                              if (state.enemyDamageEvent != null)
                                Positioned(
                                  top: -8,
                                  child: FloatingDamageText(
                                    key: ValueKey(
                                        state.enemyDamageEvent!.timestamp),
                                    event: state.enemyDamageEvent!,
                                  ),
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          state.enemy.name,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 3),
                        // 【FEAT-384 (2026-05-29)】案 Z HP|ATB 一体型バー (敵側)。
                        // 【FEAT-403 (2026-06-01)】敵 ATB 廃止 + HP 全幅化。
                        //   旧: 左 50% HP / 右 50% ATB 一体型 (FEAT-384)。
                        //   新: 敵側 ATB は演出価値が薄いため非表示、HP が 100% 全幅で
                        //       「ボスを削る実感」を強化する。味方側は ATB 表示維持。
                        HpAtbCombinedBar(
                          combatant: state.enemy,
                          compact: true,
                          showAtb: false,
                        ),
                      ],
                    ),
                  ),
                  // ── 中央の交差アイコン ───────────────────────────
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 8),
                    child: Icon(
                      Icons.flash_on,
                      color: Colors.white38,
                      size: 14,
                    ),
                  ),
                  // ── 味方（右）───────────────────────────────────
                  Expanded(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Expanded(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              // 【FEAT-385】味方側 Stack で sprite + Floating Damage 重ね描画。
                              SizedBox(
                                width: 48,
                                height: 48,
                                child: Stack(
                                  clipBehavior: Clip.none,
                                  alignment: Alignment.center,
                                  children: [
                                    CombatantSprite(
                                      spriteKey: state.player.spriteKey,
                                      // 【FEAT-297 hotfix 2026-05-24】sprite は PixelLab で
                                      // left-facing 版を採用、flipHorizontal: false で sprite
                                      // 本来の左向き (西向き = 画面左の敵を見据える対面構図) 維持。
                                      // 【FEAT-387 (2026-05-30)】attackDirection: left で
                                      // charge が左に動く (BattlePage 整合)。
                                      flipHorizontal: false,
                                      attackDirection: AttackDirection.left,
                                      size: 48,
                                      action: state.status == BattleStatus.lost
                                          ? SpriteAction.fadeOut
                                          : state.playerAction,
                                    ),
                                    if (state.playerDamageEvent != null)
                                      Positioned(
                                        top: -8,
                                        child: FloatingDamageText(
                                          key: ValueKey(state
                                              .playerDamageEvent!.timestamp),
                                          event: state.playerDamageEvent!,
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 4),
                              // 【FEAT-299】キャラ名 + ジョブ名（小フォント、空なら名前だけ）。
                              Text.rich(
                                TextSpan(
                                  text: state.player.name,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 10,
                                    fontWeight: FontWeight.w600,
                                  ),
                                  children: [
                                    if (state.player.jobName.isNotEmpty)
                                      TextSpan(
                                        text: ' / ${state.player.jobName}',
                                        style: TextStyle(
                                          color:
                                              Colors.white.withValues(alpha: 0.6),
                                          fontSize: 9,
                                          fontWeight: FontWeight.w400,
                                        ),
                                      ),
                                  ],
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 3),
                              // 【FEAT-384】案 Z HP|ATB 一体型バー (味方側)。
                              HpAtbCombinedBar(
                                combatant: state.player,
                                compact: true,
                              ),
                              const SizedBox(height: 2),
                              // 【FEAT-384】凡例 (HP | ATB)、初心者向け視認性確保。
                              // 案 Z モック仕様準拠、味方下に 1 度だけ表示。
                              const HpAtbLegend(fontSize: 8),
                            ],
                          ),
                        ),
                        // 【FEAT-300】必殺ゲージ（小型、縦 ultCost マス）。
                        // sprite の右側に吸着配置（Gemini §1.2「必殺技ボタン横」風）。
                        Padding(
                          padding: const EdgeInsets.only(left: 4, right: 2),
                          child: UltGauge(
                            chargedCount: state.chargedSpecialCount,
                            ultCost:      state.player.ultCost,
                            compact:      true,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            // 【FEAT-298】右上に回復薬残数インジケータ（plan > 0 のときのみ表示）。
            const Positioned(
              top: 4,
              right: 8,
              child: PotionCountIndicator(compact: true),
            ),
            // 【FEAT-300】左上に作戦インジケータ（display only）。
            // Gemini §1.1「戦闘スタイル切り替えインジケーター」のミニマム反映。
            // 切替操作は全画面 BattlePage 側で実施する（本ビューは display only）。
            Positioned(
              top: 4,
              left: 8,
              child: _TacticIndicator(tactic: state.tactic),
            ),
          ],
        ),
      ),
    );
  }
}

/// 【FEAT-300】作戦インジケータ（display only、tap 不可）。
///
/// MiniBattleArena 左上に常駐し、ホーム画面のながら見でも「いま何重視か」
/// が一目で分かるようにする。切替操作は全画面 BattlePage 側で実施する。
class _TacticIndicator extends StatelessWidget {
  const _TacticIndicator({required this.tactic});

  final Tactic tactic;

  IconData get _icon => switch (tactic) {
        Tactic.offense          => Icons.local_fire_department,
        Tactic.recovery         => Icons.healing,
        Tactic.conserveUltimate => Icons.bolt,
      };

  Color get _color => switch (tactic) {
        Tactic.offense          => Colors.orangeAccent,
        Tactic.recovery         => Colors.greenAccent,
        Tactic.conserveUltimate => Colors.amberAccent,
      };

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Tooltip(
      message: tactic.localizedLabel(l10n),
      child: Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.30),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: _color.withValues(alpha: 0.5),
            width: 0.5,
          ),
        ),
        child: Icon(_icon, size: 14, color: _color),
      ),
    );
  }
}
