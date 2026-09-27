import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/services/toast_center.dart';  // 【2026-06-14】root ScaffoldMessenger 経由
import '../../../core/theme/app_theme.dart';
import '../../../l10n/app_localizations.dart';
import '../models/habit.dart';
import '../providers/habits_provider.dart';
import '../providers/completion_effect_provider.dart';
import '../../../shared/widgets/sabi_category_chips.dart' show habitCategoryLabel;

class HabitCard extends ConsumerStatefulWidget {
  final Habit habit;

  /// 【FEAT-418 (2026-06-10) → FEAT-441 (2026-06-17)】カード最左に挿入する任意 widget。
  /// 並び替えハンドル (ReorderableDragStartListener + Icons.drag_indicator [6 点 2×3
  /// グリッド ⠿]、FEAT-441 で Icons.drag_handle [≡] から差し替え) をカード装飾の
  /// 内側に配置するためのスロット。null なら未挿入で既存挙動互換、詳細ページ等の他
  /// caller は影響を受けない。
  final Widget? leading;

  const HabitCard({super.key, required this.habit, this.leading});

  @override
  ConsumerState<HabitCard> createState() => _HabitCardState();
}

class _HabitCardState extends ConsumerState<HabitCard> {
  bool _expanded = false;
  late List<ChecklistItem> _localItems;
  final Set<int> _toggling = {};
  bool _actionInFlight = false; // ＋ / ✓ の往復中フラグ (レビュー 20260824 §4-1 #1)
  bool _hintShown = false; // 1回限りのヒントを表示済みか

  @override
  void initState() {
    super.initState();
    _localItems = List.from(widget.habit.checklistItems);
  }

  @override
  void didUpdateWidget(HabitCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.habit != widget.habit) {
      _localItems = List.from(widget.habit.checklistItems);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final habit = widget.habit;
    // 【2026-06-13】スワイプで habit を移動 (案逆採択: Gmail/Pokemon 風):
    //   右スワイプ (startToEnd、background 表示) = アーカイブ
    //   左スワイプ (endToStart、secondaryBackground 表示) = ゴミ箱
    // 【BUG-135 (2026-06-17)】右スワイプにも確認ダイアログを追加 (ゴミ箱と同形式)。
    // ユーザー報告「誤操作スワイプ時、アーカイブから戻すのが手間」採択。
    // Undo SnackBar は二重防御として温存 (確認 + Undo の 2 段救済)。
    return Dismissible(
      key: ValueKey('habit-${habit.id}'),
      // ── 右スワイプ背景 (アーカイブ、グレー、📁 アイコン左寄せ) ──
      background: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 20),
        decoration: BoxDecoration(
          color: AppTheme.primary.withValues(alpha: 0.7),
          borderRadius: BorderRadius.circular(16),
        ),
        alignment: Alignment.centerLeft,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.archive_outlined, color: Colors.white, size: 26),
            const SizedBox(width: 8),
            Text(l10n.habitCardSwipeArchiveLabel,
                style: const TextStyle(color: Colors.white, fontSize: 14,
                    fontWeight: FontWeight.bold)),
          ],
        ),
      ),
      // ── 左スワイプ背景 (ゴミ箱、赤、🗑️ アイコン右寄せ) ──
      secondaryBackground: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 20),
        decoration: BoxDecoration(
          color: Colors.red.withValues(alpha: 0.85),
          borderRadius: BorderRadius.circular(16),
        ),
        alignment: Alignment.centerRight,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(l10n.habitCardSwipeTrashLabel,
                style: const TextStyle(color: Colors.white, fontSize: 14,
                    fontWeight: FontWeight.bold)),
            const SizedBox(width: 8),
            const Icon(Icons.delete_outline, color: Colors.white, size: 26),
          ],
        ),
      ),
      // 【FEAT-457 (2026-06-21)】スワイプ感度を 0.4 → 0.6 に引き下げ。
      // ユーザー報告「スクロール時に誤ってスワイプ commit される事象が多発」採択。
      // 旧 0.4 = 40% スワイプで commit、縦スクロール時の小さな横ぶれでも commit に
      // 達して archive/trash 確認ダイアログが出てしまう問題があった。
      // 新 0.6 = 60% スワイプ必須 = 明確に「横へ動かす」意図が必要 (Apple Mail /
      // WhatsApp の medium-firm 感度に近い)。BUG-135 確認ダイアログ + Undo
      // SnackBar の 2 段救済は引き続き維持 (本変更は「そもそも誤発火しない」
      // 1 段目の予防策の強化)。
      dismissThresholds: const {
        DismissDirection.startToEnd: 0.6,
        DismissDirection.endToStart: 0.6,
      },
      confirmDismiss: (direction) async {
        if (direction == DismissDirection.endToStart) {
          // ゴミ箱: 確認ダイアログ (誤操作で削除を防止)
          final confirmed = await showDialog<bool>(
            context: context,
            builder: (dialogContext) => AlertDialog(
              backgroundColor: AppTheme.surface,
              title: Text(l10n.habitCardTrashConfirmTitle,
                  style: const TextStyle(color: Colors.white)),
              content: Text(
                l10n.habitCardTrashConfirmContent(habit.name),
                style: const TextStyle(color: Colors.white70),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: Text(l10n.habitCardDialogCancelButton),
                ),
                TextButton(
                  style: TextButton.styleFrom(foregroundColor: Colors.red),
                  onPressed: () => Navigator.pop(dialogContext, true),
                  child: Text(l10n.habitCardTrashConfirmButton),
                ),
              ],
            ),
          );
          return confirmed == true;
        }
        // 【BUG-135 (2026-06-17)】アーカイブ: 確認ダイアログ (ゴミ箱と同形式)。
        // 旧仕様は「即実行 + Undo SnackBar」だったが、ユーザー報告「誤操作で
        // スワイプしてしまったとき、アーカイブから戻すのが手間」採択により、
        // 意思確認を取る形に変更。Undo SnackBar は onDismissed で温存。
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            backgroundColor: AppTheme.surface,
            title: Text(l10n.habitCardArchiveConfirmTitle,
                style: const TextStyle(color: Colors.white)),
            content: Text(
              l10n.habitCardArchiveConfirmContent(habit.name),
              style: const TextStyle(color: Colors.white70),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: Text(l10n.habitCardDialogCancelButton),
              ),
              TextButton(
                style: TextButton.styleFrom(foregroundColor: AppTheme.primary),
                onPressed: () => Navigator.pop(dialogContext, true),
                child: Text(l10n.habitCardArchiveConfirmButton),
              ),
            ],
          ),
        );
        return confirmed == true;
      },
      onDismissed: (direction) async {
        // 【2026-06-14 真因解消】ScaffoldMessenger.of(context) は widget tree
        // 依存で、Dismissible で widget dispose されると下位 ScaffoldMessenger
        // を参照し SnackBar Timer が干渉する。本対症療法だけでは消えない問題が
        // 残っていた。ToastCenter.messengerKey は main.dart で MaterialApp の
        // scaffoldMessengerKey に固定されており、widget tree 変化に影響され
        // ない root レベル ScaffoldMessenger。これに切り替えて Timer 安定化。
        //
        // 【2026-06-13 旧対症療法 (維持)】:
        //   1. hideCurrentSnackBar(): 既存 SnackBar がキューに残っていた場合の
        //      重複表示を防ぐ
        //   2. behavior: floating: 浮く表示で Timer 安定化 + UI 改善
        //   3. Future.delayed 100ms: Dismissible dispose 完了待ち
        final messenger = ToastCenter.messengerKey.currentState;
        if (messenger == null) return;  // app 未起動時の安全 fallback

        // 【2026-06-14】Flutter SnackBar の duration Timer が widget tree 変化
        // (Dismissible dispose) や ScaffoldMessenger 状態変化で「動かなくなる」
        // バグ対策。SnackBar 表示後に手動 Future.delayed で hideCurrentSnackBar
        // を強制呼び出しする二重防御。これで Flutter Timer が止まっていても
        // duration + 300ms 後に確実に消える。
        Future<void> showSb(
          SnackBar sb, {
          Duration duration = const Duration(seconds: 3),
        }) async {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          messenger
            ..hideCurrentSnackBar()
            ..showSnackBar(sb);
          // 二重防御: duration + 300ms 後に強制 hide
          Future<void>.delayed(
            duration + const Duration(milliseconds: 300),
            () => messenger.hideCurrentSnackBar(),
          );
        }

        if (direction == DismissDirection.startToEnd) {
          // 右スワイプ = アーカイブ
          try {
            await ref
                .read(habitsNotifierProvider.notifier)
                .archiveHabit(habit.id);
            // 【2026-06-14】duration 4→3 秒に短縮 (ゴミ箱と統一、ユーザー要望)。
            await showSb(
              SnackBar(
                content: Text(l10n.habitCardArchivedSabi_message(habit.name)),
                action: SnackBarAction(
                  label: l10n.habitCardUndoButton,
                  onPressed: () async {
                    try {
                      await ref
                          .read(habitsServiceProvider)
                          .restoreHabit(habit.id);
                      ref.invalidate(habitsNotifierProvider);
                    } catch (_) {
                      messenger
                        ..hideCurrentSnackBar()
                        ..showSnackBar(SnackBar(
                          content: Text(l10n.habitCardRestoreErrorSabi_message),
                          behavior: SnackBarBehavior.floating,
                          duration: const Duration(seconds: 3),
                        ));
                    }
                  },
                ),
                behavior: SnackBarBehavior.floating,
                duration: const Duration(seconds: 3),
              ),
            );
          } catch (_) {
            await showSb(SnackBar(
              content: Text(l10n.habitCardArchiveErrorSabi_message),
              behavior: SnackBarBehavior.floating,
              duration: const Duration(seconds: 3),
            ));
            // 状態を invalidate で再フェッチ (UI から消えた habit を戻す)
            ref.invalidate(habitsNotifierProvider);
          }
        } else {
          // 左スワイプ = ゴミ箱
          try {
            await ref
                .read(habitsNotifierProvider.notifier)
                .deleteHabit(habit.id);
            await showSb(
              SnackBar(
                content: Text(l10n.habitCardTrashedSabi_message(habit.name)),
                behavior: SnackBarBehavior.floating,
                duration: const Duration(seconds: 3),
              ),
            );
          } catch (_) {
            await showSb(SnackBar(
              content: Text(l10n.habitCardTrashErrorSabi_message),
              behavior: SnackBarBehavior.floating,
              duration: const Duration(seconds: 3),
            ));
            ref.invalidate(habitsNotifierProvider);
          }
        }
      },
      child: Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [

          // ── ① ヘッダー行（IntrinsicHeight 内）────────────────────
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [

                // ── 最左: ドラッグハンドル (FEAT-418、leading が non-null のとき) ──
                if (widget.leading != null) widget.leading!,

                // ── 左: メインコンテンツ（長押しで詳細ページへ）──────
                Expanded(
                  child: InkWell(
                    borderRadius: BorderRadius.only(
                      topLeft: const Radius.circular(16),
                      topRight: Radius.zero,
                      // チェックリスト型は下に展開エリアが続くため、下角は丸めない
                      bottomLeft: habit.habitType == 'checklist'
                          ? Radius.zero
                          : const Radius.circular(16),
                      bottomRight: Radius.zero,
                    ),
                    onTap: _onCardTap,
                    onLongPress: () => context.push('/habits/${habit.id}'),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _buildNameRowWithBadge(),
                          const SizedBox(height: 6),
                          _buildFooter(),
                        ],
                      ),
                    ),
                  ),
                ),

                // ── 縦区切り線 ────────────────────────────────────────
                VerticalDivider(
                  width: 1,
                  thickness: 1,
                  color: Colors.white.withValues(alpha: 0.10),
                  indent: 6,
                  endIndent: 6,
                ),

                // ── 右: アクションパネル ──────────────────────────────
                _buildActionPanel(context),

              ],
            ),
          ),

          // ── ② チェックリスト展開エリア（IntrinsicHeight の外）────
          if (habit.habitType == 'checklist') ...[
            Divider(
              height: 1,
              thickness: 1,
              color: Colors.white.withValues(alpha: 0.07),
            ),
            _buildChecklistToggle(),
            // ClipRect で AnimatedSize のはみ出しを物理的にクリップ（二重対策）
            ClipRect(
              child: AnimatedSize(
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeOut,
                child: _expanded
                    ? _buildExpandedChecklist()
                    : const SizedBox.shrink(),
              ),
            ),
          ],

        ],
      ),
      ),
    );
  }

  /// 短タップ: 1回限りのヒントを表示（2回目以降は無視）
  void _onCardTap() {
    if (_hintShown) return;
    setState(() => _hintShown = true);
    HapticFeedback.selectionClick();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          AppLocalizations.of(context)!.habitCardLongPressHintSabi_message,
          style: const TextStyle(color: Colors.white70, fontSize: 13),
        ),
        backgroundColor: const Color(0xFF2A2A3E),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  /// 習慣名・チップ行 ＋ カウント型の累計バッジを横並びにする
  Widget _buildNameRowWithBadge() {
    final count = _periodCount();
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: _buildNameAndChips()),
        if (count > 0) ...[
          const SizedBox(width: 6),
          _buildPeriodCountBadge(count),
        ],
      ],
    );
  }

  /// リセット周期内の累計回数を返す (count 型のみ)。
  ///
  /// 【BUG-73 fix 2026-05-27】旧実装は `period_progress.done` を優先して
  /// 「期間内達成**日数**」を表示していたが、daily + monthly のような
  /// `frequency != reset_cycle` の組み合わせで以下の UX バグが発生:
  ///   - + ボタン 1 回押下 → todayLog.count 0 → 1 (Backend に反映済)
  ///   - しかし pp.done = 今月の達成日数 = 1 のまま (今日 1 度押すと「今日達成済」=1 日)
  ///   - 2 回押しても 3 回押しても pp.done = 1 のまま (日数は変わらない)
  ///   - → ユーザー視点「カウントが増えない」と見えるが Backend は count++ 済
  ///
  /// そこで一旦 `todayCount` に一本化したが、それにより `reset_cycle` が
  /// **何も制御しない設定**として残った (バッジは常に今日の回数)。
  ///
  /// 【FEAT-520 2026-08-06】`habit.periodCount` (= `reset_cycle` 期間内の
  /// **回数の合計**) に差し替える。BUG-73 が禁じているのは `pp.done` (日数) で
  /// あって回数合計ではない。両者は名前が似ているが中身が違う:
  ///
  ///   pp.done     … 期間内に達成した「日数」 → + を 3 回押しても 1 のまま
  ///   periodCount … 期間内の count の合計    → + を 3 回押せば 3 増える
  ///
  /// `reset_cycle == 'daily'` (既存ユーザーの大多数) では `todayCount` と一致する
  /// ため、見た目は変わらない。
  int _periodCount() {
    final habit = widget.habit;
    if (habit.habitType != 'count') return 0;
    return habit.periodCount;
  }

  /// リセット周期内の累計回数バッジ（+N）
  Widget _buildPeriodCountBadge(int count) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: AppTheme.primary.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: AppTheme.primary.withValues(alpha: 0.35),
          width: 0.8,
        ),
      ),
      child: Text(
        '+$count',
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.bold,
          color: AppTheme.primary.withValues(alpha: 0.85),
        ),
      ),
    );
  }

  /// 習慣名 + 難易度・頻度・カテゴリチップを Wrap で並べる
  Widget _buildNameAndChips() {
    final l10n  = AppLocalizations.of(context)!;
    final habit = widget.habit;
    // 【FEAT-520 §5.3】カードの **外観** は frequency 期間基準。
    // 週次習慣を月曜に達成したら、その週いっぱい取り消し線が残る。
    // 操作系 (_buildActionPanel) は今日基準のまま — §5.4 / Pre-mortem #5 参照。
    final isCompleted = habit.isCompletedInPeriod;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AnimatedDefaultTextStyle(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.bold,
            color: isCompleted
                ? Colors.white.withValues(alpha: 0.45)
                : Colors.white,
            decoration: isCompleted
                ? TextDecoration.lineThrough
                : TextDecoration.none,
            decorationColor: Colors.white.withValues(alpha: 0.45),
          ),
          child: Text(habit.name),
        ),
        const SizedBox(height: 4),
        Wrap(
          spacing: 6,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            // 【FEAT-434 (2026-06-14)】Habit (count/checklist) の難易度 chip は廃止、
            // ToDo (habit_type='todo') のみ難易度 chip を表示する。
            if (habit.habitType == 'todo')
              _chip(habit.difficultyLabelL10n(l10n), _difficultyColor()),
            // 【FEAT-523 Phase 2 案 A】期間は達成済みだが今日はまだ、の状態を 1 つ説明する。
            //
            // 週次習慣を月曜に達成 → 火曜のカードには 3 つの信号が同時に並ぶ:
            //   習慣名        取り消し線     → 「達成済み」   (isCompletedInPeriod)
            //   ✓ / + ボタン  空のアイコン   → 「未達成」     (isCompletedToday)
            //   ストリーク保護 表示される     → 「途切れます」 (todayCount == 0)
            // FEAT-520 の判定分離 (外観 = 期間 / 操作 = 今日) 自体は正しく、
            // その理由はコードのコメントに書かれているが **画面には出ていない**。
            // 判定ロジックには一切触れず、チップ 1 つで 2 つの矛盾を整合させる。
            //
            // 【要素 C-3】ここはサビ口調にしない。チップ行は難易度 / 頻度 /
            // カテゴリという機械的な情報の列で、1 つだけサビの声が混ざると
            // 聖域性が薄まる。サビの言葉は SnackBar / ダイアログ / 空状態に留める。
            //
            // frequency == 'daily' では isCompletedInPeriod == isCompletedToday
            // (Backend の period_done は frequency 窓 = 今日) なので発火しない。
            if (_periodDoneChipLabel(l10n) != null)
              _chip(_periodDoneChipLabel(l10n)!, AppTheme.expColor),
            _chip(habit.frequencyLabelL10n(l10n), Colors.blueGrey),
            _chip(habitCategoryLabel(l10n, habit.category), _categoryColor()),
          ],
        ),
      ],
    );
  }

  /// 【FEAT-523 Phase 2 案 A】「今週/今月は達成済み」チップの文言。
  ///
  /// 出す条件は **期間は達成済み かつ 今日はまだ** の 1 点のみ。
  /// `frequency` が `daily` の習慣 (既存ユーザーの大多数) では 2 つが一致するため
  /// null を返し、チップは 1 度も出ない。
  String? _periodDoneChipLabel(AppLocalizations l10n) {
    final habit = widget.habit;
    if (!habit.isCompletedInPeriod || habit.isCompletedToday) return null;
    switch (habit.frequency) {
      case 'weekly':
        return l10n.habitCardPeriodDoneWeek;
      case 'monthly':
        return l10n.habitCardPeriodDoneMonth;
      default:
        return null;
    }
  }

  /// フッター: 現在ストリーク（左）＋ 最長ストリーク（右）
  /// 【FEAT-377 → FEAT-420 (2026-06-10) 予約モード化】
  /// ストリーク保護ボタン: today 未達成 + streak > 0 + 在庫あり + 未予約 + 自動保護 OFF のとき表示
  Widget _buildFooter() {
    final habit = widget.habit;
    final player = ref.watch(playerNotifierProvider).valueOrNull;
    // 【FEAT-523 Phase 2 案 B (2026-08-07)】期間の義務を果たしている習慣には
    // 「守りますか」と聞かない。
    //
    // FEAT-420 の予約モードの趣旨は「途切れそうな時だけ静かに差し出す」で、
    // 週次習慣を月曜に達成した翌日に保護を勧めるのはその趣旨と合っていない。
    // 案 A のチップ (「今週は達成済み」) で取り消し線と空ボタンの矛盾は説明が
    // 付いたが、保護ボタンだけが「このままだと途切れます」と主張し続けていた。
    //
    // 【実測 2026-08-07】`frequency == 'daily'` の習慣 (既存ユーザーの大多数) では
    // **1 度も挙動が変わらない**。Backend の `period_done` は frequency 窓 = 今日
    // なので `periodDone == (todayCount > 0)` となり、
    //   todayCount == 0 → periodDone は必ず false → 表示 (変化なし)
    //   todayCount >= 1 → 上の `todayCount == 0` で既に非表示 (変化なし)
    // 実際に効くのは weekly / monthly の「期間は達成済み・今日はまだ」の 1 ケースだけ。
    // この不変条件は habit_period_semantics_test.dart が固定している。
    final canShowProtect = habit.streak > 0
        && habit.todayCount == 0
        && !habit.periodDone
        && (player?.streakProtectionCount ?? 0) > 0
        && !(player?.streakProtectionPending ?? false)
        && !(player?.streakProtectionAutoEnabled ?? false);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.local_fire_department,
                size: 13, color: Colors.orange),
            const SizedBox(width: 2),
            Text(
              AppLocalizations.of(context)!.habitCardStreakDays(habit.streak),
              style: const TextStyle(fontSize: 11, color: Colors.orange),
            ),
            const Spacer(),
            Text(
              AppLocalizations.of(context)!.habitCardBestStreakDays(habit.bestStreak),
              style: TextStyle(
                  fontSize: 11, color: Colors.white.withValues(alpha: 0.35)),
            ),
          ],
        ),
        if (canShowProtect) ...[
          const SizedBox(height: 6),
          _StreakProtectButton(habit: habit),
        ],
      ],
    );
  }

  /// チェックリスト展開トグルボタン（X/Y 完了）
  Widget _buildChecklistToggle() {
    final doneCount = _localItems.where((i) => i.isDone).length;
    final total = _localItems.length;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => setState(() => _expanded = !_expanded),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Row(
          children: [
            Icon(
              _expanded ? Icons.expand_less : Icons.expand_more,
              size: 14,
              color: Colors.white38,
            ),
            const SizedBox(width: 4),
            Text(
              AppLocalizations.of(context)!.habitCardChecklistProgress(doneCount, total),
              style: const TextStyle(fontSize: 11, color: Colors.white38),
            ),
          ],
        ),
      ),
    );
  }

  /// 展開時のチェックリスト内容（AnimatedSize は呼び出し元で管理）
  Widget _buildExpandedChecklist() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
      child: Column(
        children: _localItems
            .map((item) => _buildChecklistItemTile(item))
            .toList(),
      ),
    );
  }

  /// 個別チェックリスト項目タイル
  Widget _buildChecklistItemTile(ChecklistItem item) {
    // 【FEAT-533 §8-3】`_actionInFlight` (✓ / ＋ ボタン側) も見る。逆方向を塞がないと、
    // ✓ の往復中に項目タイルが素通りして「楽観的にチェックが付く → `toggleChecklistItem`
    // が `_inFlight` で早期 return (throw しない) → catch に入らないので楽観更新が
    // 戻らない」= **チェックが付いたまま、サーバーには何も無い**状態が残る。
    final isToggling = _toggling.contains(item.id);
    final blocked = isToggling || _actionInFlight;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: blocked ? null : () => _handleItemToggle(item),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          children: [
            isToggling
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 1.5),
                  )
                : Icon(
                    item.isDone
                        ? Icons.check_box_rounded
                        : Icons.check_box_outline_blank_rounded,
                    size: 16,
                    color: item.isDone ? AppTheme.primary : Colors.white38,
                  ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                item.text,
                style: TextStyle(
                  fontSize: 13,
                  color: item.isDone
                      ? Colors.white.withValues(alpha: 0.4)
                      : Colors.white70,
                  decoration: item.isDone
                      ? TextDecoration.lineThrough
                      : TextDecoration.none,
                  decorationColor: Colors.white.withValues(alpha: 0.3),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 個別チェックリスト項目のトグル（楽観的 UI 更新）
  Future<void> _handleItemToggle(ChecklistItem item) async {
    // 【FEAT-533 §8-3】`onTap: null` と二重の防御。触覚より先に置くこと。
    if (_actionInFlight || _toggling.contains(item.id)) return;

    HapticFeedback.selectionClick();
    // 【BUG-150】await をまたぐので l10n は先に capture する。
    final l10n = AppLocalizations.of(context)!;

    // 楽観的更新
    setState(() {
      _toggling.add(item.id);
      _localItems = _localItems.map((i) {
        return i.id == item.id ? i.copyWith(isDone: !i.isDone) : i;
      }).toList();
    });

    try {
      if (!item.isDone) {
        // 未完了 → 完了: エフェクト発動のためタップ座標を保存
        _storeTapPosition(context, ref);
      }
      await ref
          .read(habitsNotifierProvider.notifier)
          .toggleChecklistItem(widget.habit.id, item.id, l10n: l10n);
    } catch (_) {
      // エラー時は楽観的更新を元に戻す
      setState(() {
        _localItems = _localItems.map((i) {
          return i.id == item.id ? i.copyWith(isDone: item.isDone) : i;
        }).toList();
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              AppLocalizations.of(context)!.habitCardNetworkErrorSabi_message,
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
            backgroundColor: const Color(0xFF2A2A3E),
            duration: const Duration(seconds: 3),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _toggling.remove(item.id));
    }
  }

  /// 右端アクションパネル。チェックリスト / カウントで異なるボタンを表示。
  ///
  /// 【FEAT-520 §5.4】ここは **`isCompletedToday` のまま**にすること。
  ///
  /// ✓ ボタンは完了状態なら `decrementCount` を呼ぶが、Backend の `_apply_minus()`
  /// は **今日の log が 0 なら `no_op`** で何もしない
  /// (`habit_count_service.py:626`)。`isCompletedInPeriod` に繋ぎ替えると、
  /// 週次習慣を月曜に達成 → 火曜に ✓ を押す経路で **タップしても無反応**になる。
  /// エラーも出ないので実装中は気付けない。
  ///
  /// 結果として週次習慣では「カードは達成済み外観 / ボタンは未チェック」が並ぶが、
  /// これは「今週は達成済み、ただし今日はまだ」という正しい情報である。
  ///
  /// 【ゲームプレイレビュー 20260824 §4-1 #1 (2026-08-25)】飛行中のタップを
  /// **黙って捨てるのをやめた**。チェックリスト項目
  /// (`_buildChecklistItemTile` / `_handleItemToggle`) と同じ 3 点セットに揃える:
  ///
  ///   ① 飛行中は `onTap: null`   …… 触覚が鳴らない = 嘘をつかない
  ///   ② 飛行中は spinner を描く   …… 「処理中」が目に見える
  ///   ③ 触覚と `_storeTapPosition` は **実際に送信する経路の中だけ**で呼ぶ
  ///
  /// 🔴 直したのは **UI が黙っていたこと**で、`_inFlight` guard 自体ではない。
  /// guard は BUG-71 の構造修正として正しいので触らない。ここはその guard が
  /// 働いたことをユーザーに見せる層である。
  ///
  /// 🔵 レビューは ＋ ボタンだけを挙げていたが、**同じメソッドの ✓ ボタンも
  /// 同じ形をしていた**ので両方直した (REVIEWER_LESSONS 失敗 18: 同じ関数の中の
  /// 2 件目を数えない)。
  Widget _buildActionPanel(BuildContext context) {
    final habit = widget.habit;
    final isCompleted = habit.isCompletedToday;
    // 【FEAT-533 §8-3 (2026-08-25)】守り手は 2 つ (`_actionInFlight` = このパネル /
    // `_toggling` = 項目タイル) だが、**守る対象は 1 つ** (`_inFlight[habitId]`) なので
    // 合流させる。分けたままだと、項目タイルの往復中に ✓ を押したとき `busy` が false で
    // **触覚がまた嘘をつく**。
    final busy = _actionInFlight || _toggling.isNotEmpty;

    if (habit.habitType == 'checklist') {
      // ── チェックリスト: ✓ ボタン ───────────────────────────────
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: busy ? null : () => _handleCountAction(toggleOff: isCompleted),
        child: SizedBox(
          width: 56,
          child: Center(
            child: busy
                ? const _ActionSpinner()
                : Icon(
                    isCompleted
                        ? Icons.check_circle
                        : Icons.check_circle_outline,
                    color: isCompleted ? AppTheme.expColor : Colors.white38,
                    size: 28,
                  ),
          ),
        ),
      );

    } else {
      // ── カウント: ＋ ボタン ────────────────────────────────────
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: busy ? null : () => _handleCountAction(toggleOff: false),
        child: SizedBox(
          width: 56,
          child: Center(
            child: busy
                ? const _ActionSpinner()
                : Icon(
                    isCompleted ? Icons.add_circle : Icons.add_circle_outline,
                    color: isCompleted ? AppTheme.primary : Colors.white38,
                    size: 28,
                  ),
          ),
        ),
      );
    }
  }

  /// アクションパネルのタップ処理 (＋ / ✓ 共通)。
  ///
  /// 【ゲームプレイレビュー 20260824 §4-1 #1】触覚 (`lightImpact`) と
  /// `_storeTapPosition` を **guard の内側**で呼ぶ。外に置くと
  /// `incrementCount` / `decrementCount` が `_inFlight` で早期 return した回でも
  /// 振動が鳴り、タップ座標だけが書き換わる —— 「振動は 3 回、数字は +1」という、
  /// 取りこぼしにしか見えない状態になる。
  ///
  /// ⚠️ `_actionInFlight` の解放は **必ず `finally`** に置くこと。`_inFlight` は
  /// まさにこの解放漏れで BUG-71 になった (`firstWhere` の `StateError` が try の
  /// 外にあった)。同じ穴を UI 側に作らない。
  ///
  /// 契約テスト: `mobile/test/habits/habit_action_tap_feedback_test.dart`
  Future<void> _handleCountAction({required bool toggleOff}) async {
    if (_actionInFlight) return;
    setState(() => _actionInFlight = true);

    HapticFeedback.lightImpact();

    final notifier = ref.read(habitsNotifierProvider.notifier);
    final l10n = AppLocalizations.of(context);

    try {
      if (toggleOff) {
        await notifier.decrementCount(widget.habit.id);
      } else {
        // 未完了 → 完了: エフェクト発動のためタップ座標を保存
        _storeTapPosition(context, ref);
        await notifier.incrementCount(widget.habit.id, l10n: l10n);
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              AppLocalizations.of(context)!.habitCardNetworkErrorSabi_message,
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
            backgroundColor: const Color(0xFF2A2A3E),
            duration: const Duration(seconds: 3),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _actionInFlight = false);
    }
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

  Color _difficultyColor() {
    const map = {
      'easy': Colors.green,
      'hard': Colors.orange,
      'legendary': Colors.purple,
    };
    return map[widget.habit.difficulty] ?? Colors.blue;
  }

  Color _categoryColor() {
    // 【FEAT-307】FEAT-213 真実値 11 値全カバー。'メンタル' → '精神' /
    // '作業' → '仕事' / '交流' → '社交' は migration 0066 で死語化済。
    // 残り 7 カテゴリ (仕事/体力/美容/創造/社交/休息/その他) も追加。
    const map = {
      '運動':   Colors.redAccent,
      '学習':   Colors.blueAccent,
      '仕事':   Color(0xFF5B9BD5),     // スチールブルー
      '体力':   Color(0xFFFF8A65),     // 橙
      '美容':   Color(0xFFEC6EA0),     // ローズピンク
      '健康':   Colors.greenAccent,
      '精神':   Colors.purpleAccent,
      '創造':   Color(0xFFFFB74D),     // アンバー
      '社交':   Color(0xFFEC6EA0),     // ローズピンク
      '休息':   Color(0xFF80CBC4),     // ティール
      'その他': Color(0xFF78909C),     // ブルーグレー
    };
    return map[widget.habit.category] ?? Colors.blueGrey;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// ヘルパー関数
// ─────────────────────────────────────────────────────────────────────────────

// ─────────────────────────────────────────────────────────────────────────────
// 【FEAT-377】ストリーク保護ボタン
// ─────────────────────────────────────────────────────────────────────────────

/// 「🛡️ 保護を予約する」ボタン。streak > 0 + today 未達成 + 在庫あり + 未予約 +
/// 自動保護 OFF のときのみ表示。
/// 【FEAT-420 (2026-06-10)】タップ → 予約 (pending=True) を設定するのみ。
/// 在庫消費 / 救済判定は翌日の習慣達成時に Backend が行う。
class _StreakProtectButton extends ConsumerStatefulWidget {
  const _StreakProtectButton({required this.habit});
  final Habit habit;

  @override
  ConsumerState<_StreakProtectButton> createState() =>
      _StreakProtectButtonState();
}

class _StreakProtectButtonState extends ConsumerState<_StreakProtectButton> {
  bool _loading = false;

  @override
  Widget build(BuildContext context) {
    final player = ref.watch(playerNotifierProvider).valueOrNull;
    final count  = player?.streakProtectionCount ?? 0;

    return GestureDetector(
      onTap: _loading ? null : _onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: Colors.orange.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: Colors.orange.withValues(alpha: 0.4)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_loading)
              const SizedBox(
                width: 10, height: 10,
                child: CircularProgressIndicator(
                  strokeWidth: 1.5, color: Colors.orange,
                ),
              )
            else
              const Text('🛡️', style: TextStyle(fontSize: 11)),
            const SizedBox(width: 4),
            Text(
              AppLocalizations.of(context)!.habitCardStreakProtectButton(count),
              style: const TextStyle(fontSize: 11, color: Colors.orange),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _onTap() async {
    setState(() => _loading = true);
    try {
      // 【FEAT-420 (2026-06-10)】予約 (pending=True) を設定するのみ。
      // 在庫消費 / 救済判定は翌日の習慣達成時に Backend が行う。
      await ref
          .read(playerNotifierProvider.notifier)
          .setStreakProtectionPending(true);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              AppLocalizations.of(context)!.habitCardStreakProtectSuccessSabi_message,
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              AppLocalizations.of(context)!.habitCardStreakProtectErrorSabi_message,
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }
}

/// カードの現在の画面上の中心座標を [completionTapPositionProvider] に保存する。
///
/// - [context] は `HabitCard` の BuildContext（クロージャで渡す）。
/// - `findRenderObject()` はボタン押下時に同期で呼ぶため、
///   マウント状態の変化を気にする必要はない。
void _storeTapPosition(BuildContext context, WidgetRef ref) {
  final box = context.findRenderObject() as RenderBox?;
  if (box == null) return;
  final center = box.localToGlobal(
    Offset(box.size.width / 2, box.size.height / 2),
  );
  ref.read(completionTapPositionProvider.notifier).state = center;
}

// ─────────────────────────────────────────────────────────────────────────────
// 【ゲームプレイレビュー 20260824 §8-5】アクションパネルのスピナー
//
// 🔴 このクラスは元々 `_StreakProtectButton` のセクションバナーと docstring の
// **あいだ**に挿入されており、`_StreakProtectButton` から docstring を奪っていた
// (FEAT-420「在庫消費は翌日」という**コードからは読み取れない仕様**が
// スピナーの説明文になっていた)。ファイル末尾に移設して所在を戻した。
// **クラスを足すときは、直前の docstring が誰のものかを見ること。**
// ─────────────────────────────────────────────────────────────────────────────

/// アクションパネル (＋ / ✓) の往復中に描くスピナー。
///
/// 【ゲームプレイレビュー 20260824 §4-1 #1】チェックリスト項目の 16px は
/// アイコンが 16px だから 16px。こちらはアイコンが 28px なので一回り大きく取る。
/// タップ領域 (56px 幅の `SizedBox`) は据え置きで、**押せる面積は変えない**。
class _ActionSpinner extends StatelessWidget {
  const _ActionSpinner();

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      width: 20,
      height: 20,
      child: CircularProgressIndicator(strokeWidth: 2),
    );
  }
}
