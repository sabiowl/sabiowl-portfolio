// 【FEAT-493 (2026-07-25)】フリーメモ専用画面 (/memos)。
//
// 構成 (single-tab、旧 4 タブ構成は commit 174a5b5 で廃止):
//   メモ一覧 (Dismissible swipe 削除/変換) + 下部固定入力欄
//   使わない人向け空状態案内 (memo 0 件時のみ、49b0e8c で追加)
//
// Swipe 操作 (習慣カード方向に統一、commit 98de5d7):
//   左スワイプ (endToStart)  → 削除 (「ゴミ箱」ラベル、赤)、確認ダイアログ + 削除確定 SnackBar
//   右スワイプ (startToEnd)  → 変換 (「登録」ラベル、紫)、変換ダイアログ → 既存 add_*_page へ遷移 + convert API
//
// 【2026-07-25 update】旧 2 秒 undo 猶予は撤廃 (user 報告「戻せない状態で誤解を招く」
// への対応)。確認ダイアログで意思確認を取っている前提で、確定押下 = 即時 API 削除
// に統一。SnackBar は完了通知のみ (action なし)。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../../core/analytics/posthog_service.dart';
import '../../../core/router/app_router.dart';
import '../../../core/services/toast_center.dart';
import '../../../core/services/voice_input_service.dart';
import '../../../core/theme/app_theme.dart';
import '../../../l10n/app_localizations.dart';
import '../models/free_memo.dart';
import '../providers/free_memo_provider.dart';
// 【FEAT-500 レビュー §C1 (2026-07-26)】memo_page.dart 分割で抽出済 widget 群。
import '../widgets/highlighted_text.dart';
import '../widgets/memo_edit_sheet.dart';
import '../../../features/habits/models/habit.dart' show HabitReward;  // 【FEAT-498 §2.3】
import '../../../features/habits/providers/habits_provider.dart' show playerNotifierProvider;  // 【FEAT-498 §2.4】
import '../../../shared/widgets/reward_toast.dart';  // 【FEAT-498 §2.3】
import '../../../shared/widgets/sabi_flow_diagram.dart';
import '../widgets/memo_trash_sheet.dart';
import '../widgets/memo_waveform_painter.dart';
import 'package:shared_preferences/shared_preferences.dart';  // 【FEAT-498 §2.4】

enum _VoiceState { idle, listening, processing }

class MemoPage extends ConsumerStatefulWidget {
  /// Calendar FAB から遷移した場合に選択日を引き継ぐ (予定タブの initialDate に使用)。
  /// null = 今日の日付をデフォルトとして使用。
  /// 【2026-07-25】タブ廃止に伴い現在未使用 (旧 予定タブに `initialDate` として
  /// pre-fill していたが、タブ廃止で参照経路なし)。Calendar FAB からは引き続き
  /// 渡されるため field は保持 (constructor API 互換維持)。将来 date-aware
  /// なメモ機能 (例: 「明日のメモ」プレフィックス) 検討時に活用余地あり。
  final DateTime? selectedDate;

  /// 【FEAT-493】どこからメモ画面に遷移したかの entry point ('home_fab' / 'calendar_fab' / 'home_section')。
  final String entryPoint;

  const MemoPage({super.key, this.selectedDate, this.entryPoint = 'home_fab'});

  @override
  ConsumerState<MemoPage> createState() => _MemoPageState();
}

class _MemoPageState extends ConsumerState<MemoPage>
    with SingleTickerProviderStateMixin {
  final _inputCtrl = TextEditingController();
  // 【2026-07-25】旧 `bool _saving` は撤去。createMemo が楽観的更新化されたため
  // 送信ボタンのスピナー UI は不要 (入力欄が即クリアされる = 送信完了の視覚合図)。
  var _voiceState = _VoiceState.idle;
  // 【FEAT-499 (2026-07-26)】listening 状態の波形アニメーション用
  late final AnimationController _waveAnimCtrl;
  // 【FEAT-499 v1.0 増分 (2026-07-26、Gemini §2/§6/§9 対応)】
  // 録音経過時間 + partial 認識テキスト (ChatGPT 型リアルタイム表示)。
  //   - _voiceElapsed: listening 中に 1 秒ごとに増加 (右端に "0:15" 表示)
  //   - _voicePartial: onPartial callback で逐次更新される中間認識テキスト
  //     空文字 = まだ話していない (「話してください 🪶」hint を表示)
  //     非空   = リアルタイム認識中 (partial を grey で表示)
  Duration _voiceElapsed = Duration.zero;
  Timer? _voiceTimer;
  // 【FEAT-501 C (2026-07-26)】partial 認識テキスト / dB 連動音量を ValueNotifier 化。
  // onSoundLevelChange は Android で 10〜20 回/秒発火する。旧実装は setState で
  // ページ全体 (メモ一覧 Element 再構築まで) rebuild していたが、これらを
  // ValueNotifier + ValueListenableBuilder で入力欄 pill の波形/partial 部分に
  // rebuild を閉じ込める。
  //   - _voicePartial: onPartial callback で逐次更新 (空=波形、非空=partial text)
  //   - _voiceSoundLevel: 0.0=静音 / 1.0=大声。EMA で smoothing、端末が
  //     onSoundLevelChange 未発火なら 0.0 のまま (fallback = subtle 動きのみ)。
  final _voicePartial = ValueNotifier<String>('');
  final _voiceSoundLevel = ValueNotifier<double>(0.0);

  // ── FEAT-508 (2026-07-29) 検索 ──────────────────────────────────────────
  final _searchCtrl = TextEditingController();
  String _searchQuery = '';
  Timer? _searchDebouncer;

  // ── 【FEAT-498 §2.3 (2026-07-31)】メモ変換報酬 overlay ─────────────────
  // 旧: 「$label に決めました +N EXP 🪶」1 本 SnackBar (2 秒)。
  // 新: RewardToastOverlay (intensity: subtle) で「習慣完了 / かけら獲得と同じ
  //     overlay レイヤー」に寄せる。SnackBar は退場、Overlay.insert で表示。
  //     視覚的に「Sabiowl で EXP が入る = この overlay」の単一語彙を確立。
  //     dispose 時は remove して leak 防止。
  OverlayEntry? _convertRewardEntry;

  // ── 【FEAT-498 §2.4 (2026-07-31)】サビ月 1 回穏やか促し (常設 1 行 banner) ─
  // 旧: home_listeners.dart で SnackBar 6 秒発火 (FEAT-493 導入 2026-07-25)。
  // 新: メモ画面到達時に「その月に 1 回だけ静かに現れる」1 行に配置換え。
  //   - 条件: freeMemoEnabled=true AND memo count > 0 AND monthKey 未 set
  //   - SharedPreferences key `free_memo_sabi_prompt_YYYY_M` は既存書式流用
  //   - dismiss button なし = 「1 度見た = 月末までスルー」(表示時に flag set)
  //   - Sabi 哲学: 「呼びつける存在」ではなく「そこにいる存在」
  bool _showMonthlyPrompt = false;

  @override
  void initState() {
    super.initState();
    _waveAnimCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    );
    // 【FEAT-493】一覧閲覧イベント (best-effort, postFrameCallback でメモ件数確定後)
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final memos = ref.read(freeMemoNotifierProvider).valueOrNull ?? [];
      await PosthogService.instance.capture('free_memo_list_viewed', properties: {
        'count_visible': memos.length,
        'entry_point': widget.entryPoint,
      });
      // 【FEAT-498 §2.4 (2026-07-31)】サビ月 1 回穏やか促し判定 (旧 home_listeners
      // 経路から移設)。ホーム画面 SnackBar 発火は撤去済 (home_listeners.dart)。
      if (mounted) await _maybeShowMonthlyPrompt();
    });
  }

  /// 【FEAT-498 §2.4 (2026-07-31)】サビ月 1 回穏やか促し banner の判定 + 表示 flag set。
  ///
  /// 条件:
  ///   - freeMemoEnabled=true (機能自体が opt-in ON)
  ///   - memo count > 0 (未整理メモがある)
  ///   - SharedPreferences key `free_memo_sabi_prompt_YYYY_M` 未 set (当月未表示)
  ///
  /// 表示成功時に flag を set = 「1 度見た = 月末までスルー」(Sabi 哲学 : 呼びつけない)。
  /// 失敗 (permission / IO error) はサイレント吸収、メモ画面機能は影響なし。
  Future<void> _maybeShowMonthlyPrompt() async {
    try {
      final player = ref.read(playerNotifierProvider).valueOrNull;
      if (player == null || !player.freeMemoEnabled) return;
      final memos = ref.read(freeMemoNotifierProvider).valueOrNull ?? [];
      if (memos.isEmpty) return;

      final now = DateTime.now();
      final monthKey = 'free_memo_sabi_prompt_${now.year}_${now.month}';
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(monthKey) == true) return; // 今月表示済み

      if (!mounted) return;
      setState(() => _showMonthlyPrompt = true);
      // 表示に到達したら即 set (memo_page を閉じても monthKey 消費、翌月まで再表示なし)。
      // 旧 SnackBar 経路と同じ「表示成功 = 月消費」契約を維持。
      await prefs.setBool(monthKey, true);
    } catch (_) {
      // 促し表示の失敗はアプリ機能に影響させない
    }
  }

  @override
  void dispose() {
    _inputCtrl.dispose();
    _searchCtrl.dispose();
    _searchDebouncer?.cancel();
    _waveAnimCtrl.dispose();
    // 【FEAT-501 C】ValueNotifier leak 防止 (S4)。_waveAnimCtrl.dispose() の直下に
    // 並べて配置 (視覚的に忘れにくい、既存の Ticker cleanup と同じ場所に集約)。
    _voicePartial.dispose();
    _voiceSoundLevel.dispose();
    _voiceTimer?.cancel();
    _voiceTimer = null;
    VoiceInputService.instance.cancel(); // BUG-66: dispose 時の緊急停止
    // 【FEAT-498 §2.3】overlay leak 防止 (dispose 中に自動 remove タイマーが
    // 発火する race を回避、entry.mounted を確認せず try/catch で吸収)。
    _convertRewardEntry?.remove();
    _convertRewardEntry = null;
    super.dispose();
  }

  /// 【FEAT-498 §2.3 (2026-07-31)】メモ変換成功時に表示する subtle reward overlay。
  ///
  /// habit 完了 (home_listeners.dart:_showRewardToast) と同じ Overlay 挿入
  /// パターンを踏襲。intensity: subtle で「+3 EXP」インフレ感を避けつつ
  /// 「Sabiowl で EXP が入る = この overlay」の視覚語彙を統一する。
  void _showConvertRewardOverlay(String label, int expGain) {
    final l10n = AppLocalizations.of(context)!;
    _convertRewardEntry?.remove();
    final reward = HabitReward(
      expGain: expGain,
      bonusExp: 0,
      diamondEarned: false,
    );
    _convertRewardEntry = OverlayEntry(
      builder: (_) => RewardToastOverlay(
        reward: reward,
        intensity: RewardIntensity.subtle,
        leadingText: l10n.freeMemoPageConvertedLeadingText(label),
      ),
    );
    Overlay.of(context).insert(_convertRewardEntry!);
    // RewardToastOverlay 内部 anim (fade-in 200ms + hold 1200ms + fade-out 200ms)
    // = 1600ms 相当 + 100ms buffer で 1700ms 後に remove。home_listeners と同期。
    Future.delayed(const Duration(milliseconds: 1700), () {
      _convertRewardEntry?.remove();
      _convertRewardEntry = null;
    });
  }

  // ── 削除 ─────────────────────────────────────────────────────────────────
  //
  // 【2026-07-25 update】旧 2 秒 undo 猶予 (Timer / _pendingDelete /
  // _undoDelete / _flushPendingDelete) は撤廃。確認ダイアログで意思確認を
  // 取っている前提で、確定押下 = 即時 API 削除 + 完了 SnackBar のみ。

  Future<void> _handleSwipeDelete(FreeMemo memo) async {
    final l10n = AppLocalizations.of(context)!;
    // 【FEAT-498 §2.1 (gameplay-review #6)】destructive 操作に触覚 feedback。
    // habit_card.dart 側 destructive swipe と手触りを揃える (lightImpact 統一)。
    HapticFeedback.lightImpact();
    // 楽観的 UI 削除 → 即時 API delete。
    ref.read(freeMemoNotifierProvider.notifier).optimisticRemove(memo.id);
    final daysSince = DateTime.now().difference(memo.createdAt).inDays;

    // 【FEAT-503 アクション10 (2026-07-26)】完了通知 SnackBar を「削除しました」→
    // 「ゴミ箱に移しました 🪶」に変更 (soft delete + 復元導線の案内、AppBar ゴミ箱
    // アイコン以外の発見経路を確保)。⚠️ 2 秒 undo は復活させない (b26d296 で
    // 「戻せない状態で誤解を招く」として撤廃済、本変更は文言 1 行のみ)。
    // habit_card.dart pattern を継承: root-level messengerKey + Dismissible
    // dispose 完了待ち + 二重防御 hide。
    final messenger = ToastCenter.messengerKey.currentState;
    if (messenger != null) {
      const snackDuration = Duration(seconds: 2);
      Future<void>.delayed(const Duration(milliseconds: 100), () {
        messenger
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text(l10n.freeMemoPageMovedToTrashSnack),
              behavior: SnackBarBehavior.floating,
              duration: snackDuration,
            ),
          );
        Future<void>.delayed(
          snackDuration + const Duration(milliseconds: 300),
          () => messenger.hideCurrentSnackBar(),
        );
      });
    }

    // 【FEAT-503 アクション9 (2026-07-26)】API delete。失敗しても state は復旧
    // しない (楽観削除、次回 refresh で戻る) が、握り潰さず SnackBar で通知する。
    // deleteMemo は失敗時 rethrow するようになった (free_memo_provider.dart)。
    try {
      await ref.read(freeMemoNotifierProvider.notifier).deleteMemo(
            memo.id,
            daysSinceCreated: daysSince,
          );
    } catch (_) {
      messenger
        ?..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(l10n.freeMemoPageDeleteErrorSnack),
            behavior: SnackBarBehavior.floating,
          ),
        );
    }
  }

  // ── 変換ダイアログ ────────────────────────────────────────────────────────

  Future<void> _handleSwipeConvert(FreeMemo memo) async {
    final l10n = AppLocalizations.of(context)!;
    // ダイアログを表示 (BUG-65: dialogContext 経由で Navigator.pop)
    final type = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppTheme.card,
        title: Text(
          l10n.freeMemoPageConvertDialogTitle,
          style: const TextStyle(color: Colors.white, fontSize: 16),
        ),
        contentPadding: const EdgeInsets.symmetric(vertical: 8),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildConvertOption(dialogContext, '📅', l10n.freeMemoPageConvertOptionEvent, 'event'),
            _buildConvertOption(dialogContext, '✅', l10n.freeMemoPageConvertOptionTodo, 'todo'),
            _buildConvertOption(dialogContext, '🔁', l10n.freeMemoPageConvertOptionHabit, 'habit'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(l10n.commonCancel, style: const TextStyle(color: Colors.white54)),
          ),
        ],
      ),
    );

    if (type == null) return;
    if (!mounted) return;

    // BUG-65: ダイアログが完全に閉じるまで待つ
    await Future.delayed(const Duration(milliseconds: 300));
    if (!mounted) return;

    // タイトル先頭 100 文字を pre-fill
    final title = memo.text.length > 100 ? memo.text.substring(0, 100) : memo.text;

    bool? result;
    switch (type) {
      case 'event':
        // 【FEAT-498 §2.2 (2026-07-26)】widget.selectedDate (Calendar FAB からの
        // 引継ぎ) or 今日を initialDate として渡す。AddEventPage 側で日付
        // ピッカーで変更可能 (v1.0.4 追加、gameplay-review §2-1 案 C 本質解決)。
        result = await context.push<bool>(
          AppRoutes.addEvent,
          extra: {
            'initialTitle': title,
            'initialDate': widget.selectedDate ?? DateTime.now(),
          },
        );
      case 'todo':
        result = await context.push<bool>(
          AppRoutes.addTodo,
          extra: {'initialTitle': title},
        );
      case 'habit':
        result = await context.push<bool>(
          AppRoutes.addHabit,
          extra: {'initialTitle': title},
        );
    }

    if (!mounted) return;
    if (result != true) return;

    // ユーザーがアイテムを作成した → convert API 呼び出し (メモ削除 + EXP 付与)
    //
    // 【2026-07-25 gameplay-review 20260725 §2-2 対応】旧実装は追加ページ側の
    // 「ToDoを追加しました ✨」SnackBar (2 秒) の後にキューイングされて 2 秒遅れて
    // 「変換しました +3 EXP 🪶」が表示されていた。ゲームフィールの原則
    // (報酬フィードバックは 200ms 以内) から見て「決意した瞬間の報酬」が届かず、
    // FEAT-493 Pre-mortem「メモ = 決意しない」への予防策 (+3 EXP) が体感として
    // 機能していなかった。対応:
    //   1. hideCurrentSnackBar() で追加ページ側トーストを畳んで即時表示に
    //   2. 種別ラベルを埋め込んで「〜 に決めました +N EXP 🪶」1 本に統合
    //   3. mediumImpact 追加 (destructive でない「決意」に触覚報酬)
    final typeLabels = {
      'event': l10n.freeMemoPageEmptyFlowLeafEvent,
      'todo':  l10n.freeMemoPageEmptyFlowLeafTodo,
      'habit': l10n.freeMemoPageEmptyFlowLeafHabit,
    };
    try {
      final daysSince = DateTime.now().difference(memo.createdAt).inDays;
      final expGain = await ref
          .read(freeMemoNotifierProvider.notifier)
          .convertMemo(memo.id, type, daysSinceCreated: daysSince);
      if (!mounted) return;
      HapticFeedback.mediumImpact();
      final label = typeLabels[type] ?? l10n.freeMemoPageSwipeConvertLabel;
      // 【FEAT-498 §2.3 (2026-07-31)】旧 SnackBar 「$label に決めました +N EXP 🪶」
      // → RewardToastOverlay (intensity: subtle) に置換。習慣完了 / かけら獲得と
      // 同じ overlay レイヤーで表示することで「Sabiowl の EXP 語彙」を統一。
      // subtle 経路 = primary tint + brief scale-up、gold の報酬インフレを避ける。
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      _showConvertRewardOverlay(label, expGain);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(AppLocalizations.of(context)!.freeMemoPageConvertErrorSnack),
            behavior: SnackBarBehavior.floating,
          ),
        );
    }
  }

  Widget _buildConvertOption(
    BuildContext dialogContext,
    String emoji,
    String label,
    String type,
  ) {
    return ListTile(
      leading: Text(emoji, style: const TextStyle(fontSize: 20)),
      title: Text(label, style: const TextStyle(color: Colors.white, fontSize: 14)),
      onTap: () {
        HapticFeedback.selectionClick();
        Navigator.pop(dialogContext, type);
      },
    );
  }

  // ── メモ作成 ──────────────────────────────────────────────────────────────

  /// 【2026-07-25 codebase-functional-review 20260725 対応 (要素 A)】
  /// 楽観的作成: 入力欄を即クリア + provider に fire。provider 側で optimistic
  /// insert → API 確定 → 差し替え/ロールバック が行われる。失敗時のみ SnackBar +
  /// 入力欄に text を戻す。「思いついた瞬間の低摩擦キャプチャ」機能中核価値。
  Future<void> _createMemo() async {
    final l10n = AppLocalizations.of(context)!;
    final text = _inputCtrl.text.trim();
    if (text.isEmpty) return;
    HapticFeedback.lightImpact();
    _inputCtrl.clear();  // 楽観: API 往復を待たず即クリア (連続投稿即応)
    try {
      await ref
          .read(freeMemoNotifierProvider.notifier)
          .createMemo(text, entryPoint: widget.entryPoint);
    } catch (_) {
      if (!mounted) return;
      _inputCtrl.text = text;  // ロールバック: text 復帰でユーザーが再送信可能に
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.freeMemoPageSaveErrorSnack),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  void _onSearchChanged(String value) {
    _searchDebouncer?.cancel();
    _searchDebouncer = Timer(const Duration(milliseconds: 200), () {
      if (mounted) setState(() => _searchQuery = value.trim());
    });
  }

  // ── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      backgroundColor: AppTheme.surface,
      appBar: AppBar(
        backgroundColor: AppTheme.surface,
        elevation: 0,
        title: Text(
          l10n.freeMemoPageTitle,
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        iconTheme: const IconThemeData(color: Colors.white),
        // 【2026-07-25】タブ UI 廃止 (PM 判断)。旧「メモ / 予定 / ToDo / 習慣」
        // 4 タブは「タブ tap → button tap → add page」の 2 tap 経路が
        // 認知負荷になっていたため撤廃、メモ機能に集中させる。
        // 予定/ToDo/習慣 の直接追加はホーム画面の各 section 追加 button か
        // 左スワイプ変換 (メモ → 予定/ToDo/習慣) 経由で対応可能。
        // 【FEAT-500 (2026-07-26)】削除メモ一覧 (trash) へのアクセス icon。
        // ゴミ箱アイコンで「削除したメモの管理場所」を直感的に示す。
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: l10n.freeMemoPageTrashTooltip,
            onPressed: _openTrashSheet,
          ),
        ],
      ),
      body: _buildMemoBody(),
    );
  }

  /// 【FEAT-500 → FEAT-503 アクション6 (2026-07-26)】trash (削除メモ) Bottom Sheet を開く。
  /// 復元 / 完全削除の操作は sheet 内で完結。復元は restoreMemo が active 一覧を
  /// 再取得済 = 閉じる時の全画面 refresh (spinner) は不要なため撤去した
  /// (全画面 spinner 摩擦の解消、active 側の楽観更新設計と整合)。
  Future<void> _openTrashSheet() async {
    HapticFeedback.selectionClick();
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppTheme.surface,
      isScrollControlled: true,
      builder: (sheetContext) => const MemoTrashSheet(),
    );
  }

  // ── メモ本体 (旧 タブ廃止後のメイン body) ────────────────────────────────

  Widget _buildMemoBody() {
    final l10n = AppLocalizations.of(context)!;
    final state = ref.watch(freeMemoNotifierProvider);
    // 【FEAT-503 アクション8】200 件上限で backend が打ち切っているか。
    final hasMore = ref.watch(freeMemoHasMoreProvider);
    return Column(
      children: [
        Expanded(
          child: state.when(
            loading: () => const Center(
              child: CircularProgressIndicator(color: AppTheme.primary),
            ),
            error: (e, _) => Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    l10n.freeMemoLoadErrorSabi_message,
                    style: const TextStyle(color: Colors.white70),
                  ),
                  const SizedBox(height: 12),
                  TextButton(
                    onPressed: () =>
                        ref.read(freeMemoNotifierProvider.notifier).refresh(),
                    child: Text(l10n.freeMemoRetryButton),
                  ),
                ],
              ),
            ),
            data: (memos) {
              if (memos.isEmpty) return _buildEmptyState();
              // 【20260729 gameplay-review §3 要素 A-3 対応】メモが 5 件以下の
              // 使い始め期は検索窓を出さない (3 件しかない画面に「表示中の 3 件
              // から検索します」が常駐するのは情報過多、静かであってほしい)。
              // 6 件目以降で自動的に検索窓が現れる = user 発見体験も自然。
              final showSearchBox = memos.length > 5;
              return Column(
                children: [
                  if (showSearchBox)
                    _buildSearchBox(memoCount: memos.length, hasMore: hasMore),
                  Expanded(child: _buildMemoList(memos, hasMore)),
                ],
              );
            },
          ),
        ),
        _buildBottomInput(),
      ],
    );
  }

  Widget _buildSearchBox({required int memoCount, required bool hasMore}) {
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _searchCtrl,
            onChanged: _onSearchChanged,
            style: const TextStyle(color: Colors.white, fontSize: 13),
            decoration: InputDecoration(
              hintText: l10n.freeMemoPageSearchHint,
              hintStyle: TextStyle(
                color: Colors.white.withValues(alpha: 0.38),
                fontSize: 13,
              ),
              prefixIcon: Icon(
                Icons.search,
                size: 18,
                color: Colors.white.withValues(alpha: 0.38),
              ),
              filled: true,
              fillColor: Colors.white.withValues(alpha: 0.03),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(20),
                borderSide: BorderSide.none,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(20),
                borderSide: BorderSide.none,
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(20),
                borderSide: BorderSide(
                  color: AppTheme.primary.withValues(alpha: 0.4),
                ),
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 8,
              ),
              suffixIcon: _searchQuery.isNotEmpty
                  ? IconButton(
                      icon: Icon(
                        Icons.close,
                        size: 16,
                        color: Colors.white.withValues(alpha: 0.4),
                      ),
                      onPressed: () {
                        _searchCtrl.clear();
                        setState(() => _searchQuery = '');
                      },
                    )
                  : null,
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
            child: Text(
              hasMore
                  ? l10n.freeMemoPageSearchCountWithMore(memoCount)
                  : l10n.freeMemoPageSearchCount(memoCount),
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.28),
                fontSize: 10,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    final l10n = AppLocalizations.of(context)!;
    // 【2026-07-25 UX 改善】旧「notepad icon + 文言 2 行」の抽象的な空状態から、
    // GTD 型 Capture → Process 概念を可視化する flow 図に置換 (案 C 採用)。
    // 「思いつき → メモ → 3 分岐 (予定 / ToDo / 習慣)」の 4 ステップで、
    // user がスクリーンを見た瞬間に「あ、こういう使い方をするのね」と直感的に
    // 理解できることを狙う (Todoist / iOS Notes onboarding pattern 準拠)。
    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // ── Step 1: 💭 思いついた ─────────────────────────────
            SabiFlowBox(icon: '💭', label: l10n.freeMemoPageEmptyFlowStep1),
            const SabiFlowArrow(),
            // ── Step 2: 📝 メモに書く ─────────────────────────────
            SabiFlowBox(icon: '📝', label: l10n.freeMemoPageEmptyFlowStep2),
            // ── T 字分岐 (垂直 + 水平) ────────────────────────────
            const SizedBox(
              height: 32,
              child: CustomPaint(
                size: Size(240, 32),
                painter: SabiFlowBranchPainter(),
              ),
            ),
            // ── Step 3: 3 分岐 (予定 / ToDo / 習慣) ────────────────
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                SabiFlowLeaf(icon: '📅', label: l10n.freeMemoPageEmptyFlowLeafEvent),
                SabiFlowLeaf(icon: '✅', label: l10n.freeMemoPageEmptyFlowLeafTodo),
                SabiFlowLeaf(icon: '🌱', label: l10n.freeMemoPageEmptyFlowLeafHabit),
              ],
            ),
            const SizedBox(height: 32),
            // ── 説明文 (サビ口調) ──────────────────────────────────
            Text(
              l10n.freeMemoPageEmptyFlowCaption,
              style: const TextStyle(color: Colors.white70, fontSize: 14),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 6),
            Text(
              // 【2026-07-26 hotfix】旧「〜構いませんよ」は sabi_tone_test の
              // 「文末〜よ = 少年口調」ガードに該当 (CI 赤化)。「〜構いません」に
              // 短縮 (「〜ませんね」も候補だが微妙にニュアンスが違うため断定形へ)。
              l10n.freeMemoPageEmptyFlowSubcaption,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.5),
                fontSize: 12,
                height: 1.5,
              ),
              textAlign: TextAlign.center,
            ),
            // 【2026-07-25】メモ 0 件時 (= 機能を使っていない) のみ表示する OFF 案内。
            // default=ON 変更 (2026-07-25 hotfix) に伴う「気付いたけど使わない user
            // への出口」設計。メモを 1 件でも書いたら消える (使っている user には無用)。
            // サビ character の穏やか性: 「押し付けない、あなたの選択もどうぞ」の姿勢。
            const SizedBox(height: 32),
            Text(
              l10n.freeMemoPageDisableHint,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.4),
                fontSize: 12,
                height: 1.5,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 4),
            InkWell(
              onTap: () {
                HapticFeedback.selectionClick();
                // 【2026-07-25 hotfix】settings は ShellRoute 内、memo_page は
                // ShellRoute 外のため context.push だと GoRouter の route stack
                // と ShellRoute navigator の不整合で遷移が発火しない。
                // context.go に変更 (「機能 OFF にしたい」動線ではメモ画面を
                // 出るのが自然、戻り先は home で問題なし)。
                context.go(AppRoutes.settings);
              },
              borderRadius: BorderRadius.circular(6),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.settings_outlined,
                      size: 14,
                      color: AppTheme.primary.withValues(alpha: 0.85),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      l10n.freeMemoPageSettingsLink,
                      style: TextStyle(
                        color: AppTheme.primary.withValues(alpha: 0.85),
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMemoList(List<FreeMemo> memos, bool hasMore) {
    final filtered = _searchQuery.isEmpty
        ? memos
        : memos
            .where((m) =>
                m.text.toLowerCase().contains(_searchQuery.toLowerCase()))
            .toList();

    if (filtered.isEmpty && _searchQuery.isNotEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            AppLocalizations.of(context)!.freeMemoPageEmptySearchSabi_message,
            style: const TextStyle(color: Colors.white54, fontSize: 13),
          ),
        ),
      );
    }

    // 【FEAT-498 §2.4 (2026-07-31)】サビ月 1 回穏やか促し banner を index 0 に挿入。
    // 表示 flag が true の月のみ +1 個の item を追加、swipe hint / memos の index は
    // banner offset を考慮して計算する。
    final promptOffset = _showMonthlyPrompt ? 1 : 0;
    return RefreshIndicator(
      color: AppTheme.primary,
      onRefresh: () =>
          ref.read(freeMemoNotifierProvider.notifier).refresh(),
      child: ListView.builder(
        padding: const EdgeInsets.only(top: 4, bottom: 8),
        itemCount: filtered.length + 1 + promptOffset + (hasMore ? 1 : 0),
        itemBuilder: (context, index) {
          if (_showMonthlyPrompt && index == 0) {
            return _buildMonthlyPromptBanner();
          }
          if (index == promptOffset) {
            return _buildSwipeHint();
          }
          if (hasMore && index == filtered.length + 1 + promptOffset) {
            return _buildOlderMemosNotice();
          }
          final memo = filtered[index - 1 - promptOffset];
          return _buildDismissibleMemo(memo);
        },
      ),
    );
  }

  /// 【FEAT-498 §2.4 (2026-07-31)】サビ月 1 回穏やか促し banner (常設 1 行、passive)。
  ///
  /// SnackBar 廃止 → メモ画面上部の静的 1 行に配置換え。dismiss button なし、
  /// 「そこにいる存在」として user のペース尊重。表示位置は swipe hint の直上。
  Widget _buildMonthlyPromptBanner() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: AppTheme.primary.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: AppTheme.primary.withValues(alpha: 0.25),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('🪶', style: TextStyle(fontSize: 14)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                AppLocalizations.of(context)!.freeMemoPageMonthlyPromptSabi_message,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.78),
                  fontSize: 12,
                  height: 1.4,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 【FEAT-503 アクション8 (2026-07-26)】200 件上限で古いメモが表示から外れている
  /// ことの静かな告知。load-more button は追加しない (active では 200 件超は稀、
  /// backend の「無限肥大 → 明示的打切り」意図をクライアントに通すのが目的)。
  Widget _buildOlderMemosNotice() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Center(
        child: Text(
          AppLocalizations.of(context)!.freeMemoPageOlderMemosNotice,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.4),
            fontSize: 12,
          ),
        ),
      ),
    );
  }

  /// 【2026-07-25】スワイプ操作 hint。メモ一覧最上部に常時表示。
  Widget _buildSwipeHint() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.swipe_outlined,
              size: 14, color: Colors.white.withValues(alpha: 0.4)),
          const SizedBox(width: 6),
          Text(
            AppLocalizations.of(context)!.freeMemoPageSwipeHint,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.5),
              fontSize: 11,
              height: 1.3,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDismissibleMemo(FreeMemo memo) {
    return Dismissible(
      key: Key('memo_${memo.id}'),
      direction: DismissDirection.horizontal,
      // 【2026-07-25】背景に「ゴミ箱」「登録」テキスト表示 + 習慣パターン準拠。
      // habit_card.dart の swipe 方向 (右=アーカイブ/登録 系 positive, 左=削除)
      // に統一。app 内の swipe 方向 mental model を一貫させて誤操作リスクを軽減。
      // 色配置も習慣と同じ (positive action=紫、destructive=赤)。
      //
      // 右スワイプ (startToEnd) = 変換 (登録、positive action、紫)
      background: Builder(
        builder: (ctx) {
          final l10n = AppLocalizations.of(ctx)!;
          return Container(
            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            padding: const EdgeInsets.symmetric(horizontal: 20),
            decoration: BoxDecoration(
              color: AppTheme.primary.withValues(alpha: 0.85),
              borderRadius: BorderRadius.circular(10),
            ),
            alignment: Alignment.centerLeft,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.swap_horiz, color: Colors.white, size: 24),
                const SizedBox(width: 8),
                Text(
                  l10n.freeMemoPageSwipeConvertLabel,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          );
        },
      ),
      // 左スワイプ (endToStart) = 削除 (destructive、赤、habit の「ゴミ箱」と同色)
      secondaryBackground: Builder(
        builder: (ctx) {
          final l10n = AppLocalizations.of(ctx)!;
          return Container(
            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            padding: const EdgeInsets.symmetric(horizontal: 20),
            decoration: BoxDecoration(
              color: Colors.red.shade700,
              borderRadius: BorderRadius.circular(10),
            ),
            alignment: Alignment.centerRight,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  l10n.freeMemoPageSwipeDeleteLabel,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(width: 8),
                const Icon(Icons.delete_outline, color: Colors.white, size: 24),
              ],
            ),
          );
        },
      ),
      confirmDismiss: (direction) async {
        if (direction == DismissDirection.endToStart) {
          // 【2026-07-25】左スワイプ = 削除: 誤操作防止のため確認ダイアログを表示
          // (habit_card.dart:110- の 「ゴミ箱に移しますか?」ダイアログと同形式)。
          // 習慣と同じ方向 (左=削除) に統一。
          //
          // BUG-138 準拠: Cancel 左 (「やめる」)、Action 右 (「削除する」赤色)。
          // dialogContext で Navigator.pop する (FEAT-215 ShellRoute 配下対策)。
          //
          // 【2026-07-25 update】旧「削除後 2 秒間は取り消しできますよ 🪶」文言は
          // undo 機能撤去に伴い削除 (user 報告「戻せない状態で誤解を招く」)。
          final l10n = AppLocalizations.of(context)!;
          final preview = memo.text.length > 30
              ? '${memo.text.substring(0, 30)}…'
              : memo.text;
          final confirmed = await showDialog<bool>(
            context: context,
            builder: (dialogContext) => AlertDialog(
              backgroundColor: AppTheme.surface,
              title: Text(l10n.freeMemoPageDeleteConfirmTitle,
                  style: const TextStyle(color: Colors.white)),
              content: Text(
                l10n.freeMemoPageDeleteConfirmBody(preview),
                style: const TextStyle(color: Colors.white70),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: Text(l10n.freeMemoDialogCancelAction),
                ),
                TextButton(
                  style: TextButton.styleFrom(foregroundColor: Colors.red),
                  onPressed: () => Navigator.pop(dialogContext, true),
                  child: Text(l10n.freeMemoPageDeleteAction),
                ),
              ],
            ),
          );
          return confirmed == true;
        } else {
          // 右スワイプ = 変換 (登録): dismiss させない、ダイアログを表示
          await _handleSwipeConvert(memo);
          return false;
        }
      },
      onDismissed: (direction) {
        // 左スワイプ (削除) のみ到達する。_handleSwipeDelete は async
        // (削除失敗の SnackBar 通知を含む) だが dismiss 完了後の fire-and-forget。
        unawaited(_handleSwipeDelete(memo));
      },
      child: _buildMemoCard(memo),
    );
  }

  Widget _buildMemoCard(FreeMemo memo) {
    final date = memo.createdAt.toLocal();
    final dateStr = '${date.month}/${date.day} '
        '${date.hour.toString().padLeft(2, '0')}:'
        '${date.minute.toString().padLeft(2, '0')}';
    // 【2026-07-25】カードタップで編集モーダル起動 (アイコンなし tap 方式)。
    // 業界標準 (Apple Notes / Todoist / Things) の pattern。
    // swipe (左=削除、右=変換) との operation model 整合:
    //   tap=編集、swipe=削除/変換
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: AppTheme.card,
        borderRadius: BorderRadius.circular(10),
      ),
      // Material + InkWell で ripple 表示 + タップ検出。
      // Container の decoration を保持したまま tap 可能に。
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => _showEditModal(memo),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                HighlightedText(
                  content: memo.text,
                  query: _searchQuery,
                  style: const TextStyle(color: Colors.white, fontSize: 14, height: 1.45),
                ),
                const SizedBox(height: 6),
                Text(
                  dateStr,
                  style: const TextStyle(color: Colors.white38, fontSize: 11),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 【2026-07-25】メモ編集モーダル起動 (Full screen bottom sheet)。
  /// TextField に現 text を pre-fill、autofocus、multi-line、500 字上限。
  Future<void> _showEditModal(FreeMemo memo) async {
    HapticFeedback.selectionClick();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: AppTheme.surface,
      builder: (sheetContext) => MemoEditSheet(
        memo: memo,
        onSave: (newText) async {
          final l10n = AppLocalizations.of(context)!;
          try {
            await ref
                .read(freeMemoNotifierProvider.notifier)
                .updateMemo(memo.id, newText);
            if (!sheetContext.mounted) return;
            Navigator.pop(sheetContext);
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(l10n.freeMemoPageSaveSuccessSnack),
                behavior: SnackBarBehavior.floating,
                duration: const Duration(seconds: 2),
              ),
            );
          } catch (_) {
            if (!sheetContext.mounted) return;
            ScaffoldMessenger.of(sheetContext).showSnackBar(
              SnackBar(
                content: Text(l10n.freeMemoPageSaveErrorSnack),
                behavior: SnackBarBehavior.floating,
              ),
            );
          }
        },
      ),
    );
  }

  // ── 音声入力コントロール (FEAT-499) ──────────────────────────────────────

  Future<void> _startVoiceInput() async {
    final l10n = AppLocalizations.of(context)!;
    final available = await VoiceInputService.instance.initialize();
    if (!mounted) return;

    if (!available) {
      // BUG-65: dialogContext 経由で Navigator.pop
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          backgroundColor: AppTheme.card,
          title: Text(
            l10n.freeMemoPageVoicePermissionTitle,
            style: const TextStyle(color: Colors.white, fontSize: 16),
          ),
          content: Text(
            l10n.freeMemoPageVoicePermissionBody,
            style: const TextStyle(color: Colors.white70, fontSize: 13, height: 1.6),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(
                l10n.commonClose,
                style: const TextStyle(color: Colors.white54),
              ),
            ),
            TextButton(
              onPressed: () {
                Navigator.pop(dialogContext);
                openAppSettings(); // permission_handler: iOS 設定アプリのこのアプリのページへ
              },
              child: Text(
                l10n.freeMemoPageOpenSettings,
                style: const TextStyle(
                  color: AppTheme.primary,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
      );
      return;
    }

    // 【FEAT-499 v1.0 増分 (Gemini §2 対応)】録音開始 haptic (「押した」の即時 feedback)
    HapticFeedback.lightImpact();

    // 【FEAT-501 C】partial/soundLevel は ValueNotifier のため setState 外で reset。
    _voicePartial.value = '';
    _voiceSoundLevel.value = 0.0;
    setState(() {
      _voiceState = _VoiceState.listening;
      _voiceElapsed = Duration.zero;
    });
    _waveAnimCtrl.repeat();
    // 【FEAT-499 v1.0 増分 (Gemini §8 対応)】経過時間 Timer (1 秒周期)
    _voiceTimer?.cancel();
    _voiceTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _voiceElapsed += const Duration(seconds: 1));
    });
    unawaited(PosthogService.instance.capture('voice_input_started'));

    try {
      // 【FEAT-499 v1.0 増分 (Gemini §6/§9 対応)】onPartial callback で中間認識
      // テキストを逐次 UI 反映 (ChatGPT 型リアルタイム表示)
      // 【FEAT-499 v1.0 増分 追加 (2026-07-26)】onSoundLevel callback で
      // dB 連動波形 UI (話すと bar が大きく揺れる)。ChatGPT UX の本質 gain
      // (「話している実感」) を取得しつつ、形状・配色は現行維持で商標
      // リスクゼロ + Sabi character 保持 (§3.2 minimal 準拠)。
      final result = await VoiceInputService.instance.listen(
        onPartial: (partial) {
          if (!mounted) return;
          // 【FEAT-501 C】setState ではなく ValueNotifier 更新 =
          // ValueListenableBuilder (partial 表示部) のみ rebuild。
          _voicePartial.value = partial;
        },
        onSoundLevel: (level) {
          if (!mounted) return;
          // Apple Speech: -2〜10 (dB)、Android: 端末依存 0〜10 程度。
          // 0.0〜1.0 に正規化 + 指数移動平均 (EMA α=0.3) で急変 smoothing。
          // 【FEAT-501 C】10〜20 回/秒発火するため rebuild を波形部に閉じ込める。
          final normalized = (level / 10.0).clamp(0.0, 1.0);
          _voiceSoundLevel.value = _voiceSoundLevel.value * 0.7 + normalized * 0.3;
        },
      );
      if (!mounted) return;

      if (result.isNotEmpty) {
        _appendVoiceResult(result);
        unawaited(PosthogService.instance.capture(
          'voice_input_completed',
          properties: {
            'text_length': result.length,
            'duration_sec': _voiceElapsed.inSeconds,
          },
        ));
      } else {
        // 起動失敗 / STT エラー / 無音停止 をエラー種別で分岐。
        // lastError == null はユーザーが停止ボタンを押した場合 → SnackBar 不要。
        final err = VoiceInputService.instance.lastError;
        if (err != null) {
          final isStartupFailure = err == 'initialization_failed' ||
              err == 'listen_not_started' ||
              err == 'listen_exception';
          if (!mounted) return;
          final snackL10n = AppLocalizations.of(context)!;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                isStartupFailure
                    ? snackL10n.freeMemoPageVoiceStartupErrorSnack
                    : snackL10n.freeMemoPageVoiceRecognitionErrorSnack,
              ),
              behavior: SnackBarBehavior.floating,
              duration: Duration(seconds: isStartupFailure ? 4 : 3),
              // 【FEAT-499 v1.0 増分 (Gemini §10 対応)】再試行 action button
              // (startup failure は端末設定問題のため再試行不要、認識失敗のみ表示)
              action: isStartupFailure
                  ? null
                  : SnackBarAction(
                      label: snackL10n.freeMemoPageVoiceRetryAction,
                      textColor: AppTheme.primary,
                      onPressed: _startVoiceInput,
                    ),
            ),
          );
          unawaited(PosthogService.instance.capture('voice_input_error',
              properties: {'error_code': err}));
        }
      }
    } catch (_) {
      if (!mounted) return;
      final catchL10n = AppLocalizations.of(context)!;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(catchL10n.freeMemoPageVoiceGenericErrorSnack),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 3),
          action: SnackBarAction(
            label: catchL10n.freeMemoPageVoiceRetryAction,
            textColor: AppTheme.primary,
            onPressed: _startVoiceInput,
          ),
        ),
      );
      unawaited(PosthogService.instance.capture('voice_input_error'));
    } finally {
      _waveAnimCtrl.stop();
      _voiceTimer?.cancel();
      _voiceTimer = null;
      if (mounted) {
        // 【FEAT-501 C】partial/soundLevel は ValueNotifier のため setState 外で reset。
        _voicePartial.value = '';
        _voiceSoundLevel.value = 0.0;
        setState(() {
          _voiceState = _VoiceState.idle;
          _voiceElapsed = Duration.zero;
        });
      }
    }
  }

  void _stopVoiceInput() {
    _waveAnimCtrl.stop();
    _voiceTimer?.cancel();
    _voiceTimer = null;
    VoiceInputService.instance.stop();
    if (mounted) setState(() => _voiceState = _VoiceState.processing);
  }

  void _cancelVoiceInput() {
    _waveAnimCtrl.stop();
    _voiceTimer?.cancel();
    _voiceTimer = null;
    VoiceInputService.instance.cancel();
    // finally ブロックで _voiceState = idle + _voiceElapsed/_voicePartial reset
  }

  void _appendVoiceResult(String text) {
    final current = _inputCtrl.text;
    final newText = current.isEmpty ? text : '$current $text';
    _inputCtrl.value = _inputCtrl.value.copyWith(
      text: newText,
      selection: TextSelection.fromPosition(
        TextPosition(offset: newText.length),
      ),
    );
  }

  // ── 下部固定入力欄 (pill 型、音声入力対応) ───────────────────────────────
  //
  // [テキスト欄] [🎤/■ アイコン切替] [↑ 送信]
  // 音声 idle: mic_none 表示、タップで録音開始
  // 音声 listening/processing: stop_rounded 表示、タップで録音停止

  Widget _buildBottomInput() {
    return Container(
      color: AppTheme.surface,
      padding: EdgeInsets.fromLTRB(
        12,
        8,
        12,
        8 + MediaQuery.of(context).padding.bottom,
      ),
      child: _buildTextInputPill(),
    );
  }

  // テキスト入力 pill — 状態別 UI
  //
  // idle      : [text field] [🎤] [↑]
  // listening : [✕ cancel] [~~波形アニメーション~~] [■ stop] [↑]
  // processing: [⟳ spinner] [文字起こし中...] [■ dimmed] [↑]
  Widget _buildTextInputPill() {
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: _inputCtrl,
      builder: (_, value, __) {
        final hasText = value.text.trim().isNotEmpty;
        final isListening = _voiceState == _VoiceState.listening;
        final isProcessing = _voiceState == _VoiceState.processing;
        final isVoiceActive = isListening || isProcessing;

        // 送信ボタン（全状態共通）
        final sendBtn = Padding(
          padding: const EdgeInsets.only(right: 4),
          child: GestureDetector(
            onTap: hasText ? _createMemo : null,
            child: Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: hasText
                    ? AppTheme.primary
                    : AppTheme.primary.withValues(alpha: 0.3),
              ),
              child: const Icon(Icons.arrow_upward, color: Colors.white, size: 18),
            ),
          ),
        );

        return Container(
          decoration: BoxDecoration(
            color: AppTheme.card,
            borderRadius: BorderRadius.circular(24),
          ),
          // 音声モード時は左 padding を詰めて cancel/spinner を端に寄せる
          padding: EdgeInsets.fromLTRB(isVoiceActive ? 4 : 16, 4, 8, 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              if (isListening) ...[
                // ✕ キャンセル
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.white70, size: 20),
                  onPressed: _cancelVoiceInput,
                  padding: const EdgeInsets.all(6),
                  constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                ),
                // 【FEAT-499 v1.0 増分 (Gemini §6/§9 対応)】
                // partial text 有 → リアルタイム認識テキスト (grey で表示)
                // partial text 無 → 波形アニメーション (「話す前」の視覚 feedback、Sabi minimal)
                // 【FEAT-501 C】partial (ValueNotifier) 変化時はこの Builder のみ
                // rebuild。partial 空 → 波形 (音量 ValueNotifier で更に局所 rebuild)、
                // 非空 → partial text preview。ページ全体 setState を回避。
                Expanded(
                  child: SizedBox(
                    height: 28,
                    child: ValueListenableBuilder<String>(
                      valueListenable: _voicePartial,
                      builder: (_, partial, __) => partial.isEmpty
                          ? ValueListenableBuilder<double>(
                              valueListenable: _voiceSoundLevel,
                              builder: (_, level, __) => AnimatedBuilder(
                                animation: _waveAnimCtrl,
                                builder: (_, __) => CustomPaint(
                                  painter: MemoWaveformPainter(
                                    _waveAnimCtrl.value,
                                    level,
                                  ),
                                ),
                              ),
                            )
                          : Align(
                              alignment: Alignment.centerLeft,
                              child: Padding(
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 8),
                                child: Text(
                                  partial,
                                  style: const TextStyle(
                                    color: Colors.white70,
                                    fontSize: 13,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ),
                    ),
                  ),
                ),
                // 【FEAT-499 v1.0 増分 (Gemini §2/§8 対応)】経過時間 "0:15" 形式
                // 波形/partial の右端に控えめ表示 (tabularFigures で桁揺れ防止)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Text(
                    '${_voiceElapsed.inMinutes}:${(_voiceElapsed.inSeconds % 60).toString().padLeft(2, '0')}',
                    style: const TextStyle(
                      color: Colors.white54,
                      fontSize: 11,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                // ■ 停止
                IconButton(
                  icon: Icon(Icons.stop_rounded, color: Colors.red.shade400, size: 22),
                  onPressed: _stopVoiceInput,
                  padding: const EdgeInsets.all(6),
                  constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                ),
                sendBtn,
              ] else if (isProcessing) ...[
                // スピナー
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 10),
                  child: SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white54,
                    ),
                  ),
                ),
                // 「文字起こし中...」
                Expanded(
                  child: Text(
                    AppLocalizations.of(context)!.freeMemoPageVoiceTranscribingLabel,
                    style: const TextStyle(color: Colors.white54, fontSize: 14),
                  ),
                ),
                // ■ 停止（無効化: 文字起こし処理中はユーザー操作不可）
                IconButton(
                  icon: Icon(Icons.stop_rounded, color: Colors.red.shade200, size: 22),
                  onPressed: null,
                  padding: const EdgeInsets.all(6),
                  constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                ),
                sendBtn,
              ] else ...[
                // テキスト入力欄
                Expanded(
                  child: TextField(
                    controller: _inputCtrl,
                    minLines: 1,
                    maxLines: 6,
                    maxLength: 500,
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                    decoration: const InputDecoration(
                      // filled + transparent で Material サーフェス色を消去（親 Container と同色に）
                      filled: true,
                      fillColor: Colors.transparent,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      counterText: '',
                      contentPadding: EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                    ),
                    onSubmitted: (_) => _createMemo(),
                  ),
                ),
                // 🎤 マイク
                IconButton(
                  icon: Icon(Icons.mic_none,
                      color: AppTheme.primary.withValues(alpha: 0.7), size: 22),
                  onPressed: _startVoiceInput,
                  padding: const EdgeInsets.all(6),
                  constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                ),
                sendBtn,
              ],
            ],
          ),
        );
      },
    );
  }

  // 【2026-07-25】旧 _buildAddTab メソッドは タブ廃止に伴い削除。
  // 予定/ToDo/習慣 の追加はホーム画面 section button または左スワイプ変換経由。
}
