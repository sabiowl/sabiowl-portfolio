import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/router/app_router.dart';                    // FEAT-297
import '../../../../core/theme/app_theme.dart';
import '../../../battle/models/battle_state.dart';                   // FEAT-297
import '../../../battle/providers/battle_provider.dart';             // FEAT-297
import '../../../battle/widgets/mini_battle_arena.dart';             // FEAT-297
import '../../../puzzle_world/providers/puzzle_world_provider.dart';  // 【FEAT-479 Phase 2d】
import '../../services/world_background_service.dart';  // 【FEAT-388 → v1 pivot】背景 path 定数のみ利用
import '../world_animated_layers/world_animated_layers.dart'; // 【FEAT-388 Phase 2】L2 軽量動き
import 'ambient_battle_overlays.dart';  // 【gameplay_review 20260803 §2-1】
import 'puzzle_grid_overlay.dart';
import 'world_frame_container.dart';
import 'world_frame_listeners.dart';

// ─────────────────────────────────────────────────────────────────────────────
// WorldFrameSection（ConsumerStatefulWidget）
// ─────────────────────────────────────────────────────────────────────────────

/// ホーム画面最上部に表示する「生きた世界」額縁アニメーション UI。
///
/// - 現在時刻に応じて朝・昼・夜の 3 種類のアセットを切り替える。
/// - Animated WebP（または GIF）を Image.asset で描画。
/// - filterQuality: FilterQuality.none でピクセルアートの輪郭をくっきり保つ。
/// - [worldFrameGlowProvider] が true になると額縁グロウアニメーションが発火する。
///
/// 【FEAT-209】長押しによるフルスクリーン没入演出は廃止。
/// 旧 `_pressCtrl` / `_isPressing` / `_hintCtrl` / プログレスリング /
/// 「長押しで世界へ」ヒントオーバーレイ / `WorldFrameFullscreenPage` 遷移を
/// すべて撤去し、ジェスチャー処理を持たない純粋な表示用ウィジェットに変更。
///
/// 【FEAT-487 (2026-07-08)】1077 LOC god class を 5 file に分割:
///  - `world_frame_section.dart` (本ファイル): main widget + state + build + resolver
///  - `world_frame_container.dart`: 額縁 UI (`WorldFrameContainer`)
///  - `puzzle_grid_overlay.dart`: パズル前景 (`PuzzleGridOverlay` + `PuzzleGridPainter`)
///  - `world_battle_end_modal.dart`: 戦闘終了モーダル (`showWorldBattleEndModal`)
///  - `world_frame_listeners.dart`: ref.listen 集約 (`WorldFrameListeners`、
///    FEAT-452/458/473 listener-only widget pattern 踏襲)
class WorldFrameSection extends ConsumerStatefulWidget {
  const WorldFrameSection({super.key});

  @override
  ConsumerState<WorldFrameSection> createState() => _WorldFrameSectionState();
}

class _WorldFrameSectionState extends ConsumerState<WorldFrameSection>
    with TickerProviderStateMixin {
  // ── 既存: グロウアニメーション ────────────────────────────────
  late final AnimationController _glowCtrl;
  late final Animation<double> _glowAnim;

  // ── 外枠アイドルグロウ（breathing pulse）─────────────────────
  late final AnimationController _idleGlowCtrl;
  late final Animation<double>   _idleGlowAnim;

  /// 額縁の KO 演出を「出し終えた」`KoEvent`。
  ///
  /// これと `state.koEvent` が一致するまでは、決着後でも額縁を残す
  /// (build の `koPending` 参照)。`MiniBattleArena` からしか更新されない。
  KoEvent? _koDoneFor;

  /// 子から「KO 演出の後片付けが済んだ」と伝えられた。
  ///
  /// ⚠️ 子の build 中には呼ばれない (`ref.listen` / 演出完了 callback からのみ)
  /// ので、ここで `setState` してよい。
  void _onKoDone(KoEvent event) {
    if (!mounted || _koDoneFor == event) return;
    setState(() => _koDoneFor = event);
  }

  @override
  void initState() {
    super.initState();

    // グロウアニメーション:
    //   急速に輝き（0→1, 200ms easeOut）→ 短い保持 → ゆっくり収束（1→0, 400ms easeIn）
    _glowCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _glowAnim = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween(begin: 0.0, end: 1.0)
            .chain(CurveTween(curve: Curves.easeOut)),
        weight: 33,
      ),
      TweenSequenceItem(
        tween: ConstantTween(1.0),
        weight: 7,
      ),
      TweenSequenceItem(
        tween: Tween(begin: 1.0, end: 0.0)
            .chain(CurveTween(curve: Curves.easeIn)),
        weight: 60,
      ),
    ]).animate(_glowCtrl);

    // ── 外枠アイドルグロウ（3.0 秒で明暗 1 往復・無限ループ）──────
    // 【バッテリー消費対策】1.5s → 3.0s に延長。微小な opacity 変化は
    // 30fps 相当でも視認不可能なほど滑らかで、60fps 描画は過剰品質。
    // 常駐ウィジェットの再描画コストを実質半減させる。
    _idleGlowCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3000),
    )..repeat(reverse: true);   // 0→1→0→1… と往復する
    _idleGlowAnim = CurvedAnimation(
      parent: _idleGlowCtrl,
      curve: Curves.easeInOut,  // 呼吸のようになだらかな加減速
    );
  }

  @override
  void dispose() {
    _idleGlowCtrl.dispose();
    _glowCtrl.dispose();
    super.dispose();
  }

  // ── アセットパス解決 ─────────────────────────────────────────────────────
  // 【FEAT-479 v1 pivot (2026-07-07)】時間帯連動背景 (FEAT-388) を撤廃。
  // 背景は「眠る世界」で設定した active/displayed scene のみで決定する。
  // 時間帯 rotation は「今取り組んでいる景色」というプロダクトミッションに
  // 反するため廃止 (旧: 朝/昼/夕/夜/rest_day/levelUp 6 状態 8 画像 rotation)。

  /// 【FEAT-479 Phase 4c (2026-07-06)】背景 path + アニメ有効フラグを返す。
  ///
  /// 指示書 §4.3.3 step 4: 完成後は WorldAnimatedLayers 起動 (完成後は永続表示)。
  /// パズル導入以降は「完成前は世界一切動かない」が Ver1 要件 (Pre-mortem S4)。
  ///
  /// アニメ有効条件:
  /// - displayed_scene が history に完成記録あり → true
  /// - displayed_scene 未設定かつ active_scene が完成済 → true
  /// - 上記以外 (未完成 / fallback / onboarding 前) → false
  ///
  /// 【FEAT-479 v1 pivot (2026-07-07) → 2026-07-09 bug fix】表示 branch 4 段:
  /// - (A0)【2026-07-09 追加】displayed が active と異なる scene に明示 override
  ///        されている場合、user 意図として最優先で displayed を装飾表示。
  ///        Backend の select_active_scene は auto-sync (displayed == previous_active
  ///        なら追従) をするため、displayed != active となる = user が明示的に
  ///        SceneSelectionPage「ホームに表示」で override した signal。
  /// - (A) active 未完成 → active を額縁に強制表示 + pieces overlay
  ///        (通常経路、user は継続作業中で displayed も active に自動同期されている)
  /// - (B) active 完成 or 未設定 → displayed_scene を装飾用に表示 (overlay 無し)
  /// - (C) いずれも解決できない → morning_grassland (目覚めの山頂) 固定 + [0,0,0]
  ///       overlay (通常経路は Backend GET auto-activate で (A) が発火するため、
  ///       本経路は puzzleStatus fetch 失敗等の edge case のみ)
  /// 【hybrid hotfix 2026-07-07】返却型に `monoPath` を追加。
  /// piece overlay (state=1 セル切り抜き用モノクロ画像 path) を caller に伝達。
  /// null = mono asset 未登録シーン (`WorldBackgroundService.monoPathForBackgroundKey`
  /// が該当 case を持たない場合)。
  ({String path, String? monoPath, bool animated, List<int>? pieceStates})
      _resolveSceneRender() {
    final puzzleStatus = ref.watch(puzzleWorldStatusProvider).valueOrNull;
    final active    = puzzleStatus?.activeScene;
    final displayed = puzzleStatus?.displayedScene;

    // (A0)【2026-07-09 bug fix】user 明示 displayed override を最優先。
    //
    // 【症状】user 報告: 「昼の城下町を再生中の状態で目覚めの山頂を『ホームに表示』
    //   にしたのに、ホーム画面は昼の城下町のまま」。
    // 【原因】旧 (A) は active 未完成なら active を最優先 → displayed 選択を無視。
    // 【修正】displayed != active = user 意図的 override signal → 最優先で表示。
    //   完成 scene なら animation on (完成景色は常にアニメ)、未完成 scene が
    //   displayed に来ることは Backend で禁止済 (未着手のみ拒否、完成 or active 許可)。
    if (displayed != null && active != null && displayed.key != active.scene.key) {
      final path = WorldBackgroundService.pathForBackgroundKey(displayed.backgroundKey);
      if (path != null) {
        final completed = puzzleStatus!.history.any((h) => h.sceneKey == displayed.key);
        // user 意図 override 表示 = 装飾モード (overlay 無し)。
        // 進捗確認は SceneSelectionPage / SceneDetail で行う。
        return (path: path, monoPath: null, animated: completed, pieceStates: null);
      }
    }

    // (A) アクティブが未完成なら、それを最優先で表示 + pieces overlay
    //     (displayed は auto-sync で active と同一なので上の A0 は通過してここに来る)
    if (active != null && !active.isCompleted) {
      final path = WorldBackgroundService.pathForBackgroundKey(active.scene.backgroundKey);
      final monoPath = WorldBackgroundService.monoPathForBackgroundKey(active.scene.backgroundKey);
      if (path != null) {
        return (
          path: path,
          monoPath: monoPath,
          animated: false,  // 未完成中は静止 (指示書 §4.3.3 Pre-mortem S4)
          pieceStates: active.pieceStates,
        );
      }
    }

    // (B) 装飾モード: displayed 明示選択があれば優先、無ければ完成済 active
    if (displayed != null) {
      final path = WorldBackgroundService.pathForBackgroundKey(displayed.backgroundKey);
      if (path != null) {
        final completed = puzzleStatus!.history.any((h) => h.sceneKey == displayed.key);
        // 装飾モードは overlay 描画しない (pieceStates null) ため monoPath 不要。
        return (path: path, monoPath: null, animated: completed, pieceStates: null);
      }
    }
    if (active != null) {
      final path = WorldBackgroundService.pathForBackgroundKey(active.scene.backgroundKey);
      if (path != null) {
        return (
          path: path,
          monoPath: null,
          animated: active.isCompleted,
          pieceStates: null,
        );
      }
    }

    // (C) Default fallback: morning_grassland (目覚めの山頂) 固定 + [0,0,0] overlay。
    //
    // 通常経路: Backend の PuzzleWorldStatusView が GET 時に silent auto-activate
    // (morning_grassland) を発火するため、(A) が必ずヒットする。本経路は以下の
    // edge case のみ:
    //   - puzzleStatus fetch 失敗 (5xx / network 断)
    //   - Backend seed 未反映 (migration 0175/0178 未適用)
    //   - Backend 未 deploy (旧クライアント → 新サーバー移行過渡期)
    // これらでも overlay を表示して「かけらがすべて揃った状態」に見える bug を回避。
    final defaultPath = WorldBackgroundService.pathForBackgroundKey('morning_grassland')
        ?? WorldBackgroundService.kFallbackPath;
    final defaultMonoPath =
        WorldBackgroundService.monoPathForBackgroundKey('morning_grassland');
    return (
      path: defaultPath,
      monoPath: defaultMonoPath,
      animated: false,
      pieceStates: const [0, 0, 0],
    );
  }

  // 【FEAT-479 Phase 4c (2026-07-06)】旧 _resolveAssetPath() は _resolveSceneRender() に
  // 統合済 (path + animated フラグを同時解決するため)。単独呼出箇所は削除済。

  // ── Phase 2: L2 軽量動きレイヤー factory (path で 8 シーン分岐) ─────────────

  /// 【新規 (2026-06-26)】背景画像 [Image.asset(bgPath)] の **奥** に描画する
  /// レイヤーを返す。
  ///
  /// 城下町シーン (noon_castle_town) のように背景 PNG の上部が透過になっている
  /// シーンでは、透過部分から見える「奥の空 + 流れる雲」を本スロットで描画する。
  /// 一般シーン (背景 PNG が全面不透過) では SizedBox.shrink で no-op。
  ///
  /// 拡張性: 朝焼け / 夜空の星 / 月などの「天体・空」演出を将来追加する場合も
  /// 本スロットを使い、背景 PNG の透過部分から見える構成にする。
  Widget _resolveBackgroundLayer(String path) {
    if (path.contains('noon_castle_town')) {
      return const NoonCastleTownBackground();
    }
    // 【2026-07-05 修正 → v1 hotfix 2026-07-07】目覚めの山頂シーン (旧 朝の草原、
    // world_sunrise.png、旧 world_morning_grassland.png) は空エリアが
    // 完全に不透明 (紫グラデ + 星が描き込み済) のため、noon_castle_town の
    // 「背後透過」パターンが使えない。雲は _resolveAnimatedLayer 側で
    // world image の**手前**に描画する (下記 sunrise 分岐参照)。
    return const SizedBox.shrink();  // 他シーンは奥レイヤー不要
  }

  /// 【FEAT-388 Phase 2 (2026-05-30)】背景 path に応じた L2 軽量動きレイヤーを返す。
  ///
  /// 背景画像の **手前** に描画される動的レイヤー (旗、必殺技、天候等)。
  /// 各 widget は RepaintBoundary で囲まれて呼ばれる。
  /// 画像が未配置で path が fallback の場合は SizedBox.shrink で no-op。
  ///
  /// 【新規 (2026-06-25)】森のキャンプは kCampSceneAnimated=false のとき
  /// SizedBox.shrink (静止、L1 のみで完結)。true のとき CampScene が L2-L5。
  /// 【更新 (2026-06-26)】城下町の旗は撤去 + 雲は奥レイヤー (_resolveBackgroundLayer)
  /// へ移動。NoonCastleTownLayers は将来の前景アニメ拡張用の空 placeholder。
  Widget _resolveAnimatedLayer(String path) {
    // 【FEAT-479 v1 pivot (2026-07-07)】時間帯連動廃止に伴い、evening_grassland /
    // night_lighthouse / night_owl_library / night_tavern / night_snowy_cabin の
    // 5 シーン分岐を撤去。puzzle_world seed は morning_grassland (sunrise) /
    // noon_castle_town / night_forest_camp の 3 シーンのみで、他 path は生成
    // されない (Backend の PuzzleWorldScene master に無い)。
    //
    // 目覚めの山頂シーン: 雲のみ描画 (cloud_layer_3/4 の視差スクロール +
    // ±1.5px sin 波揺れ + 起動時ランダム位相)。
    // widget class 名 MorningGrasslandBackground は互換のため据置。
    if (path.contains('sunrise')) {
      return const MorningGrasslandBackground();
    }
    if (path.contains('noon_castle_town'))     return const NoonCastleTownLayers();
    if (path.contains('night_forest_camp')) {
      return kCampSceneAnimated
          ? const NightForestCampLayers()  // facade → CampScene 委譲
          : const SizedBox.shrink();        // 静止モード: アニメ無し
    }
    return const SizedBox.shrink();  // fallback: 動きなし
  }

  @override
  Widget build(BuildContext context) {
    // 【FEAT-297】戦闘進行状態を監視。running 中は MiniBattleArena をオーバーレイ。
    // 戦闘終了 (won/lost/abandoned) 後はオーバーレイを外し、時間帯 WebP に戻る。
    final session = ref.watch(battleSessionProvider);
    // 🔴 **決着した瞬間に額縁を畳んではいけない** (2026-08-22 ユーザー報告)。
    //
    // 旧実装は `status == running` だけを見ていた。ところが KO 演出は
    // **`status` が `won` になるのと同じ state 更新**で始まる。つまり演出の
    // 開始と同時に `MiniBattleArena` ごと unmount され、**額縁の KO 演出は
    // 一度も描かれなかった** (FEAT-526 の額縁対応が実機で効いていなかった真因)。
    //
    // ここでは「まだ後片付けが終わっていない `KoEvent` があるか」を見る。
    // 終わったかどうかは `MiniBattleArena` が [MiniBattleArena.onKoDone] で
    // 教えてくる —— **子が「もう畳んでよい」と言うまで残す**。
    //
    // 順序に依存しない: 決着フレームでは `_koDoneFor` はまだ古いままなので
    // 必ず残る。子の listener が先に走ろうが後に走ろうが結果は変わらない。
    //
    // 敗北 (`lost`) は `koEvent` が立たない (演出が無い) ので、従来どおり
    // その場で畳まれる。
    final battleState = session.state;
    final koPending = battleState?.koEvent != null
        && battleState!.koEvent != _koDoneFor;
    final inBattle = battleState != null
        && (battleState.status == BattleStatus.running || koPending);

    // 【FEAT-487 (2026-07-08)】旧 ref.listen 3 系統 (worldFrameGlowProvider /
    // battleSessionProvider / auto-startBattle inline check) は全て
    // `WorldFrameListeners` (world_frame_listeners.dart) に集約。
    // Pre-mortem #4 対応: 本 `build` 内から `ref.listen` を完全撤去、
    // grep で `ref.listen` が 0 件になる状態を維持する。

    // ── 静的コンテンツ（毎フレーム再 build しない部分）──────────────────────
    // 【バッテリー消費対策】Image.asset と下部フェードはグロウ値に依存しないため、
    // AnimatedBuilder の `child` パラメータに渡して、アニメーションフレーム毎の
    // 再 build から除外する。これにより画像デコード参照とグラデーション計算を
    // 60fps 走らせる必要がなくなる。
    // 【FEAT-479 Phase 4c (2026-07-06)】背景 path + アニメ有効フラグを同時解決。
    // アニメ無効時 (完成前 / onboarding 未完了 / fallback) は L0/L2 layer を
    // SizedBox.shrink() に差替 (指示書 §4.3.3 step 4: 完成後は永続表示、
    // Pre-mortem S4: 完成前は世界一切動かない)。
    final resolved = _resolveSceneRender();
    final bgPath = resolved.path;
    final showAnimatedLayers = resolved.animated;
    // 【FEAT-479 hotfix (2026-07-06)】未完成シーンではピース枠線をワールドフレーム内に
    // オーバーレイ表示 (完成前は「かけら」の輪郭でパズル進捗を可視化)。
    // pieceStates が null (fallback / 完成済) の場合は overlay を描画しない。
    final pieceStates = resolved.pieceStates;
    // 【hybrid hotfix 2026-07-07】mono path が非 null なら state=1 セルにモノクロ
    // 画像を切り抜き描画、state=2 セルにはカラー (bgPath) を切り抜き描画する。
    final monoPath = resolved.monoPath;

    final staticContent = AspectRatio(
      // 【FEAT-209】縦幅を 1.4 倍に拡大（2.0 / 1.4 ≈ 1.43）して額縁内の表示範囲を広げる。
      // 旧 2.0:1（高さ約 187px）→ 新 1.43:1（高さ約 261px）。
      aspectRatio: 1.43,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // ── L0: 奥アニメ層 (背景画像より奥、透過部分から透ける) ───────────
          // 【新規 (2026-06-26)】noon_castle_town 等、背景 PNG の上部が透過
          // しているシーンで sky.png + 流れる雲 を奥に配置する経路。
          // 他シーンでは SizedBox.shrink (no-op)。
          // 【FEAT-479 Phase 4c】完成後のみ描画 (完成前は静止画のみ、
          // 個別 widget を touch せず caller で分岐、最小侵襲)。
          RepaintBoundary(
            child: showAnimatedLayers
                ? _resolveBackgroundLayer(bgPath)
                : const SizedBox.shrink(),
          ),

          // ── L1: 背景画像 (FEAT-388: 8 パターン、errorBuilder でフォールバック) ──
          Image.asset(
            bgPath,
            fit: BoxFit.cover,
            // ピクセルアートはバイリニア補間を無効化してドット感を保つ
            filterQuality: FilterQuality.none,
            errorBuilder: (context, _, __) {
              // Pre-mortem #1 対応: 画像未配置時は夕フォールバック画像、
              // それも未配置なら _WorldFramePlaceholder (プレースホルダ)。
              if (bgPath != WorldBackgroundService.kFallbackPath) {
                return Image.asset(
                  WorldBackgroundService.kFallbackPath,
                  fit: BoxFit.cover,
                  filterQuality: FilterQuality.none,
                  errorBuilder: (_, __, ___) => const WorldFramePlaceholder(),
                );
              }
              return const WorldFramePlaceholder();
            },
          ),
          // ── L2 軽量動きレイヤー (FEAT-388 Phase 2、path で分岐) ─────────
          // 【FEAT-388 Phase 2】各背景に揺らぎレイヤーを RepaintBoundary で重ねる。
          // 30fps 制限 + App lifecycle で background 時 stop (Pre-mortem #5 対応)。
          // 【FEAT-479 Phase 4c】完成後のみ描画 (完成前は静止画のみ、
          // Pre-mortem S4: パズル導入で「完成前は世界一切動かない」)。
          RepaintBoundary(
            child: showAnimatedLayers
                ? _resolveAnimatedLayer(bgPath)
                : const SizedBox.shrink(),
          ),

          // ── L3: パズルピース枠線 overlay (FEAT-479 hotfix、2026-07-06 →
          // hybrid hotfix 2026-07-07) ─────────────────────────────────────
          // 未完成シーンでは 3×1 (目覚めの山頂) or 6×5 grid のピース輪郭を描画。
          // state=0 (未取得): 暗い overlay (下 L1 を隠す)
          // state=1 (輪郭)  : mono 画像を該当セルに切り抜き描画 (下 L1 を隠す)
          // state=2 (彩り)  : color 画像を該当セルに切り抜き描画 (下 L1 と同じだが
          //                    セル境界がハッキリして「収穫感」を演出)
          // 【hybrid hotfix 2026-07-07】ResizeImage で 512×360 に decode し
          // メモリ最適化 (2 画像で ~1.5MB、フルサイズだと ~32MB)。
          // 完成済 or pieceStates=null (fallback) は SizedBox.shrink で無 op。
          // 【FEAT-513 v1.1 hotfix 2026-07-31】バトル中 (auto / 手動 共通) は
          // puzzle grid を非表示にする (user 報告: バトル中もマス目が見える)。
          // MiniBattleArena 上位 Stack で render されるが、枠線 (alpha 0.45) が
          // 敵背景 (WebP) を透過して見えるため battle 演出の没入感を損なう。
          // 戦闘終了で inBattle=false → grid 復活 (「元に戻す」原則維持)。
          if (pieceStates != null && !inBattle)
            IgnorePointer(
              child: PuzzleGridOverlay(
                pieceStates: pieceStates,
                monoPath: monoPath,
                colorPath: bgPath,
              ),
            ),

          // ── 下部フェードオーバーレイ（常時・静的）─────────────────
          // コンテンツ下のカードへ自然に溶け込ませる
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Container(
              height: 36,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.transparent,
                    AppTheme.surface.withValues(alpha: 0.85),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );

    // 【バッテリー消費対策】RepaintBoundary でホーム画面の他レイヤーへの
    // 再描画波及を遮断する。WorldFrameSection 内部の repaint が
    // 親 ListView やサビメッセージパネルに連鎖しなくなる。
    // 【FEAT-487】WorldFrameListeners で全 ref.listen を包む (listener-only widget pattern)。
    // 【FEAT-513】Column で額縁 + Ambient Auto Battle インジケーターを縦積み。
    // 【FEAT-513 v1.1 hotfix 2026-07-31】countdown を WorldFrame 内 (Stack 上部
    // に Positioned.fill overlay) に表示。user 期待「countdown はワールドフレーム
    // 内で表示」に alignment (旧: WorldFrame の下 = Column child bottom)。
    // Stack fit: passthrough で frame の AspectRatio に size 追従。
    // countdown null 時は IgnorePointer(SizedBox.shrink) = frame tap 妨げ 0。
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
    Stack(
      fit: StackFit.passthrough,
      children: [
    WorldFrameListeners(
      onGlowTriggered: () {
        if (!mounted) return;
        _glowCtrl.forward(from: 0.0);
      },
      child: RepaintBoundary(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 12, 8, 4),
          child: AnimatedBuilder(
            animation: Listenable.merge([_glowAnim, _idleGlowAnim]),
            // staticContent を child として渡し、フレーム毎の再生成を回避
            child: staticContent,
            builder: (context, child) {
              final glowIntensity = _glowAnim.value;
              final idleGlowValue = _idleGlowAnim.value;
              final hasActiveGlow = glowIntensity > 0.01;

              // ── キャラ光当たりオーバーレイは active glow 時のみ生成 ──────
              // アイドル時は staticContent をそのまま使うことで Stack 再生成を回避
              Widget innerContent = child!;
              if (hasActiveGlow) {
                // 【BUG-60】StackFit.expand を削除（= StackFit.loose 既定）。
                // staticContent (= child) は内部に AspectRatio を持っており、
                // AspectRatio が「loose 制約で受け取った w=344 から h=240 を自己算出」する
                // ことに依存している。StackFit.expand を付けると Stack が children に
                // BoxConstraints.tight(Size(344, ∞)) を強制し、AspectRatio が無限高さ
                // assertion で停止 → アプリフリーズ（FEAT-224 リグレッション）。
                //
                // StackFit.loose（デフォルト）の挙動:
                //   1. 非 Positioned 子（AspectRatio）に loose 制約（w=0..344, h=0..∞）を渡す
                //   2. AspectRatio が w=344, h=344/1.43≈240 を自己決定
                //   3. Stack が 344×240 を採用
                //   4. Positioned.fill が 344×240 を fill する
                innerContent = Stack(
                  children: [
                    child,
                    // ── キャラクター光当たりオーバーレイ（グロウ時のみ）──────
                    // キャラクター位置（左寄り）にラジアルグラデーション
                    Positioned.fill(
                      child: Opacity(
                        opacity: (glowIntensity * 0.30).clamp(0.0, 1.0),
                        child: const DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: RadialGradient(
                              // キャラクターが配置される左下エリアの中心付近
                              center: Alignment(-0.3, 0.15),
                              radius: 0.65,
                              colors: [
                                Colors.white,
                                Colors.transparent,
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                );
              }

              // 【FEAT-297】戦闘中は MiniBattleArena をオーバーレイ表示。
              // 既存 WorldFrameContainer のレイアウト計算には影響させない
              // （Stack の Positioned.fill で内側に重ねる）。
              final frame = WorldFrameContainer(
                glowIntensity: glowIntensity,
                idleGlowValue: idleGlowValue,
                child: innerContent,
              );
              // 【FEAT-479 hotfix (2026-07-06)】非戦闘中は WorldFrame タップで
              // 「眠る世界」画面 (SceneSelectionPage) へ遷移。ホームから直接
              // シーン選択に導線を作り、進捗操作を 1 タップに短縮。
              // 戦闘中は既存の MiniBattleArena onTap (context.push('/battle'))
              // を優先するため、GestureDetector は追加しない。
              if (!inBattle) {
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => context.push(AppRoutes.puzzleWorld),
                  child: frame,
                );
              }
              return Stack(
                fit: StackFit.passthrough,
                children: [
                  frame,
                  // 半透明黒で時間帯 WebP を暗くし、戦闘演出を視認しやすくする
                  Positioned.fill(
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.55),
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ),
                  Positioned.fill(
                    child: MiniBattleArena(
                      onTap: () => context.push(AppRoutes.battle),
                      onKoDone: _onKoDone,
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    ),
        // 【FEAT-513 v1.1 hotfix 2026-07-31】countdown overlay を frame 上に配置。
        // Padding は WorldFrameListeners 内 (fromLTRB(8, 12, 8, 4)) と揃え、
        // frame content area のみに dark backdrop がかかるようにする (frame 外の
        // 白色 padding 領域まで暗くしない)。countdown null 時は
        // IgnorePointer(SizedBox.shrink) で tap 透過。
        // 【gameplay_review 20260803 §2-1】overlay 本体は
        // `ambient_battle_overlays.dart` に切り出し済 (契約テストを書けるように
        // するため。旧構造では額縁ごと build しないと countdown を検査できず、
        // ambient 系テスト 7 本はすべて orchestrator 単体だった)。
        const Positioned.fill(
          child: Padding(
            padding: EdgeInsets.fromLTRB(8, 12, 8, 4),
            child: AmbientBattleCountdownOverlay(),
          ),
        ),
      ], // 内側 Stack children 終端
    ),
    // 【FEAT-513】Ambient Auto Battle 待機インジケーター (frame 下部)。
    const AmbientBattleStatusIndicator(),
    ], // Column children 終端
    );
  }
}

