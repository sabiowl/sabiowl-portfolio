import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/sabi_loading_skeleton.dart';   // FEAT-230
import '../models/habit.dart';
import '../providers/habits_provider.dart';

part 'habit_detail_page.g.dart';

// 個別習慣取得プロバイダー
@riverpod
Future<Habit> habitDetail(Ref ref, int habitId) async {
  return ref.watch(habitsServiceProvider).fetchHabit(habitId);
}

class HabitDetailPage extends ConsumerWidget {
  final int habitId;
  const HabitDetailPage({super.key, required this.habitId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final habitAsync = ref.watch(habitDetailProvider(habitId));

    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(
        title: habitAsync.whenOrNull(data: (h) => Text(h.name)) ??
            Text(l10n.habitDetailPageTitleLoading),
        actions: [
          habitAsync.whenOrNull(
            data: (habit) => PopupMenuButton<String>(
              onSelected: (v) => _onMenuSelected(context, ref, habit, v),
              itemBuilder: (_) => [
                PopupMenuItem(value: 'edit', child: Text(l10n.habitDetailPageMenuEdit)),
                PopupMenuItem(value: 'archive', child: Text(l10n.habitDetailPageMenuArchive)),
                PopupMenuItem(
                  value: 'delete',
                  child: Text(l10n.habitDetailPageMenuDelete,
                      style: TextStyle(color: AppTheme.danger)),
                ),
              ],
            ),
          ) ?? const SizedBox.shrink(),
        ],
      ),
      body: habitAsync.when(
        skipLoadingOnReload: true, // リロード中は前回データを維持（スピナーを出さない）
        data: (habit) => _buildBody(context, ref, habit),
        loading: () => SabiWaitingPanel(message: l10n.habitDetailPageLoadingSabi_message),
        error: (e, _) => Center(
          child: Text(l10n.habitArchivedPageErrorSabi_message,
              style: const TextStyle(color: Colors.red)),
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context, WidgetRef ref, Habit habit) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _buildStatusCard(context, habit),
        const SizedBox(height: 16),
        _buildStatsRow(context, habit),
        const SizedBox(height: 16),
        _buildActionButtons(context, ref, habit),
        if (habit.habitType == 'checklist') ...[
          const SizedBox(height: 16),
          _ChecklistSection(
            habit: habit,
            onToggle: (itemId) async {
              // 【BUG-150】await をまたぐので l10n は先に capture する。
              final l10n = AppLocalizations.of(context)!;
              await ref
                  .read(habitsNotifierProvider.notifier)
                  .toggleChecklistItem(habit.id, itemId, l10n: l10n);
              ref.invalidate(habitDetailProvider(habit.id));
            },
          ),
        ],
        if (habit.memo.isNotEmpty) ...[
          const SizedBox(height: 16),
          _buildMemoCard(context, habit),
        ],
        const SizedBox(height: 16),
        _buildInfoCard(context, habit),
        SizedBox(height: MediaQuery.of(context).padding.bottom + 16),
      ],
    );
  }

  /// 【FEAT-520 §5.3】完了表示は frequency 期間基準 (isCompletedInPeriod)。
  /// 週次習慣は週内ずっと「完了」と出る。下の「記録する」ボタンは操作系なので
  /// 今日基準のまま (§5.4)。
  Widget _buildStatusCard(BuildContext context, Habit habit) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: habit.isCompletedInPeriod
              ? [
                  AppTheme.expColor.withValues(alpha: 0.3),
                  AppTheme.cardBackground
                ]
              : [
                  AppTheme.primary.withValues(alpha: 0.3),
                  AppTheme.cardBackground
                ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: habit.isCompletedInPeriod
              ? AppTheme.expColor.withValues(alpha: 0.4)
              : AppTheme.primary.withValues(alpha: 0.4),
        ),
      ),
      child: Column(
        children: [
          Icon(
            habit.isCompletedInPeriod
                ? Icons.check_circle
                : Icons.radio_button_unchecked,
            size: 48,
            color: habit.isCompletedInPeriod ? AppTheme.expColor : Colors.white38,
          ),
          const SizedBox(height: 8),
          Text(
            habit.isCompletedInPeriod
                ? l10n.habitDetailPageCompletedStatus
                : l10n.habitDetailPageNotYetStatus,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: habit.isCompletedInPeriod ? AppTheme.expColor : Colors.white,
            ),
          ),
          if (habit.periodProgress != null) ...[
            const SizedBox(height: 8),
            Text(
              habit.periodProgress!.localizedLabel(l10n),
              style:
                  TextStyle(color: Colors.white.withValues(alpha: 0.6), fontSize: 13),
            ),
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: habit.periodProgress!.rate,
                minHeight: 8,
                backgroundColor: Colors.white.withValues(alpha: 0.1),
                valueColor: AlwaysStoppedAnimation<Color>(
                  habit.isCompletedInPeriod
                      ? AppTheme.expColor
                      : AppTheme.primary,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildStatsRow(BuildContext context, Habit habit) {
    final l10n = AppLocalizations.of(context)!;
    return Row(
      children: [
        _streakCard(context, habit.streak),
        const SizedBox(width: 8),
        _statCard(l10n.habitDetailPageBestStreakLabel,
            l10n.habitCardBestStreakDays(habit.bestStreak)),
        const SizedBox(width: 8),
        _statCard(l10n.habitDetailPageTotalCountLabel,
            l10n.habitDetailPageTotalCountTimes(habit.totalCount)),
      ],
    );
  }

  Widget _streakCard(BuildContext context, int streak) {
    final l10n = AppLocalizations.of(context)!;
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
        decoration: BoxDecoration(
          // 【FEAT-293】AppTheme.surface → AppTheme.card で視認性確保
          color: AppTheme.card,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
        ),
        child: Column(
          children: [
            Text(l10n.habitDetailPageStreakLabel,
                style: TextStyle(
                    fontSize: 10, color: Colors.white.withValues(alpha: 0.5))),
            const SizedBox(height: 4),
            Text(l10n.habitCardBestStreakDays(streak),
                style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Colors.white)),
            // 【2026-06-27】「この波紋は広がり続けていますね 🌊」サブテキストを撤去。
            // 数値だけのシンプル表示に。
          ],
        ),
      ),
    );
  }

  Widget _statCard(String label, String value) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          // 【FEAT-293】AppTheme.surface → AppTheme.card で視認性確保
          color: AppTheme.card,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
        ),
        child: Column(
          children: [
            Text(label,
                style: TextStyle(
                    fontSize: 10, color: Colors.white.withValues(alpha: 0.5))),
            const SizedBox(height: 4),
            Text(value,
                style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Colors.white)),
          ],
        ),
      ),
    );
  }

  Widget _buildActionButtons(
      BuildContext context, WidgetRef ref, Habit habit) {
    return Column(
      children: [
        if (habit.habitType == 'count')
          Row(
            children: [
              // 「−」ボタン: 今日カウントが1以上のときのみ表示
              if (habit.todayCount > 0) ...[
                SizedBox(
                  height: 48,
                  width: 48,
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      padding: EdgeInsets.zero,
                      side: BorderSide(color: Colors.grey.shade600),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    onPressed: () async {
                      await ref
                          .read(habitsNotifierProvider.notifier)
                          .decrementCount(habit.id);
                      if (!context.mounted) return;
                      ref.invalidate(habitDetailProvider(habit.id));
                    },
                    child: const Icon(Icons.remove, size: 20),
                  ),
                ),
                const SizedBox(width: 8),
              ],
              // 「記録する」/「もう一度記録」ボタン
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: () async {
                    final l10n = AppLocalizations.of(context)!;
                    // 【FEAT-533 §8-3 (2026-08-25)】**送れなかった回は祝わない。**
                    // `incrementCount` は `_inFlight` guard で早期 return したとき
                    // `false` を返す (throw しない)。以前はここで戻り値を見ずに
                    // SnackBar を出していたため、**何も記録されていないのにサビが
                    // 「今日の積み重ねが、世界のどこかで幸運の種になりました。」と
                    // 言う**状態になっていた。触覚の嘘 (FEAT-532) より質が悪い
                    // ——「静かな聖域」であるはずのサビの口を借りた嘘だからである。
                    final sent = await ref
                        .read(habitsNotifierProvider.notifier)
                        .incrementCount(habit.id, l10n: l10n);
                    if (!context.mounted) return;
                    ref.invalidate(habitDetailProvider(habit.id));
                    if (!sent) return;
                    final msgs = [
                      l10n.habitDetailPageRecordSabi_message1,
                      l10n.habitDetailPageRecordSabi_message2,
                      l10n.habitDetailPageRecordSabi_message3,
                      l10n.habitDetailPageRecordSabi_message4,
                      l10n.habitDetailPageRecordSabi_message5,
                    ];
                    final msg = msgs[Random().nextInt(msgs.length)];
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(msg)),
                    );
                  },
                  icon: const Icon(Icons.add),
                  label: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 200),
                    child: Builder(
                      builder: (ctx) {
                        final l10n = AppLocalizations.of(ctx)!;
                        return Text(
                          habit.isCompletedToday
                              ? l10n.habitDetailPageRecordAgainButton
                              : l10n.habitDetailPageRecordButton,
                          key: ValueKey(habit.isCompletedToday),
                        );
                      },
                    ),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.primary,
                    // 【FEAT-293】Size.fromHeight(48) と同値の Size(∞, 48) で
                    // 自己説明化（このボタンは Expanded 包み済なので幅は親が tight
                    // に決定し、∞ は事実上 max width）。
                    minimumSize: const Size(double.infinity, 48),
                  ),
                ),
              ),
            ],
          ),
      ],
    );
  }

  Widget _buildMemoCard(BuildContext context, Habit habit) {
    final l10n = AppLocalizations.of(context)!;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Icon(Icons.notes_outlined, size: 16, color: Colors.white60),
              const SizedBox(width: 6),
              Text(l10n.habitDetailPageMemoHeader,
                  style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                      color: Colors.white60)),
            ]),
            const SizedBox(height: 8),
            Text(habit.memo,
                style: const TextStyle(color: Colors.white, fontSize: 14)),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoCard(BuildContext context, Habit habit) {
    final l10n = AppLocalizations.of(context)!;
    final cycleMap = {
      'daily':   l10n.habitAddHabitFreqDaily,
      'weekly':  l10n.habitAddHabitFreqWeekly,
      'monthly': l10n.habitAddHabitFreqMonthly,
      'yearly':  l10n.habitAddHabitFreqYearly,
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.habitDetailPageInfoHeader,
                style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                    color: Colors.white)),
            const Divider(height: 20, color: Colors.white12),
            _infoRow(l10n.habitDetailPageInfoCategory, habit.category),
            _infoRow(l10n.habitDetailPageInfoFrequency,
                cycleMap[habit.frequency] ?? habit.frequency),
            _infoRow(l10n.habitDetailPageInfoResetCycle,
                cycleMap[habit.resetCycle] ?? habit.resetCycle),
            // 【FEAT-434 (2026-06-14) / 2026-06-27 UI 整理】
            // Habit (count/checklist) は difficulty を EXP 計算から完全に切り離した
            // ため詳細情報の表示も撤去。ToDo (habit_type='todo') は difficulty 別 EXP
            // (easy 30 / normal 45 / hard 60 / legendary 150) を維持しているため
            // 引き続き表示する。
            if (habit.isTodo)
              _infoRow(l10n.habitDetailPageInfoDifficulty,
                  habit.difficultyLabelL10n(l10n)),
          ],
        ),
      ),
    );
  }

  Widget _infoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label,
              style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.55), fontSize: 13)),
          Text(value,
              style:
                  const TextStyle(color: Colors.white, fontSize: 13)),
        ],
      ),
    );
  }

  Future<void> _onMenuSelected(
      BuildContext context, WidgetRef ref, Habit habit, String value) async {
    if (value == 'edit') {
      context.push(
        AppRoutes.editHabit.replaceFirst(':id', '${habit.id}'),
      );
      return;
    }
    if (value == 'archive') {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (ctx) {
          final dl10n = AppLocalizations.of(ctx)!;
          return AlertDialog(
            backgroundColor: AppTheme.surface,
            title: Text(dl10n.habitDetailPageMenuArchive,
                style: const TextStyle(color: Colors.white)),
            content: Text(dl10n.habitDetailPageArchiveDialogContent,
                style: const TextStyle(color: Colors.white70)),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: Text(dl10n.habitArchivedPageCancelButton)),
              ElevatedButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: Text(dl10n.habitDetailPageMenuArchive)),
            ],
          );
        },
      );
      if (confirm == true && context.mounted) {
        await ref
            .read(habitsNotifierProvider.notifier)
            .archiveHabit(habit.id);
        if (context.mounted) Navigator.of(context).pop();
      }
    } else if (value == 'delete') {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (ctx) {
          final dl10n = AppLocalizations.of(ctx)!;
          return AlertDialog(
            backgroundColor: AppTheme.surface,
            title: Text(dl10n.habitDetailPageMenuDelete,
                style: const TextStyle(color: Colors.white)),
            content: Text(dl10n.habitDetailPageDeleteDialogContent,
                style: const TextStyle(color: Colors.white70)),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: Text(dl10n.habitArchivedPageCancelButton)),
              ElevatedButton(
                onPressed: () => Navigator.pop(ctx, true),
                style:
                    ElevatedButton.styleFrom(backgroundColor: AppTheme.danger),
                child: Text(dl10n.habitDetailPageMenuDelete),
              ),
            ],
          );
        },
      );
      if (confirm == true && context.mounted) {
        await ref
            .read(habitsNotifierProvider.notifier)
            .deleteHabit(habit.id);
        if (context.mounted) Navigator.of(context).pop();
      }
    }
  }
}

// ── チェックリスト 2セクション表示 ───────────────────────────────────────────

/// チェックリストを「未完了」「完了済み」に分けて表示するウィジェット
class _ChecklistSection extends StatefulWidget {
  final Habit habit;
  final Future<void> Function(int itemId) onToggle;

  const _ChecklistSection({required this.habit, required this.onToggle});

  @override
  State<_ChecklistSection> createState() => _ChecklistSectionState();
}

class _ChecklistSectionState extends State<_ChecklistSection> {
  bool _doneExpanded = false;
  final Set<int> _toggling = {}; // トグル中のアイテムID（二重タップ防止）

  /// 楽観的更新用のローカル状態
  /// widget.habit.checklistItems をコピーして保持し、タップ時に即座に反転させる
  late List<ChecklistItem> _items;

  @override
  void initState() {
    super.initState();
    _items = List.from(widget.habit.checklistItems);
  }

  @override
  void didUpdateWidget(_ChecklistSection old) {
    super.didUpdateWidget(old);
    // skipLoadingOnReload: true によりリロード中は同一オブジェクトが渡される場合がある。
    // 同一オブジェクトなら同期不要なのでスキップする。
    if (identical(old.habit, widget.habit)) return;
    // 【BUG-79 fix (2026-06-01)】サーバーリスト基準で再構築する。
    //
    // 旧実装は `_items.map((localItem) => ...)` で **旧 _items を基準** に
    // 同期していたため、以下の構造バグがあった:
    //   - 新規追加項目 (server に存在 + 旧 _items に存在しない): map に出てこない
    //     → 新しいチェックリスト項目が UI に現れない
    //   - 削除項目 (旧 _items に存在 + server に存在しない): orElse で localItem 維持
    //     → 削除した項目が UI に残り続ける
    //
    // 修正: サーバーリスト (widget.habit.checklistItems) を基準に map することで、
    // 新規追加は自動で含まれ、削除は自動で除外される。トグル中のみローカル状態維持。
    setState(() {
      _items = widget.habit.checklistItems.map((serverItem) {
        // 楽観的更新中の項目はローカル状態を維持 (Backend に届く前の UI 反映)
        if (_toggling.contains(serverItem.id)) {
          return _items.firstWhere(
            (i) => i.id == serverItem.id,
            orElse: () => serverItem,
          );
        }
        return serverItem;
      }).toList();
    });
  }

  @override
  Widget build(BuildContext context) {
    // widget.habit.checklistItems ではなく _items を参照する（楽観状態）
    final pending = _items
        .where((i) => !i.isDone)
        .toList()
      ..sort((a, b) => a.order.compareTo(b.order));

    final done = _items
        .where((i) => i.isDone)
        .toList()
      ..sort((a, b) => a.order.compareTo(b.order));

    final l10n = AppLocalizations.of(context)!;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── ヘッダー ───────────────────────���──────────────
            Row(
              children: [
                Text(l10n.habitDetailPageChecklistHeader,
                    style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                        color: Colors.white)),
                const Spacer(),
                Text(
                  l10n.habitDetailPageChecklistPendingCount(pending.length),
                  style: const TextStyle(
                      color: Colors.white38, fontSize: 12),
                ),
              ],
            ),
            const SizedBox(height: 8),

            // ── 未完了セクション ──────────────────────────────
            if (pending.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  l10n.habitDetailPageChecklistAllDone,
                  style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.4),
                      fontSize: 13),
                ),
              )
            else
              AnimatedSize(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOut,
                child: Column(
                  children: pending
                      .map((item) => _ChecklistTile(
                            key: ValueKey(item.id),
                            item: item,
                            onToggle: () => _handleToggle(item.id),
                          ))
                      .toList(),
                ),
              ),

            // ── 完了済みセクション ────────────────────────────
            if (done.isNotEmpty) ...[
              const SizedBox(height: 4),
              InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () =>
                    setState(() => _doneExpanded = !_doneExpanded),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      vertical: 8, horizontal: 4),
                  child: Row(
                    children: [
                      Icon(
                        _doneExpanded
                            ? Icons.expand_less
                            : Icons.expand_more,
                        color: Colors.white38,
                        size: 18,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        l10n.habitDetailPageChecklistDoneCount(done.length),
                        style: const TextStyle(
                            color: Colors.white38, fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ),
              AnimatedSize(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOut,
                child: _doneExpanded
                    ? Column(
                        children: done
                            .map((item) => _ChecklistTile(
                                  key: ValueKey(item.id),
                                  item: item,
                                  onToggle: () => _handleToggle(item.id),
                                ))
                            .toList(),
                      )
                    : const SizedBox.shrink(),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _handleToggle(int itemId) async {
    if (_toggling.contains(itemId)) return; // 二重タップ防止

    // ── 楽観的更新: API 呼び出し前に isDone を即座に反転 ──
    final idx = _items.indexWhere((i) => i.id == itemId);
    if (idx == -1) return;
    setState(() {
      _toggling.add(itemId);
      _items[idx] = _items[idx].copyWith(isDone: !_items[idx].isDone);
    });

    try {
      await widget.onToggle(itemId); // バックグラウンドで API 呼び出し
    } finally {
      if (mounted) setState(() => _toggling.remove(itemId));
      // _toggling から外れると didUpdateWidget の同期ロジックが次回ビルド時に適用される
    }
  }
}

/// 個別のチェックリストアイテム行
class _ChecklistTile extends StatelessWidget {
  final ChecklistItem item;
  final VoidCallback onToggle; // toggling は削除（グレーアウトしない）

  const _ChecklistTile({
    super.key,
    required this.item,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final isDone = item.isDone;
    return CheckboxListTile( // AnimatedOpacity ラッパーも削除
      dense: true,
      contentPadding: EdgeInsets.zero,
      value: isDone,
      activeColor: AppTheme.primary,
      title: Text(
        item.text,
        style: TextStyle(
          color: isDone
              ? Colors.white.withValues(alpha: 0.35)
              : Colors.white,
          decoration: isDone ? TextDecoration.lineThrough : null,
          decorationColor: Colors.white.withValues(alpha: 0.35),
          fontSize: 14,
        ),
      ),
      onChanged: (_) => onToggle(), // 常に有効。二重タップ防止は _handleToggle が担う
    );
  }
}
