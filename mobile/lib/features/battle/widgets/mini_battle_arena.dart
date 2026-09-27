import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../constants/battle_constants.dart';
import '../models/battle_state.dart';
import '../models/tactic.dart';
import '../providers/battle_provider.dart';
import '../services/battle_haptics_service.dart';  // 【gameplay_review 20260803 要素 A-1】
import 'combatant_sprite.dart';
import 'floating_damage_text.dart';  // 【FEAT-385】Floating Damage 数値表示
import 'hp_atb_combined_bar.dart';   // 【FEAT-384】案 Z HP|ATB 一体型バー
import 'ko_effect_overlay.dart';    // 【FEAT-526】KO 演出 (額縁は縮小版)
import 'potion_count_indicator.dart';
import 'ult_gauge.dart';

/// MiniBattleArena 内の敵 / 味方 sprite の一辺 (logical px)。
///
/// 【2026-08-08 ユーザー要望】実機で「キャラが小さく感じる」との判断により拡大。
/// 旧 48 は全画面 [CombatantSprite] の既定 96 のちょうど半分だったが、額縁内で
/// 左右に ~145px の幅があるため余裕がある。**現在値はユーザーが実機で決めた値**
/// (48 → 60 → 100)。値そのものは本定数を見ること —— 文章側に数値を書くと
/// 次の微調整で必ず食い違う。
///
/// **HP / ATB / 必殺ゲージは対象外** —— ユーザー判断「ゲージの大きさは丁度良い」
/// により `compact: true` のまま据え置く。ここを触るとゲージまで連動して太るので、
/// 拡大したいのが sprite だけであるうちは**本定数だけ**を動かすこと。
///
/// 元アセットは 92x92 〜 1254x1254 とサイズがばらついており
/// (`combatant_sprite.dart` の `fit: BoxFit.contain` 参照)、**整数倍に揃っていない**。
/// したがって値を変えても nearest-neighbor の見え方が悪化することはない。
const double _kMiniSpriteSize = 100;

/// 【FEAT-297 Phase 1】WorldFrameSection 内に表示する戦闘ミニビュー。
///
/// レイアウト（Gemini 要件 §2 + 設計ノート §3.3 準拠）:
///   - 左 = 敵 / 右 = 味方 の対面構図
///   - sprite [_kMiniSpriteSize] 角（全画面 BattlePage の `_CombatantPanel` は 128）
///   - HP バー（細い、フォント 9-10）+ ATB ゲージ（高さ 3px）
///   - 作戦切替 UI は **本ビューに表示しない**（全画面 BattlePage 側で操作）
///   - 【FEAT-298】右上に PotionCountIndicator（plan > 0 のときのみ）
///
/// 戦闘なし時は `SizedBox.shrink()` で完全に消える（Pre-mortem #5 対応）。
///
/// `onTap` を渡すと WorldFrameSection 全体タップで BattlePage 遷移する。
///
/// 【2026-08-08 ユーザー要望】sprite サイズは [_kMiniSpriteSize] の 1 箇所で決まる。
/// 実機を見て微調整するときはこの定数だけを触ること。
class MiniBattleArena extends ConsumerStatefulWidget {
  const MiniBattleArena({super.key, this.onTap, this.onKoDone});

  /// タップで全画面 BattlePage 遷移。null ならタップ不可。
  final VoidCallback? onTap;

  /// 🔴 **KO 演出の後片付けが済んだことを親 (`WorldFrameSection`) に伝える。**
  ///
  /// 親は「戦闘中 = `status == running`」で額縁を出し入れしていたため、
  /// **とどめが入って `status` が `won` になった瞬間に本 widget ごと消えていた**。
  /// KO 演出は `koEvent` と同じ state 更新で始まるので、**演出が 1 フレームも
  /// 描かれないまま unmount される** —— 額縁の KO 演出が実機で一度も出なかった
  /// 真因である (2026-08-22 ユーザー報告)。
  ///
  /// そこで親は「決着後も、本 callback が来るまでは額縁を残す」に変えた。
  /// 引数は「どの `KoEvent` について終わったか」で、親はそれを記録して畳む。
  ///
  /// ⚠️ **build から呼ばない。** 呼ぶのは `ref.listen` の callback か
  /// 演出完了 callback からだけ (build 中の `setState` は例外になる)。
  final void Function(KoEvent event)? onKoDone;

  @override
  ConsumerState<MiniBattleArena> createState() => _MiniBattleArenaState();
}

class _MiniBattleArenaState extends ConsumerState<MiniBattleArena> {
  // ── 【FEAT-526 (2026-08-22 ユーザー確定)】額縁でも KO 演出を出す ────────
  //
  // 当初は「額縁は『ながら見』の前景で、習慣チェック中の邪魔になる」という理由で
  // バトル画面だけに限定していた (指示書 決定事項 2)。実機を見たユーザー判断で
  // **額縁でも出す**方針に変更。ただし全画面の値をそのまま使うと
  // 「K.O.」がはみ出し暗転もほぼ真っ黒になるため [KoEffectStyle.ambient] を使う。
  //
  // 🔴 **ambient のループ (`AmbientAutoBattleOrchestrator`) には一切触らない。**
  // 終了判定は `status` だけを見ており、本演出の完了を待たない。ここに待ち合わせを
  // 作ると **ホームのオートバトルが静かに止まる** (指示書 Pre-mortem #2)。
  // 本 widget が持つのは「自分が再生中か」だけで、共有 state には何も置かない。
  final KoEffectController _koEffect = KoEffectController();

  /// 自分が KO 演出を再生中か。敵の fadeOut を演出の後ろへ遅らせるのに使う。
  bool _koPlaying = false;

  /// 発火済みの `KoEvent` (二重発火防止)。
  ///
  /// `koEvent` は勝利後もクリアされないので、session が動くたびに判定が走る。
  KoEvent? _firedKoEvent;

  /// 演出が終わらなかったときの保険 Timer。
  ///
  /// 🔴 これが無いと、`whenComplete` が来ない事故 (dispose / vsync 停止など) で
  /// **額縁が世界の絵の上に出たまま戻らなくなる**。演出時間の 3 倍で強制的に
  /// 親へ「終わった」と伝える。
  Timer? _koFallbackTimer;

  void _maybeFireKo(BattleState? state) {
    if (!mounted || state == null) return;
    final event = state.koEvent;
    if (event == null || event == _firedKoEvent) return;
    _firedKoEvent = event;

    if (!_koEffect.fire(speedMultiplier: state.speedMultiplier)) {
      // overlay が居ない = 演出できない。**その場で親に返す** ——
      // 演出のために額縁を残し続けると世界の絵に戻れなくなる。
      widget.onKoDone?.call(event);
      return;
    }
    setState(() => _koPlaying = true);
    BattleHapticsService.instance.playKoFinish();

    _koFallbackTimer?.cancel();
    _koFallbackTimer = Timer(
      BattleConstants.koScaledTotal(state.speedMultiplier) * 3,
      () => _finishKo(event),
    );
  }

  /// **再生せずに**「この決着は自分の担当ではない」と親へ返す。
  ///
  /// 🔴 これが無いと **額縁が決着後の絵のまま世界に貼り付く** (2026-08-22 報告)。
  /// 親は「`onKoDone` が来るまで畳まない」ので、**演出を出さない経路でも
  /// 必ず返す**必要がある。返さない経路は以下の 2 つだった。
  ///
  /// | 経路 | 何が起きるか |
  /// |---|---|
  /// | 全画面が上に乗っている | `isCurrent` が false で listener が素通り |
  /// | 決着後に額縁が mount された | 状態遷移が無いので listener が呼ばれない |
  ///
  /// **再生しないのは正しい。** 決着済みの `koEvent` をここで再生すると
  /// 「前のバトルの KO が流れる」事故になる (battle_page で実際に起きた)。
  void _skipKo(KoEvent? event) {
    if (event == null || event == _firedKoEvent) return;
    _firedKoEvent = event;
    widget.onKoDone?.call(event);
  }

  @override
  void initState() {
    super.initState();
    // 決着**後**に額縁が組まれた場合、`ref.listen` は一度も呼ばれない
    // (自分が mount される原因になった state 変化は受け取れない)。
    // ここで拾って親に返さないと、額縁が出たまま戻らなくなる。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _skipKo(ref.read(battleSessionProvider).state?.koEvent);
    });
  }

  void _onKoFinished() {
    final event = _firedKoEvent;
    if (event != null) _finishKo(event);
  }

  /// 演出の後片付け。**2 経路 (正常完了 / 保険 Timer) から呼ばれるので冪等**。
  void _finishKo(KoEvent event) {
    _koFallbackTimer?.cancel();
    _koFallbackTimer = null;
    if (!mounted) return;
    if (_koPlaying) setState(() => _koPlaying = false);
    widget.onKoDone?.call(event);
  }

  @override
  void dispose() {
    _koFallbackTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
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
      if (!(ModalRoute.of(context)?.isCurrent ?? true)) {
        // 上に全画面 BattlePage が乗っている = 演出はそちらが出す。
        // 🔴 **黙って return してはいけない。** 額縁は「畳んでよい」と
        // 言われるまで残る仕組みなので、返さないと全画面から戻ったとき
        // **決着後の絵が世界に貼り付いたままになる** (2026-08-22 報告)。
        _skipKo(next.state?.koEvent);
        return;
      }

      // 【FEAT-526】とどめの一撃。必殺より先に判定する。
      _maybeFireKo(next.state);

      final nextUlt = next.state?.ultimateHitEvent;
      if (nextUlt != null && nextUlt != prev?.state?.ultimateHitEvent) {
        // 🔴 必殺技がとどめだった場合は打たない。`koFinish` の先頭に強い一撃が
        // 入っているので、2 つ重ねると濁るだけでとどめの重さは増えない。
        if (next.state?.status != BattleStatus.won) {
          BattleHapticsService.instance.playUltimateHit();
        }
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
        onTap: widget.onTap,
        // 【FEAT-526】KO 演出は額縁の中身だけを wrap する。
        // GestureDetector の内側に置くことで、演出中でもタップして
        // 全画面 BattlePage へ抜けられる (overlay は IgnorePointer)。
        child: KoEffectOverlay(
          controller: _koEffect,
          onFinished: _onKoFinished,
          style: KoEffectStyle.ambient,
          child: Stack(
            // 【2026-08-08 ユーザー要望】敵 / 味方の対面ブロックを額縁の中央高さへ下げる。
            //
            // Stack の既定 alignment は `AlignmentDirectional.topStart` で、
            // 非 Positioned な子 (下の `Padding` > `Row`) は**上端に貼り付く**。
            // 本 Stack は WorldFrameSection の `Positioned.fill` から tight 制約を
            // 受けて額縁いっぱいに広がるため、その差が「sprite が上寄り = 背景の
            // 地平線より上、空中に浮いて見える」状態として出ていた。
            //
            // `Positioned` な子 (回復薬インジケータ / 作戦インジケータ) は
            // alignment の影響を受けないので、上部の隅に残る。
            alignment: Alignment.center,
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
                            width: _kMiniSpriteSize,
                            height: _kMiniSpriteSize,
                            child: Stack(
                              clipBehavior: Clip.none,
                              alignment: Alignment.center,
                              children: [
                                CombatantSprite(
                                  spriteKey: state.enemy.spriteKey,
                                  size: _kMiniSpriteSize,
                                  // 【FEAT-387 hotfix 2026-05-30】敵 sprite (enemy_*.png) は
                                  // PixelLab で既に右向き生成済 (全 14 体)。FEAT-387 当初指示書で
                                  // 「flipHorizontal: true で右向きに反転」と PM が誤指示した結果、
                                  // 逆に左向き (味方から離れる) になり対峙構図が崩れていた。
                                  // default false で元の右向きを維持 = 画面右の味方を見据える。
                                  // attackDirection: right で charge が右に動く (BattlePage 整合)。
                                  flipHorizontal: false,
                                  attackDirection: AttackDirection.right,
                                  // 【FEAT-526】演出中は消さない (ズームする対象を残す)。
                                  // 閉じるのは **自分が再生中の間だけ** —— 前のバトルの
                                  // `koEvent` を見て待つと二度と消えなくなる。
                                  action: (state.status == BattleStatus.won &&
                                          !_koPlaying)
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
                                  width: _kMiniSpriteSize,
                                  height: _kMiniSpriteSize,
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
                                        // 【FEAT-527 (2026-08-22 訂正)】額縁でも攻撃フレームを出す。
                                        //
                                        // 当初は Pre-mortem #4 (バッテリー) を理由に false のまま
                                        // にしていたが、**前提が誤っていた**。`CombatantSprite` は
                                        // `_idleCtrl.repeat()` で**常時ティックし続けている**ので、
                                        // 「額縁は再描画が増えないから false」という理屈は成立しない。
                                        // `_frameCtrl` が回るのは charge の 400ms だけで、その間は
                                        // `_actionCtrl` / `_slashCtrl` が既に回っている。
                                        // 増える負荷は controller 1 本ぶんで、無視できる。
                                        enableMotion: true,
                                        size: _kMiniSpriteSize,
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
