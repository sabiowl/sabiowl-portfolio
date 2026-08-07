import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/app_theme.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/sabi_loading_skeleton.dart';   // FEAT-230
import '../models/habit.dart';
import '../providers/habits_provider.dart';

class ArchivedHabitsPage extends ConsumerStatefulWidget {
  const ArchivedHabitsPage({super.key, this.initialTab = 0});

  /// 0 = アーカイブタブ, 1 = ゴミ箱タブ
  final int initialTab;

  @override
  ConsumerState<ArchivedHabitsPage> createState() => _ArchivedHabitsPageState();
}

class _ArchivedHabitsPageState extends ConsumerState<ArchivedHabitsPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: 2,
      vsync: this,
      initialIndex: widget.initialTab,
    );
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.habitFilterBarNavArchive),
        bottom: TabBar(
          controller: _tabController,
          tabs: [Tab(text: l10n.habitFilterBarNavArchive), Tab(text: l10n.habitCardSwipeTrashLabel)],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: const [_ArchiveList(), _TrashList()],
      ),
    );
  }
}

// ── 共通ヘルパー ───────────────────────────────────────────────

Future<void> _confirmAndRestore(
  BuildContext context,
  Future<void> Function() restoreAction,
) async {
  final l10n = AppLocalizations.of(context)!;
  final confirm = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: AppTheme.surface,
      title: Text(l10n.habitArchivedPageRestoreLabel,
          style: const TextStyle(color: Colors.white)),
      content: Text(l10n.habitArchivedPageRestoreContent,
          style: const TextStyle(color: Colors.white70)),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.habitArchivedPageCancelButton)),
        ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.habitArchivedPageRestoreLabel)),
      ],
    ),
  );
  if (confirm != true) return;
  await restoreAction();
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(AppLocalizations.of(context)!.habitArchivedPageRestoredSabi_message)),
    );
  }
}

Widget _habitListItem(BuildContext context, Habit habit, {required VoidCallback onRestore}) {
  final l10n = AppLocalizations.of(context)!;
  return Card(
    margin: const EdgeInsets.only(bottom: 12),
    child: ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      title: Text(
        habit.name,
        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Row(
          children: [
            _chip(habit.category, Colors.blueGrey),
            const SizedBox(width: 6),
            _chip(habit.difficultyLabelL10n(l10n), _difficultyColor(habit.difficulty)),
            const Spacer(),
            const Icon(Icons.local_fire_department, size: 13, color: Colors.orange),
            const SizedBox(width: 2),
            Text(
              l10n.habitCardBestStreakDays(habit.bestStreak),
              style: const TextStyle(fontSize: 11, color: Colors.orange),
            ),
          ],
        ),
      ),
      trailing: TextButton(
        onPressed: onRestore,
        child: Text(l10n.habitArchivedPageRestoreLabel,
            style: const TextStyle(color: AppTheme.primary)),
      ),
    ),
  );
}

Widget _emptyState(IconData icon, String message) {
  return Center(
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, size: 64, color: Colors.white.withValues(alpha: 0.3)),
        const SizedBox(height: 16),
        Text(message,
            style: const TextStyle(fontSize: 16, color: Colors.white60),
            textAlign: TextAlign.center),
      ],
    ),
  );
}

Widget _chip(String label, Color color) {
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.18),
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: color.withValues(alpha: 0.35)),
    ),
    child: Text(label, style: TextStyle(fontSize: 10, color: color)),
  );
}

Color _difficultyColor(String difficulty) {
  const map = {
    'easy': Colors.green,
    'hard': Colors.orange,
    'legendary': Colors.purple,
  };
  return map[difficulty] ?? Colors.blue;
}

// ── アーカイブ一覧 ─────────────────────────────────────────────
class _ArchiveList extends ConsumerWidget {
  const _ArchiveList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final habitsAsync = ref.watch(archivedHabitsNotifierProvider);

    return habitsAsync.when(
      loading: () => SabiWaitingPanel(message: l10n.habitArchivedPageLoadingSabi_message),
      error: (e, _) => Center(
          child: Text(l10n.habitArchivedPageErrorSabi_message,
              style: const TextStyle(color: Colors.red))),
      data: (habits) {
        if (habits.isEmpty) {
          return _emptyState(Icons.archive_outlined, l10n.habitArchivedPageEmptyArchive);
        }
        return RefreshIndicator(
          onRefresh: () =>
              ref.read(archivedHabitsNotifierProvider.notifier).refresh(),
          child: ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: habits.length,
            itemBuilder: (ctx, i) => _habitListItem(
              ctx,
              habits[i],
              onRestore: () => _confirmAndRestore(
                context,
                () => ref
                    .read(archivedHabitsNotifierProvider.notifier)
                    .restoreHabit(habits[i].id),
              ),
            ),
          ),
        );
      },
    );
  }
}

// ── ゴミ箱一覧 ────────────────────────────────────────────────
class _TrashList extends ConsumerWidget {
  const _TrashList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final habitsAsync = ref.watch(trashHabitsNotifierProvider);

    return habitsAsync.when(
      loading: () => SabiWaitingPanel(message: l10n.habitArchivedPageLoadingSabi_message),
      error: (e, _) => Center(
          child: Text(l10n.habitArchivedPageErrorSabi_message,
              style: const TextStyle(color: Colors.red))),
      data: (habits) {
        if (habits.isEmpty) {
          return _emptyState(Icons.delete_outline, l10n.habitArchivedPageEmptyTrash);
        }
        return RefreshIndicator(
          onRefresh: () =>
              ref.read(trashHabitsNotifierProvider.notifier).refresh(),
          child: ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: habits.length,
            itemBuilder: (ctx, i) => _habitListItem(
              ctx,
              habits[i],
              onRestore: () => _confirmAndRestore(
                context,
                () => ref
                    .read(trashHabitsNotifierProvider.notifier)
                    .restoreHabit(habits[i].id),
              ),
            ),
          ),
        );
      },
    );
  }
}
