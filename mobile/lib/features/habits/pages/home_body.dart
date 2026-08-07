// ┌─────────────────────────────────────────────────────────────────────────┐
// │ 【運用ルール】ホームに新セクション/表示を追加する開発者は必ず            │
// │   `home_bootstrap_provider.dart` 冒頭の判断フロー Q1/Q2 を通し、        │
// │   判断根拠を PR / commit message + 追加セクションの docstring に       │
// │   1 行残すこと (bootstrap 統合 or 独立 fetch)。                         │
// │                                                                          │
// │ Q1: LCP 内で描画される機能 → bootstrap 統合 (HomeBootstrapView に      │
// │     field 追加、bootstrapXxxProvider を経由して読む)                   │
// │ Q2: 独立 fetch 正当 → autoDispose + docstring で理由 1 行明記         │
// │                                                                          │
// │ 過去の逸脱事例 (codebase-functional-review 20260725 §2-2):              │
// │   FEAT-493 `_FreeMemoSection` が独立 fetch で全メモ本文を取得 →         │
// │   後日 free_memo_count 統合で修正 (整数 1 個化)。同じ轍を踏まない。    │
// └─────────────────────────────────────────────────────────────────────────┘

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/providers/time_segment_provider.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/time_segment_theme.dart';
import '../../../l10n/app_localizations.dart';
import '../../announcement/widgets/announcement_popup_listener.dart';
import '../../free_memo/providers/free_memo_provider.dart';  // 【FEAT-493】
import '../../social/widgets/friend_gift_popup_listener.dart';
import '../../../shared/widgets/offline_indicator.dart';
import '../../../shared/widgets/sabi_loading_skeleton.dart';
import '../../../shared/widgets/stacking_chart.dart';
import '../../sabi/providers/sabi_provider.dart';
import '../../sabi/widgets/sabi_speech_panel.dart';
import '../../stats/providers/stats_provider.dart';
import '../../puzzle_world/providers/puzzle_world_provider.dart';  // 【2026-07-09 hotfix】pull-to-refresh
import '../../puzzle_world/widgets/puzzle_world_home_widgets.dart';  // 【FEAT-479】
import '../../timeline/widgets/timeline_dashboard.dart';
import '../models/habit.dart' show Habit;
import '../providers/habits_provider.dart';
import '../providers/home_bootstrap_provider.dart';
import '../widgets/habit_card.dart';
import '../widgets/habit_filter_bar.dart';
import '../widgets/player_status_frame.dart';
import '../widgets/todo_section.dart';
import '../widgets/sabi_habit_onboarding_flow.dart';
import '../widgets/world_frame/world_frame_section.dart';
import 'add_habit_page.dart' show showAddHabitModal;

/// 【FEAT-473 Phase 2 (2026-07-04)】ホーム画面の body Stack を切出した widget。
/// Scaffold + AppBar は home_page.dart が管理し、_statusFrameOpen / _sabiPanelOpen
/// の状態もそちらで保持する。コールバック経由で状態変化を親に通知する設計。
class HomeBody extends ConsumerWidget {
  const HomeBody({
    required this.statusFrameOpen,
    required this.sabiPanelOpen,
    required this.onStatusFrameClose,
    required this.onSabiPanelClose,
    super.key,
  });

  final bool statusFrameOpen;
  final bool sabiPanelOpen;
  final VoidCallback onStatusFrameClose;
  final VoidCallback onSabiPanelClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n            = AppLocalizations.of(context)!;
    final timeSegment     = ref.watch(timeSegmentProvider);
    final segTheme        = TimeSegmentTheme.of(timeSegment);
    final playerAsync     = ref.watch(playerNotifierProvider);
    final habitsAsync     = ref.watch(habitsNotifierProvider);
    // サビセリフを裏読み (prefetch): SabiSpeechPanel 表示時点でキャッシュ済みにする。
    // ignore: unused_result
    ref.watch(sabiMessageProvider);
    final currentFilter   = ref.watch(habitFilterProvider);
    final currentCategory = ref.watch(habitCategoryFilterProvider);
    final currentType     = ref.watch(habitTypeFilterProvider);

    return Stack(
      children: [
        // ── グラジェント背景 ────────────────────────────────────────
        Positioned.fill(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 800),
            curve: Curves.easeInOut,
            decoration: BoxDecoration(gradient: segTheme.gradient),
          ),
        ),
        // 【FEAT-452 / FEAT-454】フレンドプレゼント popup listener。
        // Positioned 必須: SizedBox.shrink の 0×0 が Stack sizing 計算に含まれないよう。
        const Positioned(
          top: 0, left: 0,
          child: FriendGiftPopupListener(),
        ),
        // 【FEAT-458】お知らせ popup listener（同パターン）
        const Positioned(
          top: 0, left: 0,
          child: AnnouncementPopupListener(),
        ),
        // 【FEAT-479 Phase 3 (2026-07-06)】パズルピース overlay listener。
        // 【global hotfix 2026-07-07】main.dart の MaterialApp.router.builder に
        // 移設済 (常時 mount で Guild / Timeline / Battle 等の全画面で quest
        // piece 演出発火するように、ref.listen が edge-triggered で状態変化を
        // 見逃す bug を構造解消)。旧ここでの配置は撤去。
        // ── スクロール可能コンテンツ ────────────────────────────────
        Positioned.fill(
          child: RefreshIndicator(
            onRefresh: () async {
              // P0-1: bootstrap を再フェッチして全 state を一括更新
              ref.invalidate(homeBootstrapRawProvider);
              ref.invalidate(playerNotifierProvider);
              ref.invalidate(habitsNotifierProvider);
              ref.invalidate(stats30dProvider);
              // 【2026-06-26】sabi メッセージ refresh: カウンタを +1 して再フェッチ
              ref.read(sabiRefreshCounterProvider.notifier).state++;
              // 【2026-07-09 hotfix】WorldFrame の scene 状態も pull-to-refresh 対象に。
              //
              // 【症状】user 報告: 「昼の城下町を再生中にしたのに、ホームに目覚めの山頂の
              //         かけら 0 個状態が表示される」= _resolveSceneRender の fallback
              //         branch (C) 発火 (morning_grassland + [0,0,0] 固定表示)。
              // 【原因】puzzleWorldStatusProvider の初回 fetch が connection error 等で
              //         AsyncError に落ちた場合、pull-to-refresh の invalidate 対象から
              //         漏れていたため、user は home 以外の tab に navigate → 戻る の
              //         副次経路でしか retry できなかった (autoDispose の re-mount 契機)。
              // 【修正】home pull-to-refresh で明示的に invalidate、user 主体で retry 可に。
              ref.invalidate(puzzleWorldStatusProvider);
            },
            child: NotificationListener<ScrollNotification>(
              onNotification: (notification) {
                // 【FEAT-474】スクロール下端 -300px で次ページ読み込み
                if (notification.metrics.pixels >
                    notification.metrics.maxScrollExtent - 300) {
                  ref.read(habitsNotifierProvider.notifier).loadMore();
                }
                return false;
              },
              child: CustomScrollView(
                slivers: [
                  // 【FEAT-318】XP ブースト中の橙色チップ
                  const SliverToBoxAdapter(child: _XpBoostChip()),

                  // ステータス枠スペーサー（開閉アニメーション）
                  SliverToBoxAdapter(
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 250),
                      curve: Curves.easeOutCubic,
                      height: statusFrameOpen ? kPlayerStatusFrameSpacerHeight : 0.0,
                    ),
                  ),

                  // 生きた世界 額縁アニメーション
                  const SliverToBoxAdapter(
                    child: WorldFrameSection(),
                  ),

                  // 【FEAT-493 (2026-07-25)】フリーメモセクション (opt-in ON 時のみ表示)
                  // 配置: ワールドフレーム下、タイムラインセクションの上
                  const SliverToBoxAdapter(
                    child: _FreeMemoSection(),
                  ),

                  // 【FEAT-479 Phase 2c (2026-07-06)】パズル世界の Home widgets:
                  // - PuzzleWorldOnboardingBanner: needsOnboarding 時のみ表示
                  //   (session-scoped dismiss、× で 1 セッション消せる)
                  // 【FEAT-479 hotfix (2026-07-06)】PuzzleWorldMiniStrip 撤去。
                  // WorldFrame 自体に 30 分割ピース overlay を持つため、
                  // 直下の重複表示は不要 (ユーザー要件)。
                  const SliverToBoxAdapter(
                    child: PuzzleWorldOnboardingBanner(),
                  ),

                  // タイムラインダッシュボード（週カレンダー + 垂直タイムライン）
                  const SliverToBoxAdapter(
                    child: TimelineDashboard(),
                  ),

                  // ToDo セクション（HabitFilterBar の上）
                  const SliverToBoxAdapter(child: TodoSection()),

                  // ToDo↔習慣の間隔スペーサー
                  const SliverToBoxAdapter(child: SizedBox(height: 8)),

                  // 習慣リストヘッダー（フィルターバー）
                  const SliverToBoxAdapter(child: HabitFilterBar()),

                  // 習慣リスト（ToDo を除外して表示）
                  habitsAsync.when(
                    data: (habits) {
                      final filtered = habits.where((h) {
                        if (h.isTodo) return false;
                        final matchFreq = currentFilter == null ||
                            h.frequency == currentFilter;
                        final matchCat = currentCategory == null ||
                            h.category == currentCategory;
                        // 【BUG-134】タイプフィルタ追加 (count / checklist)
                        final matchType = currentType == null ||
                            h.habitType == currentType;
                        return matchFreq && matchCat && matchType;
                      }).toList();

                      if (filtered.isEmpty) {
                        return SliverToBoxAdapter(
                          child: _buildEmptyState(
                            context,
                            currentFilter,
                            currentCategory,
                            currentType,
                          ),
                        );
                      }
                      return SliverPadding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                        sliver: SliverReorderableList(
                          itemCount: filtered.length,
                          // 【FEAT-441】drag_indicator ハンドル経由のみ並び替え発火
                          itemBuilder: (context, index) => HabitCard(
                            key: ValueKey(filtered[index].id),
                            habit: filtered[index],
                            leading: ReorderableDragStartListener(
                              index: index,
                              child: Padding(
                                padding: const EdgeInsets.only(left: 8, right: 2),
                                child: Icon(
                                  Icons.drag_indicator,
                                  color: Colors.white.withValues(alpha: 0.35),
                                  size: 22,
                                ),
                              ),
                            ),
                          ),
                          onReorder: (oldIndex, newIndex) {
                            if (currentFilter != null ||
                                currentCategory != null) {
                              return;
                            }
                            // 【FEAT-418 hotfix】filtered 上で並び替え後、
                            // habits 全体を再構築して Backend に渡す
                            final newFiltered = [...filtered];
                            if (newIndex > oldIndex) newIndex--;
                            final item = newFiltered.removeAt(oldIndex);
                            newFiltered.insert(newIndex, item);

                            final filteredIdSet =
                                filtered.map((h) => h.id).toSet();
                            final newOrder = <Habit>[];
                            var idx = 0;
                            for (final h in habits) {
                              if (filteredIdSet.contains(h.id)) {
                                newOrder.add(newFiltered[idx++]);
                              } else {
                                newOrder.add(h); // ToDo はその位置を維持
                              }
                            }
                            ref
                                .read(habitsNotifierProvider.notifier)
                                .reorderHabits(newOrder);
                          },
                        ),
                      );
                    },
                    // 【FEAT-202】Shimmer スケルトン（回転円の代わりに実カード形状）
                    loading: () => const SliverToBoxAdapter(
                      child: Padding(
                        padding: EdgeInsets.symmetric(vertical: 8),
                        child: HabitListSkeleton(count: 3),
                      ),
                    ),
                    error: (e, _) => SliverToBoxAdapter(
                      child: _buildErrorCard(l10n.habitHomeErrorSabi_message),
                    ),
                  ),

                  // 【FEAT-204】「あなたが積み上げた地層」セクション
                  SliverToBoxAdapter(
                    child: Consumer(
                      builder: (context, ref, _) {
                        final stats30d = ref.watch(stats30dProvider);
                        return stats30d.when(
                          loading: () => const Padding(
                            padding: EdgeInsets.fromLTRB(16, 16, 16, 0),
                            child: SizedBox(
                              height: 80,
                              child: SabiSkeletonBox(
                                  width: double.infinity, height: 80),
                            ),
                          ),
                          error: (_, __) => const SizedBox.shrink(),
                          data: (data) => Padding(
                            padding:
                                const EdgeInsets.fromLTRB(16, 24, 16, 8),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  l10n.habitHomeAchievementsTitle,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                // 【FEAT-404】「今週と先週の比較」に変更
                                const SizedBox(height: 2),
                                Text(
                                  l10n.habitHomeWeekComparisonSubtitle,
                                  style: TextStyle(
                                    color:
                                        Colors.white.withValues(alpha: 0.45),
                                    fontSize: 11,
                                  ),
                                ),
                                const SizedBox(height: 12),
                                MilestoneChip(
                                  currentStreak: data.currentStreak,
                                  nextMilestone: data.nextMilestone,
                                  daysRemaining: data.daysToNextMilestone,
                                ),
                                const SizedBox(height: 16),
                                Container(
                                  decoration: BoxDecoration(
                                    color: AppTheme.card,
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                  child: StackingChart(data: data.days),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),

                  // 【FEAT-474】続き読み込み中スピナー
                  SliverToBoxAdapter(
                    child: Consumer(
                      builder: (context, ref, _) {
                        final isLoading =
                            ref.watch(habitsIsLoadingMoreProvider);
                        if (!isLoading) return const SizedBox.shrink();
                        return const Padding(
                          padding: EdgeInsets.symmetric(vertical: 16),
                          child: Center(child: CircularProgressIndicator()),
                        );
                      },
                    ),
                  ),

                  SliverPadding(
                    padding: EdgeInsets.only(
                      bottom: MediaQuery.of(context).padding.bottom + 100,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),

        // 【FEAT-280 hotfix】オフライン / 最新化中インジケータ（最前面に配置）
        const Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: OfflineIndicator(),
        ),

        // ── オーバーレイパネル: プロフィール枠 + サビセリフパネル ────────────
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // ── ① プロフィールカード（上に表示）─────────────────
              IgnorePointer(
                ignoring: !statusFrameOpen,
                child: AnimatedSize(
                  duration: const Duration(milliseconds: 250),
                  curve: Curves.easeOutCubic,
                  child: AnimatedOpacity(
                    duration: const Duration(milliseconds: 200),
                    curve: Curves.easeOut,
                    opacity: statusFrameOpen ? 1.0 : 0.0,
                    child: statusFrameOpen
                        ? playerAsync.maybeWhen(
                            data: (player) => PlayerStatusFrame(
                              player: player,
                              onLongPress: () {
                                onStatusFrameClose();
                                context.push(AppRoutes.stats);
                              },
                            ),
                            orElse: () => const SizedBox.shrink(),
                          )
                        : const SizedBox.shrink(),
                  ),
                ),
              ),

              // ── ② サビセリフパネル（プロフィールカードの直下）───────
              SabiSpeechPanel(
                open: sabiPanelOpen,
                onCloseTap: onSabiPanelClose,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildEmptyState(
    BuildContext context,
    String? filter,
    String? category,
    String? type,
  ) {
    final l10n = AppLocalizations.of(context)!;
    if (filter != null || category != null || type != null) {
      final freqPart = switch (filter) {
        'daily'   => l10n.habitHomeFilterFreqToday,
        'weekly'  => l10n.habitHomeFilterFreqWeek,
        'monthly' => l10n.habitHomeFilterFreqMonth,
        _         => null,
      };
      // 【BUG-134】タイプ表示ラベル (FilterBar の typeLabel と同じ定義)
      final typePart = switch (type) {
        'count'     => l10n.habitHomeFilterTypeCount,
        'checklist' => l10n.habitHomeFilterTypeChecklist,
        _           => null,
      };
      final parts = [
        if (freqPart != null) freqPart,
        if (category != null) category,
        if (typePart != null) typePart,
      ];
      final label   = parts.join(' × ');
      final message = l10n.habitHomeEmptyFilterSabi_message(label);
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 24),
        child: Text(
          message,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.4),
            fontSize: 14,
            height: 1.6,
          ),
        ),
      );
    }

    return SabiHabitOnboardingFlow(
      onAddHabit: () => showAddHabitModal(context),
    );
  }

  Widget _buildErrorCard(String message) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.red.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.red.withValues(alpha: 0.3)),
        ),
        child: Row(
          // 【FEAT-321】Expanded で Row overflow を防ぐ
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.error_outline, color: Colors.red),
            const SizedBox(width: 8),
            Expanded(
              child:
                  Text(message, style: const TextStyle(color: Colors.red)),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _FreeMemoSection — 【FEAT-493 (2026-07-25)】ホーム画面フリーメモセクション
//
// 表示条件:
//   - PlayerProfile.free_memo_enabled == true (opt-in ON)
//   - 未整理メモ件数 > 0
// 件数 0 時: SizedBox.shrink() (セクション自体を非表示)
// 30 件超時: 穏やかな警告テキストを追加 (サビ character)
//
// 【2026-07-25 codebase-functional-review 20260725 対応 (P1 #2)】
// 旧実装は freeMemoNotifierProvider を watch → 全メモ本文取得 → length を
// 数えていた (500 字 × 件数を above-the-fold で毎回転送)。用途は「未整理の
// メモ (N)」の整数 1 個のみ = 過大取得。ホーム bootstrap に free_memo_count
// を統合、freeMemoCountProvider で整数 1 個だけを watch する形へ移行済。
// これで home_bootstrap_provider.dart の判断フロー Q1=YES の設計原則
// (「ホーム初回描画に必要な機能は bootstrap 統合」) に完全準拠。
// メモ画面到達時のみ freeMemoNotifierProvider が発火 = 全件取得。
// ─────────────────────────────────────────────────────────────────────────────

class _FreeMemoSection extends ConsumerWidget {
  const _FreeMemoSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.watch(playerNotifierProvider).valueOrNull;
    if (player == null || !player.freeMemoEnabled) return const SizedBox.shrink();

    // bootstrap 由来 (ホーム初回) or memo 画面 load 後の最新 (freeMemoNotifier) を
    // 自動選択する派生 provider (free_memo_provider.dart:freeMemoCountProvider)。
    final count = ref.watch(freeMemoCountProvider);
    if (count == 0) return const SizedBox.shrink();

    final showWarning = count > 30;
    final l10n = AppLocalizations.of(context)!;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => context.push(AppRoutes.memos, extra: {'entryPoint': 'home_section'}),
            borderRadius: BorderRadius.circular(10),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: AppTheme.card,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  const Text('📝', style: TextStyle(fontSize: 16)),
                  const SizedBox(width: 8),
                  Text(
                    l10n.habitHomeMemoCount(count),
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.75),
                      fontSize: 14,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    l10n.habitHomeMemoConfirm,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.45),
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (showWarning) ...[
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Text(
                l10n.habitHomeMemoWarningSabi_message,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.45),
                  fontSize: 12,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _XpBoostChip — 【FEAT-318 (2026-06-13 再活性化)】XP ブースト (×1.5) 中の橙色チップ
// AppBar 直下に表示。Timer.periodic で 1 分毎に残り時間を更新する。
// ─────────────────────────────────────────────────────────────────────────────

class _XpBoostChip extends ConsumerStatefulWidget {
  const _XpBoostChip();

  @override
  ConsumerState<_XpBoostChip> createState() => _XpBoostChipState();
}

class _XpBoostChipState extends ConsumerState<_XpBoostChip> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final player = ref.watch(playerNotifierProvider).valueOrNull;
    if (player == null || !player.isXpBoostActive) {
      return const SizedBox.shrink();
    }
    // 【BUG-116】効果時間 15min → 残り分単位で表示
    final remainingMinutes = (player.xpBoostRemaining.inSeconds / 60).ceil();
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
        decoration: BoxDecoration(
          color: Colors.orange.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.orange.withValues(alpha: 0.4)),
        ),
        child: Center(
          child: Text(
            l10n.habitHomeXpBoost(remainingMinutes),
            style: const TextStyle(
              color: Colors.orange,
              fontSize: 13,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ),
    );
  }
}
