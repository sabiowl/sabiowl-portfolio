import 'package:flutter/material.dart';
import 'package:flutter/services.dart';  // 【FEAT-212】HapticFeedback
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/bouncy_fab.dart';  // 【2026-06-28】軽快な FAB
import '../../../shared/widgets/reward_toast.dart';
import '../providers/calendar_provider.dart';
import '../widgets/calendar_tab.dart';
import '../widgets/gcal_intro_sheet.dart';  // 【FEAT-254】
import '../widgets/stats_tab.dart';
import '../../habits/models/habit.dart' show HabitReward;
import '../../habits/providers/habits_provider.dart'
    show rewardToastProvider, playerNotifierProvider;
// 【FEAT-290】linkedAccountsProvider は Google アカウント連携状態に基づく
// カレンダー同期メニューのゲートに使っていたが、本 FEAT で「連携不要・常に
// 同期可能」に変更したため import 不要に。
import '../../timeline/providers/timeline_provider.dart';  // 【FEAT-214】timelineEventsProvider 用

/// カレンダー画面の表示ビュー（ハンバーガーメニューで切り替え）
enum CalendarPageView {
  monthly,    // グリッドカレンダー
  analytics,  // 分析（StatsTab）
}

// ── PageView ヘルパー ───────────────────────────────────────────────────────

/// PageView の基準年（ページインデックス 0 = 2020年1月）
const _kCalendarBaseYear = 2020;

/// 年月 → ページインデックス変換
int _yearMonthToPage(int year, int month) {
  return (year - _kCalendarBaseYear) * 12 + (month - 1);
}

/// ページインデックス → 年月変換
(int year, int month) _pageToYearMonth(int page) {
  final year  = _kCalendarBaseYear + page ~/ 12;
  final month = page % 12 + 1;
  return (year, month);
}

// ─────────────────────────────────────────────────────────────────────────────

class CalendarPage extends ConsumerStatefulWidget {
  const CalendarPage({super.key});

  @override
  ConsumerState<CalendarPage> createState() => _CalendarPageState();
}

class _CalendarPageState extends ConsumerState<CalendarPage> {
  late int _year;
  late int _month;

  DateTime? _selectedDate;
  CalendarPageView _currentView = CalendarPageView.monthly;

  // ── リワードトースト ──────────────────────────────────────────────────
  OverlayEntry? _rewardEntry;

  // BUG-16: 初回フレーム完了後に FAB を有効化するフラグ。
  // 初回フレームでは floatingActionButton: null として FAB スロット自体を
  // 生成しないことで、NEEDS-LAYOUT な RenderObject が Theater の
  // ヒットテストに巻き込まれるのを防ぐ。
  bool _fabReady = false;

  // ── 月ページスワイプ用 ────────────────────────────────────────────────
  late PageController _pageController;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _year  = now.year;
    _month = now.month;
    // デフォルト選択日 = 今日
    _selectedDate = DateTime(now.year, now.month, now.day);

    // PageView: 現在月を初期ページとして設定
    _pageController = PageController(
      initialPage: _yearMonthToPage(_year, _month),
    );

    // BUG-16: 初回 layout 完了後に FAB を有効化する
    // 【FEAT-247】Google push 失敗通知は TimelineService から ToastCenter 経由で
    // 全画面共通に届くため、calendar_page 専用 callback の登録は撤去。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _fabReady = true);
    });
  }

  @override
  void dispose() {
    _rewardEntry?.remove();
    _rewardEntry = null;
    _pageController.dispose();
    super.dispose();
  }

  void _showRewardToast(HabitReward reward) {
    _rewardEntry?.remove();
    _rewardEntry = OverlayEntry(
      builder: (_) => RewardToastOverlay(reward: reward),
    );
    Overlay.of(context).insert(_rewardEntry!);
    // BUG-S: トースト本体の寿命短縮（200+1200+200=1600ms）に合わせて 1700ms で掃除。
    Future.delayed(const Duration(milliseconds: 1700), () {
      _rewardEntry?.remove();
      _rewardEntry = null;
      if (mounted) {
        ref.read(rewardToastProvider.notifier).state = null;
      }
    });
  }

  // FEAT-166B: 分析ビューで登録月以前への移動を禁止する
  bool _isPrevMonthDisabled() {
    if (_currentView != CalendarPageView.analytics) return false;
    final createdAt = ref.read(playerNotifierProvider).valueOrNull?.createdAt;
    if (createdAt == null) return false; // 登録日不明の場合は制限なし
    return _year < createdAt.year ||
        (_year == createdAt.year && _month <= createdAt.month);
  }

  void _prevMonth() {
    if (_currentView == CalendarPageView.analytics) {
      // FEAT-166B: 登録月以前へは移動しない
      if (_isPrevMonthDisabled()) return;
      // 分析ビューは PageView を持たないので _year/_month を直接更新
      setState(() {
        if (_month == 1) {
          _year--;
          _month = 12;
        } else {
          _month--;
        }
      });
    } else {
      _pageController.previousPage(
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeInOut,
      );
    }
  }

  void _nextMonth() {
    if (_currentView == CalendarPageView.analytics) {
      // 今月より未来の分析データは存在しないため移動を制限
      final now = DateTime.now();
      if (_year > now.year || (_year == now.year && _month >= now.month)) return;
      setState(() {
        if (_month == 12) {
          _year++;
          _month = 1;
        } else {
          _month++;
        }
      });
    } else {
      _pageController.nextPage(
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeInOut,
      );
    }
  }

  void _goToToday() {
    final now = DateTime.now();
    setState(() {
      _year  = now.year;
      _month = now.month;
      _selectedDate = DateTime(now.year, now.month, now.day);
    });
    // 分析ビュー中は PageView が存在しないため hasClients でガード（FEAT-167）
    if (_pageController.hasClients) {
      _pageController.jumpToPage(_yearMonthToPage(now.year, now.month));
    }
  }

  void _onDateSelected(DateTime date) {
    setState(() {
      _selectedDate = date;
      _year  = date.year;
      _month = date.month;
    });
  }

  void _selectView(CalendarPageView view) {
    // FEAT-160: 分析ビュー → カレンダービューへ戻るとき、_year/_month にページを合わせる
    final needsPageSync = view != CalendarPageView.analytics &&
        _currentView == CalendarPageView.analytics;

    // ① 先に setState して PageView を描画させる（FEAT-167: クラッシュ修正）
    setState(() => _currentView = view);

    // ② PageView 描画後（次フレーム）にページを合わせる
    if (needsPageSync) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _pageController.hasClients) {
          _pageController.jumpToPage(_yearMonthToPage(_year, _month));
        }
      });
    }
  }

  /// 年月ピッカーダイアログを表示する
  void _showMonthPicker() {
    showDialog<void>(
      context: context,
      builder: (_) => _MonthPickerDialog(
        initialYear:  _year,
        initialMonth: _month,
        onSelected: (year, month) {
          setState(() {
            _year  = year;
            _month = month;
            _selectedDate = DateTime(year, month, 1);
          });
          // 分析ビュー中は PageView が存在しないため hasClients でガード（FEAT-167）
          if (_pageController.hasClients) {
            _pageController.jumpToPage(_yearMonthToPage(year, month));
          }
        },
      ),
    );
  }

  // FEAT-154: CalendarAddPage（タブ式）への全画面遷移
  void _showQuickAdd() {
    // 選択日（未選択なら今日）を CalendarAddPage に渡す
    final date = _selectedDate ?? DateTime.now();
    context.push(AppRoutes.calendarAdd, extra: date);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // FEAT-188: カレンダーはサーバー側ゲスト基盤で完全動作。
    // 旧 GuestLinkPromptCard 分岐は撤廃。

    // リワードトースト（タイムライン達成時）
    ref.listen<HabitReward?>(rewardToastProvider, (_, reward) {
      if (reward == null) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _showRewardToast(reward);
      });
    });

    final showFab = _currentView != CalendarPageView.analytics;
    // 【2026-07-25 update】freeMemoEnabled 分岐撤廃 (gameplay-review 20260725 §2-1
    // 対応、Calendar FAB は _showQuickAdd 固定に戻す)。

    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // FEAT-166B: 分析ビューかつ登録月以前は onPressed: null で dim
            Builder(
              builder: (context) {
                final disabled = _isPrevMonthDisabled();
                return IconButton(
                  icon: const Icon(Icons.chevron_left),
                  onPressed: disabled ? null : _prevMonth,
                  padding: EdgeInsets.zero,
                );
              },
            ),
            // タップで年月ピッカーを開く
            GestureDetector(
              onTap: _showMonthPicker,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    l10n.calendarPageYearMonthTitle(_year, _month),
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(width: 2),
                  // ドロップダウン示唆アイコン（小さめ）
                  const Icon(
                    Icons.arrow_drop_down,
                    size: 18,
                    color: Colors.white60,
                  ),
                ],
              ),
            ),
            // FEAT-160: 分析ビューかつ今月以降は onPressed: null で dim
            Builder(
              builder: (context) {
                final isAtOrAfterCurrentMonth = () {
                  if (_currentView != CalendarPageView.analytics) return false;
                  final now = DateTime.now();
                  return _year > now.year ||
                      (_year == now.year && _month >= now.month);
                }();
                return IconButton(
                  icon: const Icon(Icons.chevron_right),
                  onPressed: isAtOrAfterCurrentMonth ? null : _nextMonth,
                  padding: EdgeInsets.zero,
                );
              },
            ),
          ],
        ),
        centerTitle: true,
        actions: [
          // ── 今日 / 今月ボタン ────────────────────────────────────
          // FEAT-169: 分析ビューは「今月」、カレンダー / リストビューは「今日」
          Builder(
            builder: (context) {
              final now = DateTime.now();
              final bool isDisabled;
              final String label;

              if (_currentView == CalendarPageView.analytics) {
                label      = l10n.calendarPageThisMonthButton;
                isDisabled = _year == now.year && _month == now.month;
              } else {
                label      = l10n.calendarPageTodayButton;
                final todayDate = DateTime(now.year, now.month, now.day);
                isDisabled = _selectedDate == todayDate;
              }

              return _TodayButton(
                label:   label,
                isToday: isDisabled,
                onTap:   _goToToday,
              );
            },
          ),
          // ── 三本線ハンバーガーメニュー ──────────────────────────
          _ViewMenuButton(
            currentView: _currentView,
            onSelected:  _selectView,
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: _currentView == CalendarPageView.analytics
          // 分析ビューはスワイプ不要
          ? StatsTab(year: _year, month: _month)
          // カレンダー / リストビューは PageView で横スワイプ対応
          : PageView.builder(
              controller: _pageController,
                  // 未来方向へ最大 60 ヶ月（約5年）まで移動可能
              itemCount: _yearMonthToPage(
                    DateTime.now().year,
                    DateTime.now().month,
                  ) +
                  1 +
                  60,
              onPageChanged: (page) {
                final (year, month) = _pageToYearMonth(page);
                setState(() {
                  _year  = year;
                  _month = month;
                  // 月が変わったら選択日をその月の1日にリセット
                  _selectedDate = DateTime(year, month, 1);
                });
              },
              itemBuilder: (_, page) {
                final (pageYear, pageMonth) = _pageToYearMonth(page);
                return CalendarTab(
                  year:           pageYear,
                  month:          pageMonth,
                  // 選択日は現在月のページのみ反映
                  selectedDate:   (pageYear == _year && pageMonth == _month)
                      ? _selectedDate
                      : null,
                  onDateSelected: _onDateSelected,
                );
              },
            ),
      // クイック追加 FAB（分析ビュー以外で表示）
      // BUG-16: 初回フレームは null（FAB スロットを生成しない）
      // BUG-14: 型スイッチを避けるため AnimatedOpacity + IgnorePointer で制御
      // 【2026-06-28】FAB を BouncyFab に置換 (押下時 0.95 縮小 + easeOutBack 復帰 +
      // 紫リップル + light impact + 120ms 遅延発火)。「押すこと自体が気持ち良い」体験。
      //
      // 【2026-07-25 gameplay-review 20260725 §2-1 対応】Calendar FAB の分岐撤廃。
      // 経緯:
      //   1. 87a62f9 で freeMemoEnabled ? /memos : calendarAdd に分岐
      //   2. 6eebcf4 + migration 0186 で default ON + 既存 row 全 backfill
      //   3. → 全ユーザーが /memos に流れる = /calendar/add への唯一の到達経路が消滅
      //   4. → 「来週の火曜に歯医者」を任意日付で予定に追加する core flow が不可能に
      // 対応 (案 B): Calendar FAB は _showQuickAdd 固定に戻す。
      // 画面ごとに FAB の意味を分離 (Home = メモ Quick Capture、Calendar = 予定追加)
      // する方が「カレンダーで日付タップ → + = その日の予定追加」の mental model
      // (最も強く手が覚えているジェスチャ) と整合する。
      floatingActionButton: _fabReady
          ? Padding(
              padding: const EdgeInsets.only(bottom: 48),
              child: AnimatedOpacity(
                opacity: showFab ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 200),
                child: IgnorePointer(
                  ignoring: !showFab,
                  child: BouncyFab(
                    onPressed: _showQuickAdd,
                    tooltip: l10n.calendarPageFabTooltip,
                    child: const Icon(
                      Icons.add,
                      color: Colors.white,
                      size: 28,
                    ),
                  ),
                ),
              ),
            )
          : null,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 今日ボタン
// ─────────────────────────────────────────────────────────────────────────────

/// AppBar に表示する「今日 / 今月」ジャンプボタン（FEAT-169）。
/// 選択中の日付が今日（カレンダービュー）または今月（分析ビュー）の場合のみ非活性。
class _TodayButton extends StatelessWidget {
  final bool         isToday; // true のとき非活性（薄く・押せない）
  final VoidCallback onTap;
  /// FEAT-169: 「今日」or「今月」を外部から渡す。
  ///
  /// 【FEAT-489 Phase 2F-a】default parameter は AppLocalizations を参照できないため
  /// nullable にして `build()` 内で fallback する (Phase 2D の SabiWaitingPanel と同型)。
  final String?      label;

  const _TodayButton({
    required this.isToday,
    required this.onTap,
    this.label,
  });

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: isToday ? null : onTap,
      style: TextButton.styleFrom(
        foregroundColor: AppTheme.primary,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      child: Text(
        label ?? AppLocalizations.of(context)!.calendarPageTodayButton,
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.bold,
          color: isToday ? Colors.white24 : AppTheme.primary,
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 表示切り替えハンバーガーメニュー
// ─────────────────────────────────────────────────────────────────────────────

/// カレンダー画面の表示切り替えハンバーガーメニュー。
/// Google 連携済みの場合は Google カレンダー同期メニューも表示する。
class _ViewMenuButton extends ConsumerStatefulWidget {
  final CalendarPageView currentView;
  final void Function(CalendarPageView) onSelected;

  const _ViewMenuButton({
    required this.currentView,
    required this.onSelected,
  });

  @override
  ConsumerState<_ViewMenuButton> createState() => _ViewMenuButtonState();
}

class _ViewMenuButtonState extends ConsumerState<_ViewMenuButton> {
  bool _isSyncing = false;

  /// 【FEAT-212 → BUG-138 (2026-06-17) → 2026-06-29】「Google カレンダーを管理」
  /// メニュー押下時のダイアログを **同期状態で 2 状態に切り替え** る。
  ///
  /// 経緯:
  /// - FEAT-212 で 3-button (同期する / キャンセル / 同期解除) 統合ダイアログ
  /// - BUG-138 で 2-button (Cancel 左 / Action 右) ルール適用のため「同期する」
  ///   選択肢を撤去、常に「解除」ダイアログを表示していた
  /// - 【2026-06-29】未同期状態でも「同期を解除」しか出せず「まだ同期していない
  ///   のに解除表示」の UX 不具合が報告 → 同期状態を判定して未同期時は
  ///   「同期する」ダイアログ、同期済み時は「解除」ダイアログを切り替える設計に変更
  ///
  /// 判定基準: `LocalGoogleEventStore.allGoogleEventIds()` の件数 > 0 で「同期済み」。
  /// (取り込み済みイベントが端末内に 1 件でもあれば同期済み扱い)
  ///
  /// button 配置は BUG-138 ルール準拠を維持 (Cancel 左 / Action 右の 2-button)。
  /// アカウント連携 (SocialAccount) とは無関係に動作する (Calendar 専用 GoogleSignIn
  /// インスタンスを使うため、連携なしのゲスト・非連携ユーザーも同期可能)。
  Future<void> _showGoogleCalendarDialog() async {
    HapticFeedback.selectionClick();

    // 同期状態を判定: LocalGoogleEventStore に取り込み済みイベントがあるか。
    // (エラー時は「未同期」扱いにフォールバック = ユーザーが誤って解除を選ぶ
    //  リスクをゼロにする安全側の設計)
    bool isSynced = false;
    try {
      final store = ref.read(localGoogleEventStoreProvider);
      final ids = await store.allGoogleEventIds();
      isSynced = ids.isNotEmpty;
    } catch (e) {
      debugPrint('[calendar_page._showGoogleCalendarDialog] '
          'sync state detection failed: $e (fallback: 未同期扱い)');
    }
    if (!mounted) return;

    if (isSynced) {
      await _showUnsyncGoogleCalendarDialog();
    } else {
      await _showSyncGoogleCalendarDialog();
    }
  }

  /// 【2026-06-29】未同期時に表示する「同期する」確認ダイアログ。
  Future<void> _showSyncGoogleCalendarDialog() async {
    final l10n = AppLocalizations.of(context)!;
    // 【FEAT-215】Navigator.pop は dialogContext で行う (ShellRoute 配下対策)。
    final proceed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppTheme.card,
        title: Text(
          l10n.calendarPageSyncDialogTitle,
          style: const TextStyle(color: Colors.white),
        ),
        content: Text(
          l10n.calendarPageSyncDialogContent,
          style: const TextStyle(color: Colors.white70, height: 1.6, fontSize: 13),
        ),
        actions: [
          // 【BUG-138】Cancel 左 / Action 右。
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(l10n.commonCancel,
                style: const TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: TextButton.styleFrom(foregroundColor: AppTheme.primary),
            child: Text(l10n.calendarPageSyncDialogConfirm),
          ),
        ],
      ),
    );
    if (!mounted || proceed != true) return;
    await _syncGoogleCalendar();
  }

  /// 【2026-06-29】同期済み時に表示する「解除」ダイアログ (旧 _showGoogleCalendarDialog)。
  Future<void> _showUnsyncGoogleCalendarDialog() async {
    final l10n = AppLocalizations.of(context)!;
    // 【FEAT-215】Navigator.pop は dialogContext で行う (ShellRoute 配下対策)。
    final result = await showDialog<_GoogleCalendarAction>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppTheme.card,
        title: Text(
          l10n.calendarPageUnsyncDialogTitle,
          style: const TextStyle(color: Colors.white),
        ),
        content: Text(
          l10n.calendarPageUnsyncDialogContent,
          style: const TextStyle(color: Colors.white70, height: 1.6, fontSize: 13),
        ),
        actions: [
          // 【BUG-138 (2026-06-17)】Cancel 左 / Action 右の新ルール準拠。
          TextButton(
            onPressed: () =>
                Navigator.pop(dialogContext, _GoogleCalendarAction.cancel),
            child: Text(l10n.commonCancel,
                style: const TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () =>
                Navigator.pop(dialogContext, _GoogleCalendarAction.unsync),
            style: TextButton.styleFrom(foregroundColor: AppTheme.danger),
            child: Text(l10n.calendarPageUnsyncDialogAction),
          ),
        ],
      ),
    );

    if (!mounted || result == null || result == _GoogleCalendarAction.cancel) {
      return;
    }
    if (result == _GoogleCalendarAction.unsync) {
      await _confirmAndUnsyncGoogleCalendar();
    }
  }

  /// 【FEAT-212】同期解除の最終確認 → DELETE 実行。
  Future<void> _confirmAndUnsyncGoogleCalendar() async {
    final l10n = AppLocalizations.of(context)!;
    // 【FEAT-215】1 つ目ダイアログと同じ理由で、Navigator.pop は dialogContext で行う。
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppTheme.card,
        title: Text(
          l10n.calendarPageUnsyncConfirmTitle,
          style: const TextStyle(color: Colors.white),
        ),
        content: Text(
          l10n.calendarPageUnsyncConfirmContent,
          style: const TextStyle(color: Colors.white70, height: 1.6, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(l10n.commonCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: TextButton.styleFrom(foregroundColor: AppTheme.danger),
            child: Text(l10n.calendarPageUnsyncConfirmAction),
          ),
        ],
      ),
    );

    if (!mounted || confirmed != true) return;

    setState(() => _isSyncing = true);
    try {
      final result = await ref
          .read(googleCalendarSyncServiceProvider)
          .unsyncGoogleCalendar();
      if (!mounted) return;
      final deleted = result['deleted'] ?? 0;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.calendarPageUnsyncSuccessSnackbarSabi_message(deleted is int ? deleted : (deleted as num).toInt())),
          duration: const Duration(seconds: 2),
        ),
      );
      // 【FEAT-214】UI で実際に watch されている provider を正しく invalidate する。
      // - calendarBootstrapProvider: カレンダー画面（CalendarTab）が watch
      // - timelineEventsProvider:    ホーム画面 / タイムライン画面が watch
      // 旧 calendarDataProvider / dailyDataProvider は CAL/P1-3 で bootstrap 集約
      // 後はカレンダー画面から直接 watch されておらず、UI が更新されないバグの原因だった。
      // family を引数なしで invalidate すると全インスタンスが対象になる。
      ref.invalidate(calendarBootstrapProvider);
      ref.invalidate(timelineEventsProvider);
    } catch (e, st) {
      // 【2026-05-29 hotfix】CLAUDE.md「FEAT-244 診断」教訓踏襲: catch (_) で
      // 真因を握り潰さない。例外型 + メッセージ + 簡易スタックを debugPrint で
      // 可視化 (Xcode Console / Android Studio Logcat / flutter logs で確認可能)。
      // ユーザーには引き続きサビ口調メッセージを表示 (UX 不変)。
      debugPrint('[calendar_page._confirmAndUnsyncGoogleCalendar] failed: $e\n$st');
      if (!mounted) return;
      // 【FEAT-251】redAccent からサビ温度に統一。文面は元から穏やかな丁寧体。
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.calendarPageUnsyncErrorSnackbarSabi_message),
          backgroundColor: AppTheme.primary,
          duration: const Duration(seconds: 3),
        ),
      );
    } finally {
      if (mounted) setState(() => _isSyncing = false);
    }
  }

  Future<void> _syncGoogleCalendar() async {
    if (_isSyncing) return;
    final l10n = AppLocalizations.of(context)!;

    // 【FEAT-254】OAuth scope 拡張（calendar.readonly → calendar.events）の
    // 信頼コストを軽減するため、初回タップ時のみサビ口調の事前説明シートを表示。
    // ユーザーが「今はやめておく」を選んだ場合は同期実行せず、フラグも立てない。
    final introShown = await GcalIntroPrefs.hasBeenShown();
    if (!introShown) {
      if (!mounted) return;
      final proceed = await GcalIntroSheet.show(context);
      if (proceed != true) {
        // 「今はやめておく」または背景タップで閉じた → 同期中止
        return;
      }
      await GcalIntroPrefs.markShown();
      if (!mounted) return;

      // 【FEAT-263】シート「承諾画面へ進む」タップ = Google カレンダー連携への明示同意。
      // FEAT-257 の `gcal_push_enabled` は FEAT-263 (migration 0077) で DB default
      // が OFF に変わったため、同意の瞬間にここで `true` に flip する。
      // 失敗してもサイレント続行（マイページのトグルから手動 ON 可能）。
      // 【FEAT-373 (2026-05-29)】v1.0 で push 機能廃止後、`gcal_push_enabled=true` は
      // Backend `_initial_pending_google_push` 常時 False + FeatureFlags.gcalPushEnabled=false
      // により構造的に無効化されている。本 flip 自体は dead code 化しているが、
      // v1.1+ で push 再開時の互換性 + Settings UI 復元時の整合性のため残置する。
      try {
        await ref
            .read(playerNotifierProvider.notifier)
            .setGcalPushEnabled(true);
      } catch (e) {
        debugPrint('[FEAT-263] gcal_push_enabled flip failed: $e');
      }
    }

    setState(() => _isSyncing = true);

    try {
      final result = await ref
          .read(googleCalendarSyncServiceProvider)
          .syncGoogleCalendar();

      if (!mounted) return;

      if (result == null) {
        // ユーザーがキャンセル — 何もしない
        return;
      }

      // 【FEAT-214】解除側と同じく、UI で実際に watch されている provider を invalidate する。
      // - calendarBootstrapProvider: カレンダー画面（CalendarTab）が watch
      // - timelineEventsProvider:    ホーム画面 / タイムライン画面が watch
      ref.invalidate(calendarBootstrapProvider);
      ref.invalidate(timelineEventsProvider);

      // 【FEAT-244】双方向同期に拡張。
      // 【FEAT-373 (2026-05-29)】v1.0 で push 機能廃止後、送信側は構造的に無効化。
      // - 取り込み側 (Google → Sabiowl): created / updated / skipped (本番動作)
      // - 送信側     (Sabiowl → Google): pushed / push_failed (v1.0 では常に 0、
      //   `FeatureFlags.gcalPushEnabled = false` で Step 6 push loop skipped)
      // 【FEAT-253】Google 側削除イベントの追随件数 (deleted_followup) も追加。
      final created         = result['created']          ?? 0;
      final updated         = result['updated']          ?? 0;
      final skipped         = result['skipped']          ?? 0;
      final pushed          = result['pushed']           ?? 0;
      final pushFailed      = result['push_failed']      ?? 0;
      final deletedFollowup = result['deleted_followup'] ?? 0;
      // 主要メッセージ（取り込み / 送信）にオプション情報を後置で連結
      final iCreated = (created as num).toInt();
      final iUpdated = (updated as num).toInt();
      final iPushed  = (pushed as num).toInt();
      final iSkipped = (skipped as num).toInt();
      final iPushFailed      = (pushFailed as num).toInt();
      final iDeletedFollowup = (deletedFollowup as num).toInt();
      final parts = <String>[
        l10n.calendarSyncPartFetched(iCreated + iUpdated),
        l10n.calendarSyncPartPushed(iPushed),
      ];
      if (iDeletedFollowup > 0) parts.add(l10n.calendarSyncPartDeletedFollowup(iDeletedFollowup));
      if (iPushFailed > 0) {
        parts.add(l10n.calendarSyncPartPushFailed(iPushFailed));
      } else {
        parts.add(l10n.calendarSyncPartSkipped(iSkipped));
      }
      final msg = l10n.calendarSyncSuccessSnackbar(parts.join(l10n.calendarSyncPartSeparator));

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), duration: const Duration(seconds: 3)),
      );
    } catch (e, st) {
      // 【2026-05-29 hotfix】CLAUDE.md「FEAT-244 診断」教訓踏襲: catch (_) で
      // 真因を握り潰さない。例外型 + メッセージ + 簡易スタックを debugPrint で
      // 可視化。Sabiowl の syncGoogleCalendar() は明示的に Exception を throw
      // (scope 不足 / token 失敗 / API エラー等) するため、ログから真因を即特定可能。
      // ユーザーには引き続きサビ口調メッセージを表示 (UX 不変)。
      debugPrint('[calendar_page._syncGoogleCalendar] failed: $e\n$st');
      if (!mounted) return;
      // 【FEAT-426 Pre-mortem S4】端末ストレージ逼迫等で sqflite への書き込みが
      // 失敗した場合は、汎用メッセージではなくストレージ専用の案内を表示する。
      final message = _isStorageError(e)
          ? l10n.calendarPageSyncStorageErrorSnackbarSabi_message
          : l10n.calendarPageSyncErrorSnackbarSabi_message;
      // 【FEAT-251】例外原文露出 + redAccent を撤去し、サビ口調 + AppTheme.primary に統一。
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: AppTheme.primary,
          duration: const Duration(seconds: 3),
        ),
      );
    } finally {
      if (mounted) setState(() => _isSyncing = false);
    }
  }

  /// 【FEAT-426 Pre-mortem S4】sqflite の DatabaseException がストレージ不足
  /// （SQLITE_FULL / "no space left" / "disk full" 等）かどうかを判定する。
  bool _isStorageError(Object e) {
    final msg = e.toString().toLowerCase();
    return msg.contains('sqlite_full') ||
        msg.contains('no space left') ||
        msg.contains('disk full') ||
        msg.contains('disk is full') ||
        msg.contains('database or disk is full');
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // 【FEAT-290】Google カレンダー同期は Sabiowl のアカウント連携状態と独立。
    // `GoogleCalendarSyncService._googleSignIn` は calendar.events scope 専用の
    // 独立した GoogleSignIn インスタンスを持つため、アカウント連携をしていない
    // ユーザーも sync ボタンタップで Google アカウント選択 → カレンダー取得が
    // 可能。`linkedAccountsProvider` の watch + isGoogleLinked ゲートは撤去。
    // 旧実装: `if (isGoogleLinked) ...[_syncItem()]` でメニュー非表示。

    if (_isSyncing) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 12),
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white70),
        ),
      );
    }

    return PopupMenuButton<String>(
      icon: const Icon(Icons.menu),
      tooltip: l10n.calendarPageMenuTooltip,
      color: AppTheme.card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      onSelected: (value) {
        switch (value) {
          case 'google_sync':
            // 【FEAT-212】3 択ダイアログ（同期 / キャンセル / 同期解除）経由に変更
            _showGoogleCalendarDialog();
          default:
            final view = CalendarPageView.values.firstWhere((v) => v.name == value);
            widget.onSelected(view);
        }
      },
      itemBuilder: (_) => [
        _viewItem(CalendarPageView.monthly,   Icons.calendar_month_outlined, l10n.calendarPageViewMonthly),
        const PopupMenuDivider(),
        _viewItem(CalendarPageView.analytics, Icons.bar_chart_outlined,      l10n.calendarPageViewAnalytics),
        // 【FEAT-290】Google アカウント連携の有無に関わらず常に表示。
        // タップ時に GoogleCalendarSyncService が独立した Google サインインを
        // 起動し、ユーザーが選んだ Google アカウントのカレンダーを同期する。
        const PopupMenuDivider(),
        _syncItem(l10n),
      ],
    );
  }

  PopupMenuItem<String> _viewItem(
    CalendarPageView view,
    IconData icon,
    String label,
  ) {
    final isSelected = widget.currentView == view;
    return PopupMenuItem<String>(
      value: view.name,
      child: Row(
        children: [
          Icon(
            icon,
            size: 20,
            color: isSelected ? AppTheme.primary : Colors.white60,
          ),
          const SizedBox(width: 12),
          Text(
            label,
            style: TextStyle(
              color: isSelected ? AppTheme.primary : Colors.white70,
              fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
            ),
          ),
          if (isSelected) ...[
            const Spacer(),
            const Icon(Icons.check, size: 16, color: AppTheme.primary),
          ],
        ],
      ),
    );
  }

  PopupMenuItem<String> _syncItem(AppLocalizations l10n) {
    return PopupMenuItem<String>(
      value: 'google_sync',
      child: Row(
        children: [
          const Icon(Icons.sync, size: 20, color: Colors.white60),
          const SizedBox(width: 12),
          Text(
            l10n.calendarPageMenuGoogleSync,
            style: const TextStyle(color: Colors.white70),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 年月ピッカーダイアログ
// ─────────────────────────────────────────────────────────────────────────────

/// 年月を視覚的に選択するポップアップダイアログ。
///
/// - 年は < > ボタンで変更
/// - 月は 4×3 グリッドで選択
/// - 未来月はグレーアウト（選択不可）
/// - 現在の選択月を紫でハイライト
class _MonthPickerDialog extends StatefulWidget {
  final int initialYear;
  final int initialMonth;
  final void Function(int year, int month) onSelected;

  const _MonthPickerDialog({
    required this.initialYear,
    required this.initialMonth,
    required this.onSelected,
  });

  @override
  State<_MonthPickerDialog> createState() => _MonthPickerDialogState();
}

class _MonthPickerDialogState extends State<_MonthPickerDialog> {
  late int _pickerYear;

  @override
  void initState() {
    super.initState();
    _pickerYear = widget.initialYear;
  }

  void _prevYear() => setState(() => _pickerYear--);

  void _nextYear() {
    if (_pickerYear >= DateTime.now().year) return;
    setState(() => _pickerYear++);
  }

  @override
  Widget build(BuildContext context) {
    final l10n      = AppLocalizations.of(context)!;
    final now       = DateTime.now();
    final isMaxYear = _pickerYear >= now.year;

    return Dialog(
      backgroundColor: AppTheme.card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // ── 年選択ヘッダー ──────────────────────────────────────
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                IconButton(
                  icon: const Icon(Icons.chevron_left, color: Colors.white70),
                  onPressed: _prevYear,
                ),
                Text(
                  l10n.calendarPagePickerYearLabel(_pickerYear),
                  style: const TextStyle(
                    color:      Colors.white,
                    fontSize:   18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                IconButton(
                  icon: Icon(
                    Icons.chevron_right,
                    color: isMaxYear ? Colors.white24 : Colors.white70,
                  ),
                  onPressed: isMaxYear ? null : _nextYear,
                ),
              ],
            ),

            const SizedBox(height: 12),

            // ── 月グリッド（4列 × 3行）──────────────────────────────
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount:   4,
                childAspectRatio: 1.8,
                crossAxisSpacing: 8,
                mainAxisSpacing:  8,
              ),
              itemCount: 12,
              itemBuilder: (_, i) {
                final month      = i + 1;
                final isFuture   = _pickerYear > now.year ||
                    (_pickerYear == now.year && month > now.month);
                final isSelected = _pickerYear == widget.initialYear &&
                    month == widget.initialMonth;

                return InkWell(
                  onTap: isFuture
                      ? null
                      : () {
                          widget.onSelected(_pickerYear, month);
                          Navigator.of(context).pop();
                        },
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: isSelected
                          ? AppTheme.primary
                          : Colors.white.withValues(alpha: 0.07),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      l10n.calendarPagePickerMonthLabel(month),
                      style: TextStyle(
                        color: isFuture
                            ? Colors.white24
                            : isSelected
                                ? Colors.white
                                : Colors.white70,
                        fontWeight: isSelected
                            ? FontWeight.bold
                            : FontWeight.normal,
                        fontSize: 13,
                      ),
                    ),
                  ),
                );
              },
            ),

            const SizedBox(height: 16),

            // ── キャンセルボタン ────────────────────────────────────
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(
                l10n.commonCancel,
                style: const TextStyle(color: Colors.white54),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 【FEAT-212 → 2026-06-29】Google カレンダー解除ダイアログの選択肢。
// 「同期する」経路は _showSyncGoogleCalendarDialog で bool 戻り値に切替えたため、
// 本 enum は解除ダイアログ (cancel / unsync) の 2 値のみ。旧 sync 値は撤去。
// ─────────────────────────────────────────────────────────────────────────────

enum _GoogleCalendarAction { cancel, unsync }
