import 'dart:async';

import 'package:dio/dio.dart';  // 【2026-07-08 hotfix】長押し連打の 400 race silent-catch
import 'package:flutter/material.dart';
import '../../../l10n/app_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/api/error_formatter.dart';  // 【2026-07-09】name 変更 dialog の error 表示用
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/character_asset.dart';  // FEAT-123
import '../../../shared/widgets/sabi_loading_skeleton.dart';   // FEAT-230
import '../../calendar/widgets/cumulative_progress_chart.dart'; // P2-3
import '../../habits/models/player.dart';
import '../../habits/providers/habits_provider.dart';
import '../../settings/providers/settings_provider.dart';  // 【2026-07-09】name 変更 dialog 用
import '../models/gamification_models.dart';
import '../providers/gamification_provider.dart';
import '../widgets/character_fullscreen_view.dart';  // 【新規 2026-06-26】全画面表示
import '../widgets/character_zoom_indicator.dart';   // 【新規 2026-06-26】ズームアイコン
import '../widgets/sabi_stats_onboarding_flow.dart'; // 【FEAT-512】
import '../widgets/stat_hexagon_chart.dart';         // 【FEAT-489】stat 名の l10n 解決
import '../widgets/status_overview_card.dart';       // 【新規 2026-06-27】総覧カード(共通)
// 【2026-06-27 v5】StatHexagonChart / StatRankBadge / StatSummaryList は
// StatusOverviewCard 内部で使うように集約済のため、本ファイルからは直接 import 不要。

class StatsPage extends ConsumerStatefulWidget {
  const StatsPage({super.key});

  @override
  ConsumerState<StatsPage> createState() => _StatsPageState();
}

class _StatsPageState extends ConsumerState<StatsPage> {
  // FEAT-115: スクロール検知 + フローティングバッジ制御
  final ScrollController _scrollController = ScrollController();
  bool _showFloatingBadge = false;

  // バナーが画面外に出たとみなすスクロール量（px）
  static const double _badgeThreshold = 200.0;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  void _onScroll() {
    final shouldShow =
        _scrollController.hasClients &&
        _scrollController.offset > _badgeThreshold;
    if (shouldShow != _showFloatingBadge) {
      setState(() => _showFloatingBadge = shouldShow);
    }
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final statsAsync  = ref.watch(statsNotifierProvider);
    final playerAsync = ref.watch(playerNotifierProvider);

    // FEAT-115: allocatable は build() レベルで取得してフローティングバッジに渡す
    final allocatable =
        playerAsync.whenOrNull(data: (p) => p.allocatablePoints) ?? 0;

    return Scaffold(
      appBar: AppBar(
        title: Text(AppLocalizations.of(context)!.gamifStatsPageTitle),
        // 【FEAT-330 (2026-05-27) → 2026-07-05 更新】旧経緯: AppBar ショップアイコン
        // 撤去後、_EconomyCard 3 列 (ギルド / ガチャ / キャラ変更) で遷移経路を提供。
        // 【2026-07-05】_EconomyCard 3 列も撤去。ギルドは BottomNav タブ、ガチャ /
        // キャラ変更は Home/Guild Drawer 経由で到達可能になり、ステータス画面から
        // の直接動線は不要と判断。ステータス画面は「6 stat の可視化」に純化。
      ),
      body: Stack(
        children: [
          // ── メインコンテンツ ──────────────────────────────────────────────
          statsAsync.when(
            data: (stats) => _buildBody(context, stats, playerAsync),
            loading: () => SabiWaitingPanel(message: AppLocalizations.of(context)!.gamifStatsPageLoadingSabi_message),
            error: (e, _) => Center(
              child: Text(
                AppLocalizations.of(context)!.gamifStatsPageErrorSabi_message,
                style: const TextStyle(color: Colors.red),
              ),
            ),
          ),

          // ── FEAT-115: フローティングポイントバッジ ────────────────────────
          // ポイントあり かつ スクロールでバナーが隠れた場合のみ表示
          AnimatedSlide(
            offset: (allocatable > 0 && _showFloatingBadge)
                ? Offset.zero
                : const Offset(0, 1.5),
            duration: const Duration(milliseconds: 280),
            curve: Curves.easeOutCubic,
            child: AnimatedOpacity(
              opacity: (allocatable > 0 && _showFloatingBadge) ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 200),
              child: Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: EdgeInsets.only(
                    bottom: 20 + MediaQuery.of(context).padding.bottom,
                  ),
                  child: _FloatingPointsBadge(
                    points: allocatable,
                    onTap: () => _scrollController.animateTo(
                      0,
                      duration: const Duration(milliseconds: 400),
                      curve: Curves.easeOutCubic,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context, List<CharacterStat> stats,
      AsyncValue<Player> playerAsync) {
    final allocatable =
        playerAsync.whenOrNull(data: (p) => p.allocatablePoints) ?? 0;
    final player = playerAsync.valueOrNull;

    return ListView(
      controller: _scrollController, // FEAT-115: スクロール検知のため追加
      padding: EdgeInsets.fromLTRB(
        16, 16, 16,
        // FEAT-115: バッジの高さ分（72px）底パディングを追加してバッジで隠れる対策
        88 + MediaQuery.of(context).padding.bottom,
      ),
      children: [
        // ── ステータスヘッダーカード (共通 widget 化、2026-06-27 v5) ──
        // 【2026-06-27 v5】v4 (Container 直接組み立て) を撤回し、共通 widget
        // `StatusOverviewCard` 呼び出しに集約。フレンドプロフィール画面
        // (friend_profile_page) と表示を 1:1 で共有するため。
        // 自画面側はアバタータップで全画面表示遷移する経路を avatarSection で組む。
        if (player != null)
          StatusOverviewCard(
            avatarSection: GestureDetector(
              onTap: () {
                final char = player.activeCharacter;
                if (char == null) return;
                CharacterFullscreenView.push(
                  context,
                  imagePath:     char.imagePath,
                  keyFallback:   char.key,
                  heroTag:       'status_card_avatar',
                  characterName: char.name,
                );
              },
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Hero(
                    tag: 'status_card_avatar',
                    child: CircleAvatar(
                      radius: 36,
                      backgroundColor:
                          AppTheme.primary.withValues(alpha: 0.3),
                      child: ClipOval(
                        child: Image.asset(
                          CharacterAsset.assetPath(
                              player.activeCharacter?.imagePath),
                          width: 72,
                          height: 72,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => const Icon(
                            Icons.person,
                            size: 40,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const Positioned(
                    right: -2,
                    bottom: -2,
                    child: CharacterZoomIndicator(),
                  ),
                ],
              ),
            ),
            name: player.name,
            level: player.level,
            stats: stats,
            // 【2026-07-09】自画面のみ ✏️ ペン (名前変更) + 「キャラ変更」チップを表示。
            // friend_profile_page 側は両 callback を渡さないため影響ゼロ。
            onEditName: () => _showEditNameDialog(context, player),
            onChangeCharacter: () => context.push(AppRoutes.character),
          ),
        // ── 既存コンテンツ ──────────────────────────────────────────────
        _buildQuickNavRow(context),
        // 【2026-07-05】旧 _buildEconomyRow (ギルド / ガチャ / キャラ変更 3 列)
        // を撤去。ギルドは BottomNav、ガチャ / キャラ変更は Home/Guild Drawer に
        // 動線が集約されたため。ステータス画面は「6 stat の可視化」に純化。
        const SizedBox(height: 12),
        if (allocatable > 0) ...[
          _buildAllocatableBanner(allocatable),
          const SizedBox(height: 12),
        ],
        // 【FEAT-512】Lv.1 の初回ユーザーへ 6 stat の育て方を inline tutorial で案内
        if (player != null && player.level == 1) ...[
          const SabiStatsOnboardingFlow(),
          const SizedBox(height: 12),
        ],
        ...stats.map((stat) => _StatCard(
              stat: stat,
              allocatable: allocatable,
            )),

        // 【FEAT-379 (2026-05-29)】結晶インベントリ (Coming Soon)
        if (player != null) ...[
          const SizedBox(height: 16),
          _CrystalInventoryCard(player: player),
        ],

        // P2-3: 30 日積み上げ折れ線（プロダクト哲学「積み上げ」の可視化）
        const SizedBox(height: 16),
        const CumulativeProgressChart(),
      ],
    );
  }

  // ── クイックナビ: 実績バナー ────────────────────────────────────────────
  // 【更新 (2026-06-26)】称号 6 段階システム廃止に伴い、2 列 (実績・称号) →
  // 1 列 (実績のみ) に変更。実績は 30 件拡張 (FEAT-Z) で十分なバッジ収集要素を
  // 提供するため、称号との重複役割は実績側に統合済。
  Widget _buildQuickNavRow(BuildContext context) {
    return _NavBanner(
      emoji: '🏅',
      label: AppLocalizations.of(context)!.gamifStatsAchievementLabel,
      onTap: () => context.push(AppRoutes.achievements),
    );
  }

  // 【2026-07-05】_buildEconomyRow (ギルド / ガチャ / キャラ変更 3 列) 撤去済。
  // 動線は BottomNav (ギルド) + Home/Guild Drawer (ガチャ / キャラ変更) に移動。

  /// 【2026-07-09】ステータス画面の名前横 ✏️ ペン tap で発火する名前変更 dialog。
  ///
  /// profile_edit_page (フル画面編集) との違い:
  ///   - profile_edit_page: 名前 + 性別を同時編集、設定画面から到達 (2 タップ)
  ///   - 本 dialog: 名前のみ、ステータス画面から 1 タップで到達 = 頻度高い変更を軽量化
  /// 性別変更は引き続き profile_edit_page で行う。
  Future<void> _showEditNameDialog(BuildContext context, Player player) async {
    final l10n = AppLocalizations.of(context)!;
    final controller = TextEditingController(text: player.name);
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: Text(l10n.gamifStatsNameEditLabel, style: const TextStyle(color: Colors.white)),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 12,  // Backend PlayerProfile.name = CharField(max_length=12) 相当
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            hintText: l10n.gamifStatsNameEditHint,
            hintStyle: const TextStyle(color: Colors.white38),
            enabledBorder: OutlineInputBorder(
              borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.2)),
            ),
            focusedBorder: const OutlineInputBorder(
              borderSide: BorderSide(color: AppTheme.primary, width: 2),
            ),
            counterStyle: const TextStyle(color: Colors.white38),
          ),
          onSubmitted: (v) => Navigator.pop(dialogContext, v.trim()),
        ),
        // 【BUG-138】Cancel 左 / Action 右。
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(l10n.gamifStatsNameEditCancelButton, style: const TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text.trim()),
            style: TextButton.styleFrom(foregroundColor: AppTheme.primary),
            child: Text(l10n.gamifStatsNameEditConfirmButton),
          ),
        ],
      ),
    );

    if (result == null || result.isEmpty || result == player.name) return;
    if (!context.mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    try {
      // profile_edit_page と同じ経路: settingsServiceProvider.updateProfile()。
      // gender は現在値を渡して no-op、name のみ更新扱いにする。
      await ref.read(settingsServiceProvider).updateProfile(
            name:   result,
            gender: player.gender,
          );
      ref.invalidate(playerNotifierProvider);
      if (!context.mounted) return;
      final l10nAfter = AppLocalizations.of(context)!;
      messenger.showSnackBar(
        SnackBar(
          content: Text(l10nAfter.gamifStatsNameChangeSuccessToastSabi_message),
          backgroundColor: AppTheme.primary,
        ),
      );
    } catch (e) {
      if (!context.mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text(formatApiError(e))),
      );
    }
  }

  Widget _buildAllocatableBanner(int points) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            Colors.orange.withValues(alpha: 0.3),
            Colors.deepOrange.withValues(alpha: 0.1),
          ],
        ),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.orange.withValues(alpha: 0.5)),
      ),
      child: Row(
        children: [
          const Icon(Icons.arrow_upward, color: Colors.orange, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  AppLocalizations.of(context)!.gamifStatsAllocatablePoints(points),
                  style: const TextStyle(
                      color: Colors.orange, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 2),
                Text(
                  AppLocalizations.of(context)!.gamifStatsPointDescription,
                  style: const TextStyle(color: Colors.orange, fontSize: 11),
                ),
                if (points >= 5) ...[
                  const SizedBox(height: 4),
                  Text(
                    AppLocalizations.of(context)!.gamifStatsPointLongPressHint,
                    style: const TextStyle(color: Colors.orange, fontSize: 11),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── _NavBanner — 実績・称号用バナー ────────────────────────────────────────

class _NavBanner extends StatelessWidget {
  final String emoji;
  final String label;
  final VoidCallback onTap;

  // 【2026-07-02 dead code cleanup】optional な `sub` パラメータを削除。
  // 全呼び出し箇所で sub を渡していないため実質 dead code (前回レビュー 6/29 継続指摘)。
  // 将来サブテキストを再表示したい場合は git history から復活可能。
  const _NavBanner({
    required this.emoji,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: AppTheme.cardBackground,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppTheme.primary.withValues(alpha: 0.3)),
        ),
        child: Row(
          children: [
            Text(emoji, style: const TextStyle(fontSize: 24)),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(label,
                      style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 14)),
                ],
              ),
            ),
            Icon(Icons.chevron_right,
                color: Colors.white.withValues(alpha: 0.3), size: 18),
          ],
        ),
      ),
    );
  }
}

// 【2026-07-05】_EconomyCard クラス撤去済 (使用箇所ゼロのため物理削除)。
// 旧: ショップ / ガチャ / キャラ変更 の 3 ボタン共通カード widget。
// 動線は BottomNav (ギルド) + Home/Guild Drawer (ガチャ / キャラ変更) に移動。

// ── _FloatingPointsBadge — FEAT-115: スクロール時のフローティングバッジ ─────

class _FloatingPointsBadge extends StatelessWidget {
  final int points;
  final VoidCallback onTap;

  const _FloatingPointsBadge({
    required this.points,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        decoration: BoxDecoration(
          // オレンジグラデーション（上部バナーと色調を合わせる）
          gradient: LinearGradient(
            colors: [
              Colors.orange.shade700,
              Colors.deepOrange.shade600,
            ],
          ),
          borderRadius: BorderRadius.circular(28),
          // 浮いている感を出す影
          boxShadow: [
            BoxShadow(
              color: Colors.orange.withValues(alpha: 0.45),
              blurRadius: 14,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.bolt, color: Colors.white, size: 16),
            const SizedBox(width: 6),
            Text(
              AppLocalizations.of(context)!.gamifStatsAllocatablePointsHeader(points),
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 13,
                letterSpacing: 0.3,
              ),
            ),
            const SizedBox(width: 6),
            const Icon(Icons.keyboard_arrow_up, color: Colors.white70, size: 16),
          ],
        ),
      ),
    );
  }
}

// ── _StatCard — ポイント割り振り（長押し連続割り振り対応） ────────────────

class _StatCard extends ConsumerStatefulWidget {
  final CharacterStat stat;
  final int allocatable;

  const _StatCard({required this.stat, required this.allocatable});

  @override
  ConsumerState<_StatCard> createState() => _StatCardState();
}

class _StatCardState extends ConsumerState<_StatCard> {
  Timer?    _longPressTimer;
  bool      _pressing        = false;
  // FEAT-112: 長押し加速
  bool      _isLongPressing  = false;
  bool      _isAllocating    = false;   // 並行呼び出し防止
  Duration  _interval        = const Duration(milliseconds: 350);
  DateTime? _longPressStart;
  // FEAT-112: EXP バーアニメーション用の前回値
  double    _prevExpRate     = 0.0;

  static const _statMeta = {
    '運動力': ('💪', '運動'),
    '学習力': ('📚', '学習'),
    '健康力': ('❤️', '健康'),
    '精神力': ('🧘', '精神'),
    '創造力': ('🎨', '創造'),
    '貢献力': ('🤝', '社交'),
  };

  /// 【FEAT-489 Phase 2C follow-up】switch の重複定義を避けるため
  /// `StatHexagonChart.fullNameFor` に一本化 (level_up_dialog と共有)。
  static String _statFullNameFor(AppLocalizations l10n, String statName) =>
      StatHexagonChart.fullNameFor(l10n, statName);

  static String _statCategoryFor(AppLocalizations l10n, String statName) {
    return switch (statName) {
      '運動力' => l10n.gamifStatHexagonLabelExercise,
      '学習力' => l10n.gamifStatHexagonLabelStudy,
      '健康力' => l10n.gamifStatHexagonLabelHealth,
      '精神力' => l10n.gamifStatHexagonLabelMental,
      '創造力' => l10n.gamifStatHexagonLabelCreativity,
      '貢献力' => l10n.gamifStatHexagonLabelContribution,
      _ => '',
    };
  }

  @override
  void didUpdateWidget(_StatCard old) {
    super.didUpdateWidget(old);
    // FEAT-112: EXP バーアニメーション用に前回の expRate を保存
    if (old.stat.expRate != widget.stat.expRate) {
      _prevExpRate = old.stat.expRate;
    }
  }

  @override
  void dispose() {
    _longPressTimer?.cancel();
    super.dispose();
  }

  Future<bool> _doAllocate() async {
    if (_isAllocating) return false;
    _isAllocating = true;
    try {
      return await ref
          .read(statsNotifierProvider.notifier)
          .allocate(widget.stat.id);
    } on DioException catch (e) {
      // 【2026-07-08 hotfix】長押し連打の race condition:
      // client `widget.allocatable` の rebuild が Backend の
      // `allocatable_points <= 0` 判定より 200-300ms 遅れる窓があり、
      // 最後の 1-2 tick で 400 (割り振れるポイントがありません) が返る
      // ことがある。Backend の期待動作 (guard) + 実害なし
      // (二重消費は select_for_update で保護) なので silent 処理して
      // Sentry ノイズ化を防ぐ。他ステータスコードは throw 継続。
      // 参考: player.py:404-408 StatAllocateView の唯一の 400 経路。
      if (e.response?.statusCode == 400) return false;
      rethrow;
    } finally {
      if (mounted) _isAllocating = false;
    }
  }

  // 単発タップ
  Future<void> _handleTap() async {
    if (widget.allocatable <= 0) return;
    await _doAllocate();
  }

  // FEAT-112: 長押し開始（500ms 認識後）
  void _onLongPressStart(LongPressStartDetails _) {
    if (widget.allocatable <= 0) return;
    _isLongPressing = true;
    _longPressStart = DateTime.now();
    _interval       = const Duration(milliseconds: 350);
    // BUG-41: 長押し中の画面遷移で dispose 済みの State に setState されないようガード
    if (mounted) setState(() => _pressing = true);
    _doAllocate(); // 最初の 1 回を即時実行
    _scheduleNext();
  }

  void _scheduleNext() {
    if (!_isLongPressing || widget.allocatable <= 0 || !mounted) {
      _stopLongPress();
      return;
    }
    _longPressTimer = Timer(_interval, () async {
      await _doAllocate();
      if (_isLongPressing && widget.allocatable > 0 && mounted) {
        _accelerate();
        _scheduleNext();
      } else {
        _stopLongPress();
      }
    });
  }

  // FEAT-112: 保持時間に応じて間隔を短縮（0.8s ごとに 1 段階、最速 100ms）
  void _accelerate() {
    if (_longPressStart == null) return;
    final elapsed  = DateTime.now().difference(_longPressStart!).inMilliseconds;
    final stage    = (elapsed ~/ 800).clamp(0, 4);
    final targetMs = 350 - stage * 50; // 350 → 300 → 250 → 200 → 150ms
    _interval = Duration(milliseconds: targetMs.clamp(100, 350));
  }

  void _stopLongPress() {
    _isLongPressing = false;
    _longPressTimer?.cancel();
    _longPressTimer = null;
    _interval       = const Duration(milliseconds: 350);
    _longPressStart = null;
    if (mounted) setState(() => _pressing = false);
  }

  void _onLongPressEnd(LongPressEndDetails _) {
    _stopLongPress();
  }

  void _onLongPressCancel() {
    _stopLongPress();
  }

  /// 【FEAT-382 (2026-05-29)】FEAT-333 stat → 戦闘能力 1:1 連動の可視化ラベル。
  ///
  /// gameplay_review 20260528 P1-1「FEAT-333 学習導線 = stat が戦闘でどう効くか
  /// 説明 UI が不在」を解消、「ステの数字 = 戦闘での自分の強さ」を 1 行で明示。
  ///
  /// 連動式真実値 (battle_provider.dart:563-569 _buildPlayerCombatant 内):
  ///   運動力 → maxHp += level × 5             (Lv 5 で +25 HP)
  ///   学習力 → atk += level × 1               (Lv 5 で +5 ATK)
  ///   健康力 → 毎 turn HP 自動回復 +level × 2  (Lv 5 で +10 HP/turn)
  ///   精神力 → atbSpeedModifier += level × 0.01 (Lv 5 で +5% 充填速度)
  ///   創造力 → critRate = level × 0.005         (Lv 5 で 2.5% クリ率)
  ///   貢献力 → damageReduction = level × 0.005  (Lv 5 で 2.5% 被ダメ軽減)
  ///
  /// レビュー提示式 (運動力 × 10、学習力 × 2 等) は実装と乖離あり、
  /// REVIEWER_LESSONS §2「定数を変更推奨する前に過去経緯確認」原則で実装値採用。
  String _battleEffectLabel(AppLocalizations l10n, String name, int level) {
    switch (name) {
      case '運動力':
        return l10n.gamifStatsEffectHp(level * 5);
      case '学習力':
        return l10n.gamifStatsEffectAtk(level);
      case '健康力':
        return l10n.gamifStatsEffectRegen(level * 2);
      case '精神力':
        return l10n.gamifStatsEffectAtb(level);
      case '創造力':
        return l10n.gamifStatsEffectCrit((level * 0.5).toStringAsFixed(1));
      case '貢献力':
        return l10n.gamifStatsEffectMitigation((level * 0.5).toStringAsFixed(1));
      default:
        return '';
    }
  }

  /// 【20260729 gameplay-review §3 要素 C-2 対応】各 stat に「習慣がどう自分を
  /// 作り変えたか」の 1 行を添える。機械的な数値ラベル (`_battleEffectLabel`)
  /// を「あなたの積み上げがこう効いていますよ」の物語に接続する。
  ///
  /// 貢献力 → 被ダメ軽減の「人のために動いた時間 = 巡ってあなたを守る」の
  /// 因果は、Sabiowl で最も美しい利己的利他のメカニクスであり、機械的な
  /// パーセンテージだけでは提示されていなかった。6 軸すべてに 1 行添えることで、
  /// stat 詳細画面が「習慣が自分をどう作り変えたか」の物語になる。
  String _habitStoryLabel(AppLocalizations l10n, String name) {
    switch (name) {
      case '運動力':
        return l10n.gamifStatsExerciseSabi_message;
      case '学習力':
        return l10n.gamifStatsStudySabi_message;
      case '健康力':
        return l10n.gamifStatsHealthSabi_message;
      case '精神力':
        return l10n.gamifStatsMentalSabi_message;
      case '創造力':
        return l10n.gamifStatsCreativitySabi_message;
      case '貢献力':
        return l10n.gamifStatsContributionSabi_message;
      default:
        return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n     = AppLocalizations.of(context)!;
    final meta     = _statMeta[widget.stat.name];
    final icon     = meta?.$1 ?? '⭐';
    final category = _statCategoryFor(l10n, widget.stat.name);
    final bonusPct = (widget.stat.level * 5).clamp(0, 50);
    final canAlloc = widget.allocatable > 0;

    return Container(
      // 【2026-06-27】カード縦幅を圧縮するため margin / padding / 内部 SizedBox を
      // 縮減 (フォントサイズは触らず視認性維持)。
      //   margin   12 → 8
      //   padding  16 → 12
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        // 【FEAT-293】AppTheme.surface → AppTheme.card で視認性確保（ステータス
        // カードはホーム画面の主要視覚要素、carpet 描画されると体験悪化）
        color: AppTheme.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── ヘッダー行（アイコン・名前・割り振りボタン）──────────
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              // 【2026-08-02 hotfix】内側 Column を Expanded で包む。
              //
              // 旧実装は Row の子に裸の Column を置いていたため、Column の子 Text
              // (_battleEffectLabel / _habitStoryLabel) が幅制約を受けず、長い
              // 台詞で RenderFlex overflow を起こしていた (実機で運動力 24 文字 /
              // 貢献力 26 文字の 2 stat が OVERFLOWED 表示)。
              //
              // Expanded で残り幅を与えると Text が自然に折り返す。ellipsis では
              // なく折り返しを選ぶのは、この 2 行が「習慣がどう自分を作り変えたか」
              // を伝える本文であり、途中で切ると意味が失われるため。
              // CLAUDE.md「Row 内 Text は Flexible + 制約幅確認」(FEAT-298 hotfix)。
              Expanded(
                child: Row(
                  children: [
                    Text(icon, style: const TextStyle(fontSize: 22)),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(_statFullNameFor(l10n, widget.stat.name),
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 15,
                                  fontWeight: FontWeight.bold)),
                          Text('Lv.${widget.stat.level}',
                              style: const TextStyle(
                                  color: AppTheme.primary,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600)),
                          // 【FEAT-382 (2026-05-29)】FEAT-333 stat → 戦闘能力 1:1 連動の可視化。
                          // gameplay_review 20260528 P1-1 指摘「FEAT-333 学習導線 = stat が
                          // 戦闘でどう効くか説明 UI が不在」を解消、「ステの数字 = 戦闘での
                          // 自分の強さ」を 1 行サブテキストで明示。
                          // 連動式真実値は battle_provider.dart:563-569 (FEAT-333) を参照、
                          // レビュー提示式は誤差あり (REVIEWER_LESSONS §2 原則で実装値採用)。
                          Text(
                            _battleEffectLabel(
                                l10n, widget.stat.name, widget.stat.level),
                            // 【2026-06-27】カードスリム化に伴い line-height 1.3 → 1.15。
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.55),
                              fontSize: 11,
                              height: 1.15,
                            ),
                          ),
                          // 【20260729 gameplay-review §3 要素 C-2 対応】
                          // 「習慣がどう自分を作り変えたか」の 1 行を添える。機械的な
                          // 数値ラベルを、あなたの積み上げの物語として提示する。
                          const SizedBox(height: 2),
                          Text(
                            _habitStoryLabel(l10n, widget.stat.name),
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.38),
                              fontSize: 10,
                              height: 1.3,
                              fontStyle: FontStyle.italic,
                            ),
                            maxLines: 2,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

              // ── +1 ボタン（長押し加速・押下ビジュアル改善）──────────
              if (canAlloc)
                GestureDetector(
                  // FEAT-112: 単発タップと長押しを分離（誤発火防止）
                  onTap: _handleTap,
                  // FEAT-112: 指を置いた瞬間（500ms 前）にビジュアル変化
                  // BUG-41: ジェスチャーアリーナ遅延配信で dispose 済みでも届くため mounted ガード
                  onLongPressDown: (_) {
                    if (mounted) setState(() => _pressing = true);
                  },
                  onLongPressStart: _onLongPressStart,
                  onLongPressEnd: _onLongPressEnd,
                  onLongPressCancel: _onLongPressCancel,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 100),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 8),
                    decoration: BoxDecoration(
                      // FEAT-112: 押下中はボタンが沈む（darker）感覚
                      color: _pressing
                          ? Colors.orange.shade700
                          : Colors.orange,
                      borderRadius: BorderRadius.circular(20),
                      // FEAT-112: 長押し中は影なし（押し込み感）
                      boxShadow: _pressing
                          ? null
                          : [
                              BoxShadow(
                                color: Colors.orange.withValues(alpha: 0.35),
                                blurRadius: 6,
                                offset: const Offset(0, 2),
                              ),
                            ],
                    ),
                    // FEAT-112: 押下中は微縮（タッチフィードバック）
                    transform: _pressing
                        ? (Matrix4.identity()..scale(0.95))
                        : Matrix4.identity(),
                    transformAlignment: Alignment.center,
                    // BUG-39: 旧実装は Icon(Icons.add) と Text('+1') を両方並べており、
                    // ボタン上で「+」が2つ並ぶように見えていた。Text('+1') のみを残す。
                    child: const Text(
                      '+1',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ),
            ],
          ),

          // ── ボーナス表示 ───────────────────────────────────────
          // 【2026-06-27】カードスリム化: 上余白 10→6、ボーナスチップ vertical 5→3。
          if (category.isNotEmpty) ...[
            const SizedBox(height: 6),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
              decoration: BoxDecoration(
                color: AppTheme.primary.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                    color: AppTheme.primary.withValues(alpha: 0.25)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.bolt, size: 13, color: AppTheme.primary),
                  const SizedBox(width: 4),
                  Text(
                    l10n.gamifStatsBonusExpLabel(category, bonusPct),
                    style: const TextStyle(
                        color: AppTheme.primary,
                        fontSize: 12,
                        fontWeight: FontWeight.w500),
                  ),
                ],
              ),
            ),
          ],

          // ── EXP バー ───────────────────────────────────────────
          // 【2026-06-27】カードスリム化: 上余白 10→6、EXP テキスト〜バー 6→4。
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '${widget.stat.currentExp} / ${widget.stat.maxExp} EXP',
                style: TextStyle(
                    fontSize: 11,
                    color: Colors.white.withValues(alpha: 0.5)),
              ),
              Text(
                '${(widget.stat.expRate * 100).toInt()}%',
                style: TextStyle(
                    fontSize: 11,
                    color: Colors.white.withValues(alpha: 0.5)),
              ),
            ],
          ),
          const SizedBox(height: 4),
          // FEAT-112: TweenAnimationBuilder でポイント割り振り後に EXP バーが
          // 滑らかに伸びる。300ms easeOut でゲームらしい増加感を演出。
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: TweenAnimationBuilder<double>(
              tween: Tween<double>(
                begin: _prevExpRate,
                end: widget.stat.expRate,
              ),
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOut,
              builder: (_, value, __) => LinearProgressIndicator(
                value: value,
                minHeight: 6,
                backgroundColor: Colors.white.withValues(alpha: 0.1),
                valueColor: AlwaysStoppedAnimation<Color>(
                  widget.stat.level >= 10
                      ? Colors.orange
                      : AppTheme.primary,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}


// ─────────────────────────────────────────────────────────────────────────────
// 【FEAT-379 (2026-05-29)】結晶インベントリ (Coming Soon) カード
// ─────────────────────────────────────────────────────────────────────────────

class _CrystalInventoryCard extends StatelessWidget {
  final Player player;
  const _CrystalInventoryCard({required this.player});

  /// 【FEAT-489 Phase 2F-a】旧 tuple 第 2 要素の日本語名を削除。
  /// build() 側で `final (key, _, icon) = meta;` と destructure して捨てており、
  /// 表示は下の l10n switch が担っていた (= 未使用の日本語データだった)。
  static const _crystalMeta = [
    ('exercise',     Icons.fitness_center),
    ('learning',     Icons.book),
    ('health',       Icons.favorite),
    ('mental',       Icons.spa),
    ('creation',     Icons.palette),
    ('contribution', Icons.volunteer_activism),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.lightBlue.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 【gameplay_review 20260530 §2-1 P3 → Priority 1-①】
          // 視認性向上: subtitle (fontSize 11 / white54) → title 横に「7 月 解禁」
          // バッジ格上げ + subtitle を primary 色強調。「壊れている」ではなく
          // 「期待」として読まれるようにする。
          ListTile(
            leading: const Icon(Icons.diamond, color: Colors.lightBlueAccent),
            title: Row(
              children: [
                Flexible(
                  child: Text(AppLocalizations.of(context)!.gamifStatsCrystalInventoryTitle,
                      style: const TextStyle(color: Colors.white, fontSize: 15)),
                ),
                const SizedBox(width: 8),
                // 【BUG-123 (2026-06-14)】「解禁予定」バッジ (時期は伏せる、PM 判断)。
                // 旧「7 月 解禁予定」→「今後 解禁予定」: 期日コミットを避ける。
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: Colors.lightBlueAccent.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: Colors.lightBlueAccent.withValues(alpha: 0.45),
                      width: 0.8,
                    ),
                  ),
                  child: Text(
                    AppLocalizations.of(context)!.gamifStatsCrystalComingSoon,
                    style: const TextStyle(
                      color: Colors.lightBlueAccent,
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            subtitle: Text(
              AppLocalizations.of(context)!.gamifStatsCrystalDescriptionSabi_message,
              style: const TextStyle(
                color: Colors.lightBlueAccent,
                fontSize: 11.5,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          const Divider(color: Colors.white12, height: 1),
          const SizedBox(height: 8),
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            childAspectRatio: 3.0,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            children: _crystalMeta.map((meta) {
              final l10n = AppLocalizations.of(context)!;
              final (key, icon) = meta;
              final count = player.crystals[key];
              final crystalName = switch (key) {
                'exercise'     => l10n.gamifStatsCrystalExercise,
                'learning'     => l10n.gamifStatsCrystalStudy,
                'health'       => l10n.gamifStatsCrystalHealth,
                'mental'       => l10n.gamifStatsCrystalMental,
                'creation'     => l10n.gamifStatsCrystalCreativity,
                'contribution' => l10n.gamifStatsCrystalContribution,
                _              => key,
              };
              return Row(
                children: [
                  Icon(icon, size: 16, color: Colors.lightBlueAccent.withValues(alpha: 0.8)),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(crystalName,
                        style: const TextStyle(color: Colors.white70, fontSize: 11),
                        overflow: TextOverflow.ellipsis),
                  ),
                  Text('$count',
                      style: const TextStyle(
                        color: Colors.lightBlueAccent,
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                      )),
                  const SizedBox(width: 4),
                ],
              );
            }).toList(),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}
