import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/app_theme.dart';
import '../../../l10n/app_localizations.dart';
import '../../habits/pages/add_habit_page.dart';   // 【2026-06-27】習慣タブ Form 埋め込み
import '../../habits/pages/add_todo_page.dart';    // 【2026-06-29】ToDo タブ Form 埋め込み (Plan A 統合)
import '../../timeline/pages/add_event_page.dart'; // 【2026-06-29】予定タブ Form 埋め込み (Plan A 統合)

/// カレンダー FAB から遷移するタブ統合追加ページ（FEAT-154）。
/// タブ 0: 予定を追加（AddEventPage の Form 部分を直接埋め込み）
/// タブ 1: ToDo を追加（AddTodoPage の Form 部分を直接埋め込み）
/// タブ 2: 習慣を追加（AddHabitPage の Form 部分を直接埋め込み）
///
/// 【2026-06-27 → 2026-06-29 (Plan A 統合)】3 タブとも該当ページの `useScaffold: false`
/// 経路で埋め込む方式に統一。旧実装は予定 form (~500 LOC) + ToDo form (~300 LOC) を
/// 本ファイル内に**独立実装として複製**しており、UI 修正 (「予定名」ラベル追加等) の
/// 二度手間が 2 度発生していた。本統合で form 実装は各 AddXxxPage の 1 箇所に集約、
/// 二度手間の構造解消 (~800 LOC 削減、本ファイル 1244 → ~50 LOC)。
///
/// 保存ボタン押下時は各 AddXxxPage 内部の `Navigator.of(context).pop()` で
/// calendar_add_page 全体が pop されてカレンダー画面に戻る (3 タブ共通の UX)。
class CalendarAddPage extends ConsumerStatefulWidget {
  final DateTime initialDate;

  const CalendarAddPage({super.key, required this.initialDate});

  @override
  ConsumerState<CalendarAddPage> createState() => _CalendarAddPageState();
}

class _CalendarAddPageState extends ConsumerState<CalendarAddPage>
    with SingleTickerProviderStateMixin {

  late final TabController _tabCtrl;

  // 【2026-06-29 Plan A 統合】旧実装は予定/ToDo 用の controllers / state 変数 /
  // 定数 (~100 LOC) を持っていたが、AddEventPage(useScaffold: false) /
  // AddTodoPage(useScaffold: false) で埋め込む方式に統一したため撤去。
  // それぞれの state は埋め込まれた page 側の _AddEventPageState / _AddTodoPageState
  // が単独で管理する。calendar_add_page 側は TabController の管理のみに責務を絞る。

  @override
  void initState() {
    super.initState();
    // 【2026-06-27】タブを 2 → 3 に拡張 (予定 / ToDo / 習慣)。
    _tabCtrl = TabController(length: 3, vsync: this);
    _tabCtrl.addListener(_onTabChanged);
  }

  /// タブ切り替え時にキーボードを閉じる（レイアウトのガタツキ防止）
  void _onTabChanged() {
    if (_tabCtrl.indexIsChanging) {
      FocusScope.of(context).unfocus();
    }
  }

  @override
  void dispose() {
    _tabCtrl.removeListener(_onTabChanged);
    _tabCtrl.dispose();
    super.dispose();
  }

  // ── build ──────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.calendarAddPageTitle),
        bottom: TabBar(
          controller:           _tabCtrl,
          indicatorColor:       AppTheme.primary,
          indicatorWeight:      2.5,
          labelColor:           AppTheme.primary,
          unselectedLabelColor: Colors.white38,
          labelStyle: const TextStyle(
              fontSize: 14, fontWeight: FontWeight.w600),
          unselectedLabelStyle: const TextStyle(fontSize: 14),
          tabs: [
            Tab(text: l10n.calendarAddPageTabEvent),   // FEAT-156: スペースなしに統一
            Tab(text: l10n.calendarAddPageTabTodo),
            Tab(text: l10n.calendarAddPageTabHabit),  // 【2026-06-27】習慣追加タブ
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabCtrl,
        children: [
          // 【2026-06-29 Plan A 統合】旧 _buildEventForm() / _buildTodoForm() の
          // 独立実装 (~800 LOC) を削除し、AddEventPage / AddTodoPage の useScaffold=false
          // 経路で埋め込むように統一。3 タブすべて同 pattern に。保存時は各 page の
          // Navigator.pop で calendar_add_page 全体が pop してカレンダー画面に戻る。
          AddEventPage(
            initialDate: widget.initialDate,
            useScaffold: false,
          ),
          const AddTodoPage(useScaffold: false),
          const AddHabitPage(useScaffold: false),
        ],
      ),
    );
  }

}

