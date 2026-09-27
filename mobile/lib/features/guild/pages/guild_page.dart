import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';  // 【FEAT-505】

import '../../../l10n/app_localizations.dart';

import '../../../core/analytics/posthog_service.dart';  // 【FEAT-513】
import '../../../core/router/app_router.dart';        // 【SEC-12】Shop 遷移用 AppRoutes
import '../../../core/theme/app_theme.dart';
import '../../../shared/widgets/sabi_loading_skeleton.dart';  // 【FEAT-482】SabiWaitingPanel
import '../../battle/constants/battle_constants.dart';  // 【FEAT-295 hotfix 2026-05-25】残必要回数表示
// 【FEAT-513 v1.1 hotfix 2 follow-up (2026-07-31)】旧 skip_confirm_dialog import
// (FEAT-505) は _onSkipBattle 撤去に伴い削除。同様に battle_service の
// DailyBattleLimitReachedException import も撤去 (旧 _onSkipBattle catch 専用)。
import '../../battle/models/enemy.dart';                // 【FEAT-296】
import '../../battle/providers/battle_provider.dart';   // 【FEAT-296 / FEAT-513】
import '../../battle/services/ambient_auto_battle_preferences.dart'; // 【FEAT-513】
import '../../battle/widgets/battle_pre_start_sheet.dart'; // 【FEAT-298】
import '../../battle/widgets/battle_settings_dialog.dart'; // 【FEAT-528】
import '../../battle/widgets/party_edit_dialog.dart';     // 【FEAT-304】
import '../widgets/guild_drawer.dart';                    // 【2026-07-05】ハンバーガーメニュー
import '../widgets/guild_reception_view.dart';            // 【FEAT-305】
import '../widgets/sabi_guild_onboarding_flow.dart';     // 【FEAT-512】
// 【FEAT-297 後続 hotfix 2026-05-24】BattleWidget の import を削除。
// ユーザー要望「他のボス（ゴブリンキング / シャドウメイジ等）と同じような枠」に
// 応じて、ゴブリンを _BossQuestList に統合する設計に変更（Option B 採用）。
// BattleWidget ファイル自体は battle/widgets/battle_widget.dart に残置（将来別所
// で再利用する可能性のため、撤去ではなく未参照化）。チケットゲージ表示は
// ホーム AppBar 盾バッジ + 各 _BossQuestCard の disabled 状態で代替。
import '../../habits/providers/habits_provider.dart';   // playerNotifierProvider
import '../../habits/providers/home_bootstrap_provider.dart'; // FEAT-442: pull-to-refresh

/// 【FEAT-207】ギルド画面（GuildPage）
///
/// 「習慣の成果を試す出撃エリア」として、ボス討伐・装備変更の経路を提供する。
/// 旧 QuestPage（報酬の二重抽象でレビュー上削除推奨だった）を本画面にリブランディング
/// することで、ナビゲーション枠を活かしつつ「習慣 → ゲーム的成果」の体験価値を生む。
///
/// 設計方針:
/// - **レトロドット絵 RPG 風**: 角丸控えめ + 2px のシャープな枠線 + 矩形 HP ゲージ
/// - **キャラ画像は active_character を動的表示**（オンボーディングで選んだキャラを尊重）
/// - **状態管理はモック**（StatefulWidget + ハードコード）。本実装は将来 FEAT で
///   Equipment / Boss モデル + Riverpod 化を計画
class GuildPage extends ConsumerStatefulWidget {
  const GuildPage({super.key});

  @override
  ConsumerState<GuildPage> createState() => _GuildPageState();
}

class _GuildPageState extends ConsumerState<GuildPage> {
  @override
  void initState() {
    super.initState();
    _loadAmbientAutoBattleEnabled();
  }

  /// 【FEAT-513 v1.1 hotfix 2 follow-up (2026-07-31)】旧 `_loadSkipMode` は
  /// FEAT-505 の skipModeProvider + ambientAutoBattleEnabledProvider 両方を
  /// 読み込んでいたが、skipModeProvider 撤去に伴い ambient auto battle 専用に
  /// リネーム。SharedPreferences から Ambient Auto Battle 有効フラグを Provider に
  /// 反映する (Guild toggle 用の初期化)。
  Future<void> _loadAmbientAutoBattleEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    ref.read(ambientAutoBattleEnabledProvider.notifier).state =
        AmbientAutoBattlePreferences.isEnabled(prefs);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      backgroundColor: AppTheme.surface,
      appBar: AppBar(
        backgroundColor: AppTheme.surface,
        title:           Text(l10n.guildPageTitle),
        centerTitle:     true,
        // 【2026-07-05】旧: 編成・装備アイコン + ショップアイコン の 2 アイコン
        // 直配置 → ハンバーガーメニュー 1 アイコンに集約。GuildDrawer (endDrawer)
        // で 6 項目 (ステータス / 装備・編成 / 所持品リスト / ショップ / フレンド /
        // お知らせ) に整理し、AppBar の視覚ノイズを削減しつつ動線を拡張。
        // 【FEAT-528 (2026-08-23)】バトル設定を AppBar の actions に置く。
        // 設定は「この画面の操作」なので leading (= iOS では戻るの場所) ではなく
        // actions が規約。ハンバーガーの左に並べる。
        actions: [
          const GuildBattleSettingsAction(),
          Builder(
            builder: (ctx) => IconButton(
              icon:      const Icon(Icons.menu),
              tooltip:   l10n.guildPageMenuTooltip,
              onPressed: () => Scaffold.of(ctx).openEndDrawer(),
            ),
          ),
        ],
      ),
      // 【2026-07-05】endDrawer に GuildDrawer を配置。onOpenPartyEdit
      // コールバックで既存の _openPartyEditDialog を再利用 (BUG-65 系
      // dialog 内 navigation race 回避のため context 選択は本 page 側に委譲)。
      endDrawer: GuildDrawer(
        onOpenPartyEdit: () => _openPartyEditDialog(context),
      ),
      // 【FEAT-306】Stack 化 → 背景画像（ギルド受付木造内装）+ 暗化オーバーレイ +
      // コンテンツ層（リリア + ボスリスト）の 3 層構造。背景画像 未配置時は
      // errorBuilder で AppTheme.surface 単色 fallback（サイレント）。
      // 【FEAT-306 案 C 修正 2026-05-25】
      // 画面レベルの Stack 撤去 → 背景画像配置を GuildReceptionView 内に閉じ込め。
      // ボスリスト領域は AppTheme.surface（Scaffold.backgroundColor）で従来通り。
      body: Column(
        children: [
          // ── 最上部: ギルド受付（リリア + 吹き出し UI、画面 25%） ──
          // 【FEAT-305 + FEAT-306 案 C】Gemini guild_register.md 完全実装。
          // 背景画像 guild_reception_2.png は本 widget 内の Stack で配置（案 C 採用）。
          // 結果として「BOTTOM OVERFLOWED BY 26 PIXELS」エラーも _GuildHeader 撤廃で解消済。
          const GuildReceptionView(),
          // 【FEAT-528 (2026-08-23)】旧 AutoBattleBar (FEAT-513) はここにあったが撤去。
          // オートバトルの ON/OFF はバトル設定モーダルへ移した。
          // 🔵 ON かどうかは **各クエストカードの参加回数スピナー** で分かる
          // (`_PresetCountRow` は `autoEnabled` のときだけ描かれる)。トグルより
          // 情報量が多く、その場で回数まで設定できる。
          // ── 下部: 敵一覧（zako + boss、スクロール） ──
          // 案 C: 背景画像は配置せず、Scaffold.backgroundColor (AppTheme.surface) で
          // 従来通りの暗背景。_BossQuestCard 個別 UI で十分の視認性。
          const Expanded(
            child: _BossQuestList(),
          ),
        ],
      ),
    );
  }

  /// 【FEAT-304】PartyEditDialog (中央 dialog、フェード + スケール 200ms)。
  ///
  /// `showGeneralDialog` で root navigator に push (`useRootNavigator: true`)、
  /// builder の `dialogContext` を `onClose` callback 経由で渡すことで
  /// CLAUDE.md「ShellRoute 配下での Navigator.pop コンテキスト分離 FEAT-215」
  /// に準拠 (内側 context での pop は親 ShellRoute を pop してしまうリスク回避)。
  ///
  /// dialog 内では navigation 一切しない (閉じるのみ) ので BUG-65 系の defunct
  /// race も発生しない (Pre-mortem #1)。
  void _openPartyEditDialog(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    showGeneralDialog<void>(
      context:           context,
      barrierDismissible: true,
      barrierLabel:      l10n.guildPageDrawerBarrierLabel,
      barrierColor:      Colors.black54,
      transitionDuration: const Duration(milliseconds: 200),
      pageBuilder: (dialogContext, __, ___) => PartyEditDialog(
        onClose: () => Navigator.of(dialogContext).pop(),
      ),
      transitionBuilder: (_, animation, __, child) => ScaleTransition(
        scale: CurvedAnimation(parent: animation, curve: Curves.easeOut),
        child: FadeTransition(opacity: animation, child: child),
      ),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// 【FEAT-306】Phase 2 の _GuildHeader / _BattleReadyIndicator / _CharacterPlaceholder /
// _EquipmentSlot は完全撤廃。HP/Lv/EXP/coins/diamonds 等の状態確認は
// PartyEditDialog (FEAT-304 + FEAT-306 で _StatusSection 拡張) で行う動線に統合。
// 旧実装は ~430 LOC、dead UX + "BOTTOM OVERFLOWED BY 26 PIXELS" overflow バグの
// 温床だったため物理削除（同時に副次バグ解消）。
// ═════════════════════════════════════════════════════════════════════════════


// ═════════════════════════════════════════════════════════════════════════════
// Phase 3: _BossQuestList + _BossQuestCard — 下部ボス一覧
// ═════════════════════════════════════════════════════════════════════════════

// 【FEAT-296 / FEAT-302】tier ごとの装飾色。
// 【FEAT-302】mid_boss = オレンジ / hidden_boss = 紫 を追加（段階解放の視覚的識別）。
const _kTierColors = <String, Color>{
  'zako':        Color(0xFF7DDA58),
  'mid_boss':    Color(0xFFF59E0B),
  'boss':        Color(0xFFEF4444),
  'hidden_boss': Color(0xFF9C27B0),
};

Color _colorForEnemy(EnemyMaster enemy) {
  // key で個別色も対応（既存モックの色設計を踏襲、視覚的に区別しやすくする）
  switch (enemy.key) {
    case 'goblin':         return const Color(0xFF7DDA58);
    case 'giant_slime':    return const Color(0xFF7DDA58);
    case 'goblin_king':    return const Color(0xFFD4A017);
    case 'dragon':         return const Color(0xFFEF4444);
    case 'shadow_mage':    return const Color(0xFFA78BFA);
    // 【FEAT-302】新規 3 体の個別色（tier default にも fallback 可能）。
    case 'armored_knight': return const Color(0xFFF59E0B); // mid_boss オレンジ
    case 'ice_witch':      return const Color(0xFF4FC3F7); // 氷色シアン
    case 'void_dragon':    return const Color(0xFF9C27B0); // hidden_boss 紫
    default:
      return _kTierColors[enemy.tier] ?? const Color(0xFF7DDA58);
  }
}

/// 【FEAT-302 / FEAT-489】tier 表示ラベル（l10n 経由でロケール別文字列を返す）。
String _labelForTier(AppLocalizations l10n, String tier) {
  switch (tier) {
    case 'mid_boss':    return l10n.guildEnemyTierMidBoss;
    case 'boss':        return l10n.guildEnemyTierBoss;
    case 'hidden_boss': return l10n.guildEnemyTierHiddenBoss;
    case 'zako':        return l10n.guildEnemyTierZako;
    default:            return l10n.guildEnemyTierZako;
  }
}

/// 【FEAT-296 / FEAT-297 後続 hotfix 2026-05-24】敵一覧。Backend
/// `GET /api/battle/enemies/` (tier 未指定) で **全 5 体取得**:
///   - zako: goblin (ゴブリン) + giant_slime (巨大スライム)
///   - boss: goblin_king / dragon / shadow_mage
///
/// 旧実装は `tier=boss` で 3 体のみ取得していたが、ユーザー要望「ゴブリンも
/// 他のボスと同じような枠で表示したい」に応じて全 5 体統一表示に変更。
/// BattleWidget は同タイミングで撤去（ゴブリン専用ウィジェットの役割を本リストに統合）。
class _BossQuestList extends ConsumerWidget {
  const _BossQuestList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enemiesAsync = ref.watch(enemyListProvider(null));

    // 【FEAT-442 (2026-06-17)】プル to リフレッシュ。ホーム / カレンダー画面と
    // 同様に最上部より上にスクロールすると画面再読み込みできるよう対応。
    // 全状態 (loading / error / data / empty) で動作するよう、各分岐は
    // AlwaysScrollableScrollPhysics を持つ ListView を返す設計。
    Future<void> onRefresh() async {
      ref.invalidate(enemyListProvider(null));
      ref.invalidate(playerNotifierProvider);
      // ignore: invalid_use_of_visible_for_testing_member
      ref.invalidate(homeBootstrapRawProvider);
    }

    final l10n = AppLocalizations.of(context)!;
    return RefreshIndicator(
      onRefresh: onRefresh,
      color: AppTheme.primary,
      child: enemiesAsync.when(
        loading: () => ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            const SizedBox(height: 80),
            // 【FEAT-482 (2026-07-06)】Sabi パネル統一 (shop_page.dart:196 と同パターン)
            SabiWaitingPanel(message: l10n.guildBoardLoadingSabi_message),
          ],
        ),
        error: (e, _) => ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            const SizedBox(height: 40),
            Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                children: [
                  Text(
                    l10n.guildBoardErrorSabi_message,
                    style: TextStyle(color: Colors.white.withValues(alpha: 0.7)),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                  TextButton.icon(
                    onPressed: () => ref.invalidate(enemyListProvider(null)),
                    icon: const Icon(Icons.refresh, size: 16),
                    label: Text(l10n.guildBoardRetryButton),
                  ),
                ],
              ),
            ),
          ],
        ),
        data: (enemies) {
          if (enemies.isEmpty) {
            return ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                const SizedBox(height: 40),
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    l10n.guildBoardEmptySabi_message,
                    style: TextStyle(color: Colors.white.withValues(alpha: 0.6)),
                    textAlign: TextAlign.center,
                  ),
                ),
              ],
            );
          }
        // 【FEAT-512】初回 tutorial: recentBattlesProvider が空 = 未出陣ユーザー
        final battles = ref.watch(recentBattlesProvider(10)).valueOrNull;
        final showTutorial = battles != null && battles.isEmpty;
        // 【2026-06-12】ハイブリッド並び順:
        //   解放済: unlock_level 降順 (= 強い順、最強の挑戦可能敵を一番上)
        //   未解放: unlock_level 昇順 (= 弱い順、次の解放予定敵を境界直下)
        //   二次キー: base_hp で同 Lv 内の安定化 (griffin/void_dragon 共に Lv 35 等)
        // Backend は unlock_level 昇順固定 (5 分キャッシュ維持)、Mobile 側で
        // playerLevel に応じて動的 sort することでキャッシュ + 即時反映を両立。
        final playerLevel = ref.watch(playerNotifierProvider).valueOrNull?.level ?? 0;
        final unlocked = enemies
            .where((e) => e.unlockLevel <= 0 || playerLevel >= e.unlockLevel)
            .toList()
          ..sort((a, b) {
            final cmp = b.unlockLevel.compareTo(a.unlockLevel);
            return cmp != 0 ? cmp : b.baseHp.compareTo(a.baseHp);
          });
        final locked = enemies
            .where((e) => e.unlockLevel > 0 && playerLevel < e.unlockLevel)
            .toList()
          ..sort((a, b) {
            final cmp = a.unlockLevel.compareTo(b.unlockLevel);
            return cmp != 0 ? cmp : a.baseHp.compareTo(b.baseHp);
          });
        final showBoundary = unlocked.isNotEmpty && locked.isNotEmpty;
        final tutorialOffset = showTutorial ? 1 : 0;
        final itemCount =
            tutorialOffset + unlocked.length + (showBoundary ? 1 : 0) + locked.length;

          return ListView.builder(
            // 【FEAT-442 (2026-06-17)】プル to リフレッシュ対応のため、内容が
            // 画面に収まる量でも常にスクロール可能にする。
            physics: const AlwaysScrollableScrollPhysics(),
            // 【FEAT-211】ボトムナビ + ホームインジケータに隠れないよう下部余白を確保。
            padding: EdgeInsets.fromLTRB(
              16,
              12,
              16,
              MediaQuery.of(context).padding.bottom + 100,
            ),
            itemCount: itemCount,
            itemBuilder: (context, index) {
              // 【FEAT-512】tutorial は常に最上部
              if (showTutorial && index == 0) {
                return const SabiGuildOnboardingFlow();
              }
              final i = index - tutorialOffset;
              if (i < unlocked.length) {
                return _BossQuestCard(enemy: unlocked[i]);
              }
              if (showBoundary && i == unlocked.length) {
                return const _LockedSectionHeader();
              }
              final lockedIdx = i - unlocked.length - (showBoundary ? 1 : 0);
              return _BossQuestCard(enemy: locked[lockedIdx]);
            },
          );
        },
      ),
    );
  }
}

/// 【2026-06-12】解放済 / 未解放クエストの境界に挟む見出し。
/// `_BossQuestList` のハイブリッド並び順 (解放済降順 → 未解放昇順) で、
/// 「ここから先は未解放」のセパレータとして表示。
class _LockedSectionHeader extends StatelessWidget {
  const _LockedSectionHeader();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: [
          Expanded(
            child: Divider(
              color: Colors.white.withValues(alpha: 0.15),
              thickness: 1,
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.lock_outline,
                  size: 14,
                  color: Colors.white.withValues(alpha: 0.5),
                ),
                const SizedBox(width: 6),
                Text(
                  AppLocalizations.of(context)!.guildLockedQuestsLabel,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.6),
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1.0,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: Divider(
              color: Colors.white.withValues(alpha: 0.15),
              thickness: 1,
            ),
          ),
        ],
      ),
    );
  }
}

// 【FEAT-513】_BossQuestCard を ConsumerStatefulWidget 化してプリセットカウンターを保持する。
class _BossQuestCard extends ConsumerStatefulWidget {
  const _BossQuestCard({required this.enemy});

  final EnemyMaster enemy;

  @override
  ConsumerState<_BossQuestCard> createState() => _BossQuestCardState();
}

class _BossQuestCardState extends ConsumerState<_BossQuestCard> {
  // 【FEAT-513】Ambient Auto Battle 試行回数プリセット (SharedPreferences から初期化)
  int _presetCount = 0;

  @override
  void initState() {
    super.initState();
    _loadPreset();
  }

  Future<void> _loadPreset() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _presetCount = AmbientAutoBattlePreferences.getPreset(prefs, widget.enemy.key);
    });
  }

  Future<void> _setPreset(int count) async {
    final clamped = count.clamp(0, 99);
    setState(() => _presetCount = clamped);
    final prefs = await SharedPreferences.getInstance();
    await AmbientAutoBattlePreferences.setPreset(prefs, widget.enemy.key, clamped);
    PosthogService.instance.capture(
      'ambient_battle_preset_updated',
      properties: {'enemy_key': widget.enemy.key, 'count': clamped},
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final enemy = widget.enemy;
    final iconColor = _colorForEnemy(enemy);
    // 【FEAT-302】player.level < unlockLevel なら 🔒 表示 + タップ無効。
    final playerAsync = ref.watch(playerNotifierProvider);
    final playerLevel = playerAsync.valueOrNull?.level ?? 0;
    final isLocked = enemy.unlockLevel > 0 && playerLevel < enemy.unlockLevel;
    // 【FEAT-306】出陣可否（battleCharges >= 3）を combine し、disabled ボタンに統合。
    // 旧実装の「押せる + SnackBar」経路は撤廃、押下不可 + サブテキストで明示。
    final avail = ref.watch(battleAvailabilityProvider);
    final canBattle = avail.canBattle;
    final isEnabled = !isLocked && canBattle;
    // 【FEAT-513】Ambient Auto Battle モード表示制御
    final autoEnabled = ref.watch(ambientAutoBattleEnabledProvider);

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      color:  AppTheme.card,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(6),
        side: BorderSide(
          color: iconColor.withValues(alpha: isLocked ? 0.2 : 0.4),
          width: 1.5,
        ),
      ),
      // 【FEAT-513】autoEnabled スコープを card 下流に渡す
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                // sprite 表示（asset 未配置時は errorBuilder で半透明プレースホルダ）
                Container(
                  width: 48, height: 48,
                  decoration: BoxDecoration(
                    color:  iconColor.withValues(alpha: 0.15),
                    border: Border.all(color: iconColor, width: 1.5),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(3),
                        child: Opacity(
                          opacity: isLocked ? 0.3 : 1.0,
                          child: Image.asset(
                            'assets/images/battle/${enemy.spriteKey}.webp',
                            width:  48, height: 48,
                            fit:    BoxFit.contain,
                            filterQuality: FilterQuality.none, // ドット絵 nearest
                            errorBuilder: (_, __, ___) => Icon(
                              Icons.bug_report_outlined,
                              color: iconColor,
                              size: 24,
                            ),
                          ),
                        ),
                      ),
                      // 【FEAT-302】ロック中は sprite 上に 🔒 アイコンを重ねる。
                      if (isLocked)
                        const Icon(Icons.lock,
                            color: Colors.white70, size: 22),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        enemy.name,
                        style: TextStyle(
                          color:      isLocked ? Colors.white60 : Colors.white,
                          fontSize:   15,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        // 【FEAT-302】tier ラベル + ロック中は解禁レベル併記。
                        isLocked
                            ? l10n.guildEnemyUnlockLevelAndTierLabel(_labelForTier(l10n, enemy.tier), enemy.unlockLevel)
                            : _labelForTier(l10n, enemy.tier),
                        style: TextStyle(
                          color: iconColor.withValues(alpha: 0.85),
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      // 【FEAT-302 → FEAT-439 (2026-06-17)】弱点 / 耐性 chip 行。
                      // 未勝利時は「強さ未知数」体験を維持するため非表示、勝利後に解放。
                      // PM 判断「強さ未知数の方が良い、負けたデメリットなし、一度勝利
                      // で弱点表示」採択。Backend EnemyListView.defeated で判定。
                      if (enemy.defeated &&
                          (enemy.hasPhysicalResistance ||
                              enemy.hasMagicalResistance ||
                              enemy.hasWeakness))
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: _ResistanceChips(enemy: enemy),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // 【FEAT-439 (2026-06-17)】HP ゲージ + 「基礎 N × Y.Y」テキスト撤去。
            // 「強さ未知数」体験維持のため、勝利後も常に非表示。バトル中は battle_page
            // 側で動的 HP ゲージが表示されるため、ギルド一覧での事前提示は不要と判断。

            // 報酬（coins + EXP）
            Row(
              children: [
                const Icon(Icons.card_giftcard,
                    size: 14, color: Color(0xFFFFD60A)),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    l10n.guildEnemyRewardLabel(enemy.rewardCoins, enemy.rewardExp),
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // 参加ボタン
            // 【FEAT-306】出陣不可 (Lv 未達 or battleCharges < 3) は disabled 化。
            // 旧 FEAT-302 のタップで SnackBar 経路は撤廃、押下不可 + 下部サブテキストで
            // disabled 理由を明示（learned helplessness 回避、Pre-mortem #4）。
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: isEnabled ? () => _onJoin(context, ref, enemy) : null,
                icon: Icon(
                  isEnabled
                      ? Icons.flash_on
                      : (isLocked ? Icons.lock : Icons.info_outline),
                  size: 16,
                ),
                label: Text(
                  isEnabled
                      ? (enemy.isBoss ? l10n.guildEnemyAttackButton : l10n.guildEnemyJoinButton)
                      : (isLocked
                          ? l10n.guildEnemyUnlockLevelButton(enemy.unlockLevel)
                          : l10n.guildEnemyPrepButton),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: isEnabled
                      ? iconColor.withValues(alpha: 0.85)
                      : Colors.white.withValues(alpha: 0.10),
                  foregroundColor: isEnabled ? Colors.white : Colors.white60,
                  disabledBackgroundColor:
                      Colors.white.withValues(alpha: 0.10),
                  disabledForegroundColor: Colors.white60,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
            ),
            // 【FEAT-306】disabled 時のサブテキスト (Pre-mortem #4)。
            if (!isEnabled) ...[
              const SizedBox(height: 6),
              _BattleChargeSubtext(
                isLocked: isLocked,
                unlockLevel: enemy.unlockLevel,
                charges: avail.charges,
              ),
            ],
            // 【FEAT-513】解放済み + Ambient Auto Battle ON の場合にプリセットスピナーを表示
            if (!isLocked && autoEnabled) ...[
              const SizedBox(height: 10),
              _PresetCountRow(
                enemyName: enemy.name,
                count: _presetCount,
                onDecrement: () => _setPreset(_presetCount - 1),
                onIncrement: () => _setPreset(_presetCount + 1),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 【FEAT-296】参加ボタンタップ → 出陣可能なら大画面 BattlePage 遷移 + 戦闘開始、
  /// チケット不足ならサビ口調 SnackBar。
  ///
  /// 【ユーザー判断 2026-05-31】context.go(/home) → context.push(/battle) に再変更。
  /// 設計意図: 「クエスト受託は大画面で没入バトル、戻るで MiniBattleArena に縮小」体験。
  /// 旧 FEAT-297 設計 (受託即ホームで MiniBattleArena = ながらプレイ主体験) から、
  /// 「受託 → 大画面 → 戻る → MiniBattleArena 継続」に方針転換。
  /// MiniBattleArena 機能は維持 (BattleSession state は autoDispose 無効、
  /// BattlePage の AppBar leading で context.go(/home) すれば継続表示される)。
  ///
  /// 【FEAT-298】ホーム遷移前に BattlePreStartSheet で **回復薬の使用数** を選択。
  /// キャンセル時は何もしない（Pre-mortem #4 対応: selectEnemyForNextBattle も呼ばない）。
  /// 出陣選択時は `setPendingPotionsToUse` + `selectEnemyForNextBattle` + ホーム遷移。
  Future<void> _onJoin(
    BuildContext context,
    WidgetRef ref,
    EnemyMaster enemy,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    HapticFeedback.lightImpact();
    // Pre-mortem #6 緩和: 戦闘準備チェック (BattleAvailability を watch)
    final avail = ref.read(battleAvailabilityProvider);
    if (!avail.canBattle) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.guildLowStatsWarningBody),
          duration: const Duration(seconds: 3),
        ),
      );
      return;
    }

    // 【FEAT-513 v1.1 hotfix 2026-07-31】Guild toggle 経由の Skip Mode 分岐廃止。
    // Skip は battle 画面の速度選択 5 番目 (⏭) に統合済 (FEAT-505 §2.1 原仕様復元)。
    // 全 tap は下記の通常 battle 経路 (BattlePreStartSheet → /battle) を通る。

    // 【FEAT-298】回復薬使用数選択 BottomSheet を表示（caller-decides-navigation）。
    // 戻り値: null=キャンセル / int 0-3=使用予定数。
    //
    // 【FEAT-298 hotfix 2026-05-24】ShellRoute 配下で showModalBottomSheet を
    // useRootNavigator 未指定（= デフォルト false）で開くと shell の nested
    // navigator に push される。一方 BattlePreStartSheet 内部の Navigator.pop は
    // `rootNavigator: true` で root navigator を pop するため、sheet ではなく
    // ShellRoute 全体が pop されて画面真っ黒になるバグが発生していた。
    // CLAUDE.md「Flutter 既知の落とし穴 §ShellRoute 配下での showDialog +
    // Navigator.pop のコンテキスト分離（FEAT-215）」と同じ構造の問題。
    // 修正: useRootNavigator: true を明示して sheet を root に push し、
    // BattlePreStartSheet 内部の root pop と整合させる。
    // 【FEAT-376 + FEAT-432】BattlePreStartSheet が List<int>? を返す (4 種類のポーション数)
    final potionSelection = await showModalBottomSheet<List<int>?>(
      context: context,
      isScrollControlled: true,
      useRootNavigator: true,  // 【FEAT-298 hotfix】ShellRoute 整合性
      backgroundColor: Colors.transparent,
      // 【FEAT-302】enemy 全体を渡して耐性 / 弱点 advisory を表示。
      builder: (_) =>
          BattlePreStartSheet(enemyName: enemy.name, enemy: enemy),
    );
    if (!context.mounted) return;
    if (potionSelection == null) return; // キャンセル: 何もしない

    // 【CLAUDE.md BUG-65 標準パターン】sheet dispose 完全完了を 300ms 待ってから navigate。
    await Future.delayed(const Duration(milliseconds: 300));
    if (!context.mounted) return;

    // 次回 startBattle の対象敵 + ポーション数を予約 → ホーム遷移。
    // potionSelection = [regular, plus, attack, defense] の 4 要素 List。
    final notifier = ref.read(battleSessionProvider.notifier);
    notifier.setPendingPotionsToUse(potionSelection.isNotEmpty ? potionSelection[0] : 0);
    notifier.setPendingPotionsPlusToUse(potionSelection.length > 1 ? potionSelection[1] : 0);
    notifier.setPendingAttackPotionsToUse(potionSelection.length > 2 ? potionSelection[2] : 0);
    notifier.setPendingDefensePotionsToUse(potionSelection.length > 3 ? potionSelection[3] : 0);
    notifier.selectEnemyForNextBattle(enemy.key);
    if (!context.mounted) return;
    // 【ユーザー判断 2026-05-31】FEAT-297 の「context.go(/home) で MiniBattleArena」
    // 設計から、「context.push(/battle) で大画面 → 戻るで /home の MiniBattleArena」
    // 設計に方針転換。没入バトルを主体験、ながらプレイを副体験 (戻るで縮小) に。
    // MiniBattleArena 機能は維持 (BattleSession state は autoDispose 無効で継続)。
    context.push(AppRoutes.battle);
  }

  // 【FEAT-505 → FEAT-513 v1.1 hotfix 2 follow-up (2026-07-31)】旧 _onSkipBattle
  // (SkipConfirmDialog → runSkipBattle → SkipResultDialog、~90 LOC) は撤去済。
  // Skip は battle 画面速度選択 5 番目 (⏭ = 50x tick) に統合され、
  // 手動 battle 経路 (_onJoin → context.push(/battle)) と統一された。
}

// ═════════════════════════════════════════════════════════════════════════════
// 【FEAT-302】_ResistanceChips — 弱点 / 耐性 表示用の小型 chip 群
// ═════════════════════════════════════════════════════════════════════════════

/// 敵カードに重ねる弱点 / 耐性の小型 chip 群。
///
/// 表示パターン:
///   - 物理耐性 (赤): `physicalResistance < 1.0` のとき「物理 -30%」等
///   - 魔法耐性 (赤): `magicalResistance < 1.0` のとき「魔法 -50%」等
///   - 弱点 (黄):    `weakUltCost != null` のとき「弱点: ult4」等
///
/// 各 chip は Tooltip で詳細説明（攻略のヒント、サビ口調）。
class _ResistanceChips extends StatelessWidget {
  const _ResistanceChips({required this.enemy});

  final EnemyMaster enemy;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final chips = <Widget>[];
    if (enemy.hasPhysicalResistance) {
      final pct = ((1.0 - enemy.physicalResistance) * 100).round();
      chips.add(_chip(
        label:   l10n.guildEnemyPhysicalResistanceLabel(pct),
        color:   const Color(0xFFEF4444),
        tooltip: l10n.guildEnemyPhysicalResistanceTooltip,
      ));
    }
    if (enemy.hasMagicalResistance) {
      final pct = ((1.0 - enemy.magicalResistance) * 100).round();
      chips.add(_chip(
        label:   l10n.guildEnemyMagicResistanceLabel(pct),
        color:   const Color(0xFFEF4444),
        tooltip: l10n.guildEnemyMagicResistanceTooltip,
      ));
    }
    if (enemy.hasWeakness) {
      chips.add(_chip(
        label:   l10n.guildEnemyWeaknessUltLabel(enemy.weakUltCost!),
        color:   const Color(0xFFFBBF24),
        tooltip: l10n.guildEnemyWeaknessUltTooltip(enemy.weakUltCost!),
      ));
    }
    if (chips.isEmpty) return const SizedBox.shrink();
    return Wrap(spacing: 4, runSpacing: 2, children: chips);
  }

  Widget _chip({
    required String label,
    required Color color,
    required String tooltip,
  }) {
    return Tooltip(
      message: tooltip,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.18),
          border: Border.all(color: color.withValues(alpha: 0.55), width: 0.8),
          borderRadius: BorderRadius.circular(3),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: color,
            fontSize: 9,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// 【FEAT-304】Phase 4 の _EquipmentSheet / _MockEquipment / _EquipmentTile は撤廃。
// 装備の閲覧・将来の変更導線は AppBar 🛡️ → PartyEditDialog
// (mobile/lib/features/battle/widgets/party_edit_dialog.dart) に統合された。
// 旧モック実装 (~157 LOC) は dead UX のため削除 (FEAT-207 mock 由来)。
// ═════════════════════════════════════════════════════════════════════════════

// 【FEAT-505 → FEAT-513 v1.1 hotfix 2 follow-up (2026-07-31)】旧 _SkipModeBar
// (Guild ヘッダー下の Skip toggle bar、~65 LOC) は撤去済。Skip は battle 画面
// 速度選択 5 番目 (⏭) に統合され、Guild toggle は不要になった。
// SharedPreferences 'battle_skip_mode' key は user 端末に残置される場合があるが
// 読み書き経路ゼロのため無害 (次回 install で上書き / 永続 orphan)。

// ═════════════════════════════════════════════════════════════════════════════
// 【FEAT-513 → FEAT-528 (2026-08-23)】AutoBattleBar は撤去
// ═════════════════════════════════════════════════════════════════════════════
//
// GuildReceptionView の直下にあったオートバトル切替バー (~120 LOC) を削除した。
//
// ## 経緯
//
// FEAT-528 でバーに速度バッジと歯車を足したところ、1 行に 4 種類の情報
// (状態 / 説明 / 速度 / 設定) が並ぶ密度になった。英語では副題が
// 「(Fights automatically when yo…」と切れ、押し分けのための的の確保にも
// 苦労した。2 度の実機 QA を経て、**バーごと畳んで AppBar の歯車 1 つに
// する**判断になった (2026-08-23 ユーザー判断)。
//
// ## 🔵 オートバトルの ON/OFF はどこで分かるのか
//
// **各クエストカードの参加回数スピナー** (`_PresetCountRow`)。
// `if (!isLocked && autoEnabled)` で囲まれているので、**ON のときだけ現れる**。
// トグルより情報量が多く (回数まで見える)、その場で設定もできる。
//
// ⚠️ ただし信号は片方向である。**OFF のときは何も出ない**ので、
// 「オートバトルという機能がある」ことは歯車を開くまで分からない。
// ギルドのオンボーディング (FEAT-512) も出陣 3 ステップのみで触れていない。
// 機能の発見性を上げるなら、そちらに 1 行足すのが素直 (別 FEAT)。
//
// _ToggleSwitch → BattleToggleSwitch (battle/widgets/battle_toggle_switch.dart)
// への移設はそのまま。トグル自体はバトル設定モーダルで使い続ける。

/// 【FEAT-528 (2026-08-23)】AppBar actions に置く「速度バッジ + 歯車」。
///
/// 🔵 **1 つの widget にまとめてあるのはテストのため。** ここを guild_page の
/// `actions:` に直書きすると、テスト側で AppBar を組み直すことになり
/// **実装のコピーが 2 つ**できる。コピーは必ず古くなる。
///
/// 並び（歯車がハンバーガーの左、`leading` は空のまま）は
/// `battle_settings_dialog_test.dart` の D-3 がソース走査で縛っている。
class GuildBattleSettingsAction extends StatelessWidget {
  const GuildBattleSettingsAction({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const _SpeedBadge(),
        IconButton(
          icon: const Icon(Icons.settings),
          tooltip: l10n.guildBattleSettingsTooltip,
          onPressed: () => openBattleSettingsDialog(context),
        ),
      ],
    );
  }
}

/// 【FEAT-528】AppBar に出す現在のバトル速度バッジ。
///
/// 🔴 **これが「Skip の一方通行」問題の実質的な解決。** モーダル（出口）を作っても、
/// **Skip のままだと気付けていない**という本体は解けない。開かなくても
/// 見える場所に現在値を出すことで、初めて「戻そう」という発想が生まれる。
///
/// ## 🔵 等速のときは何も描かない（2026-08-23 ユーザー判断）
///
/// 既定値の「1x」は**情報量がゼロ**である。常時出していると見慣れてしまい、
/// **本当に気付いて欲しい ⏭ / 3x のときに埋もれる**。出さなければ、
/// 現れたこと自体が信号になる。
///
/// 副作用として、既定状態の AppBar は `⚙ ☰` だけになり、
/// ユーザー要望の「歯車アイコンだけ」を満たす。
class _SpeedBadge extends ConsumerWidget {
  const _SpeedBadge();

  /// 速度 → 表示ラベル。`battle_page` の `_SpeedChip` と同じ文字列を使う。
  static String labelFor(double speed) {
    for (final option in BattleSettingsDialog.speedOptions) {
      if ((speed - option.value).abs() < 0.01) return option.label;
    }
    // 想定外の値 (将来の選択肢追加 / 壊れた pref) でも黙って落とさない。
    return '${speed.toStringAsFixed(speed % 1 == 0 ? 0 : 1)}x';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final speed = ref.watch(battleSpeedPreferenceProvider);
    if ((speed - 1.0).abs() < 0.01) return const SizedBox.shrink();
    return Center(
      child: Padding(
        padding: const EdgeInsets.only(left: 4),
        child: Text(
          labelFor(speed),
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.bold,
            color: AppTheme.primary,
          ),
        ),
      ),
    );
  }
}

/// 【FEAT-528】バトル設定モーダルを開く。
///
/// `_openPartyEditDialog` と**同じ形**で書いてある（showGeneralDialog /
/// barrierDismissible / 200ms の Scale + Fade）。`pageBuilder` の `dialogContext`
/// を `onClose` に束ねるのは CLAUDE.md FEAT-215 の要請で、
/// 外側 context で pop すると ShellRoute の navigator ごと pop してしまう。
///
/// モーダル内では navigation を一切しないので BUG-65 系の race も起きない。
void openBattleSettingsDialog(BuildContext context) {
  final l10n = AppLocalizations.of(context)!;
  showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: l10n.guildPageDrawerBarrierLabel,
    barrierColor: Colors.black54,
    transitionDuration: const Duration(milliseconds: 200),
    pageBuilder: (dialogContext, __, ___) => BattleSettingsDialog(
      onClose: () => Navigator.of(dialogContext).pop(),
    ),
    transitionBuilder: (_, animation, __, child) => ScaleTransition(
      scale: CurvedAnimation(parent: animation, curve: Curves.easeOut),
      child: FadeTransition(opacity: animation, child: child),
    ),
  );
}

// 【FEAT-528 (2026-08-22)】旧 _ToggleSwitch は
// `battle/widgets/battle_toggle_switch.dart` の `BattleToggleSwitch` に移設した。
// バトル設定モーダルが同じ見た目を使うため、2 箇所にコピーを置かない。

// ═════════════════════════════════════════════════════════════════════════════
// 【FEAT-306】_BattleChargeSubtext — 出陣ボタン disabled 時のサブテキスト
// ═════════════════════════════════════════════════════════════════════════════

/// 出陣ボタン disabled 時、ボタン下に表示する disabled 理由テキスト。
///
/// 表示パターン:
///   - `isLocked` (Lv 未達)        → 「Lv.XX で解禁」(FEAT-302 既存パターン踏襲)
///   - そうでなく chargesShort      → 「あと N 回の習慣達成で出陣可能 🪶」(サビ口調)
///
/// 【FEAT-409 (2026-06-01)】文言を「達成」→「習慣達成」に統一。
/// battle_provider.dart の tooltip / label と整合 (旧来から「習慣」が抜けていた
/// guild_page だけが単独で「達成」表記の不整合状態だった)。
///
/// 視認性確保 (Pre-mortem #4):
///   - 黄色系 (AppTheme.warning) + 太字 + 情報アイコン
///   - 既存 FEAT-302 の 🔒 アイコン (Lv 未達) との UI 統一感維持
class _BattleChargeSubtext extends StatelessWidget {
  const _BattleChargeSubtext({
    required this.isLocked,
    required this.unlockLevel,
    required this.charges,
  });

  final bool isLocked;
  final int unlockLevel;
  final int charges;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final IconData icon;
    final String text;
    if (isLocked) {
      icon = Icons.lock_outline;
      text = l10n.guildEnemyUnlockLevelOnly(unlockLevel);
    } else {
      icon = Icons.info_outline;
      final remaining = (BattleConstants.chargesPerBattle - charges)
          .clamp(0, BattleConstants.chargesPerBattle);
      // 【20260729 gameplay-review §2-1 案 A 対応】「今日」の 2 文字で日次性を
      // 事前に伝える (翌朝 0 リセットが「消えた」ではなく「そういうもの」に)。
      text = l10n.guildEnemyDailyRemainingHint(remaining);
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 12, color: AppTheme.warning),
        const SizedBox(width: 4),
        Text(
          text,
          style: const TextStyle(
            color: AppTheme.warning,
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// 【FEAT-513】_PresetCountRow — 敵ごとのオートバトル試行回数スピナー
// ═════════════════════════════════════════════════════════════════════════════

/// 各 _BossQuestCard の下部に表示するオートバトル回数プリセットスピナー。
///
/// オートバトル ON かつ解放済みの敵にのみ表示される。
/// count = 0 のとき「−」ボタンを無効化 (0 以下にならない)。
/// count = 99 のとき「+」ボタンを無効化 (上限)。
class _PresetCountRow extends StatelessWidget {
  const _PresetCountRow({
    required this.enemyName,
    required this.count,
    required this.onDecrement,
    required this.onIncrement,
  });

  final String enemyName;
  final int count;
  final VoidCallback onDecrement;
  final VoidCallback onIncrement;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          l10n.guildAutoCountLabel,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.55),
            fontSize: 11,
          ),
        ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _SpinnerButton(
              icon: Icons.remove,
              onPressed: count > 0 ? onDecrement : null,
            ),
            SizedBox(
              width: 36,
              child: Text(
                '$count',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: count > 0
                      ? Colors.white
                      : Colors.white.withValues(alpha: 0.4),
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            _SpinnerButton(
              icon: Icons.add,
              onPressed: count < 99 ? onIncrement : null,
            ),
          ],
        ),
      ],
    );
  }
}

class _SpinnerButton extends StatelessWidget {
  const _SpinnerButton({required this.icon, required this.onPressed});

  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 28,
      height: 28,
      child: IconButton(
        padding: EdgeInsets.zero,
        icon: Icon(icon, size: 16),
        color: AppTheme.primary,
        disabledColor: Colors.white.withValues(alpha: 0.2),
        onPressed: onPressed,
      ),
    );
  }
}
