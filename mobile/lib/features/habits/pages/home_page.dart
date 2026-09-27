import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/providers/time_segment_provider.dart';
import '../../../core/router/app_router.dart';
import '../../../core/services/toast_center.dart';  // 【gameplay_review 20260803 §2-2 d】
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/time_segment_theme.dart';
import '../../../l10n/app_localizations.dart';
import '../../calendar/providers/calendar_provider.dart';
import '../../social/providers/social_provider.dart';
import '../../../shared/widgets/bouncy_fab.dart';
import '../../battle/constants/battle_constants.dart';  // 【FEAT-513 v1.1 hotfix】chargesPerBattle
import '../../battle/dialogs/ambient_battle_defeat_dialog.dart';  // 【FEAT-513】
import '../../battle/providers/battle_provider.dart';  // 【FEAT-513 v1.1 hotfix】battleAvailabilityProvider
import '../../battle/services/ambient_auto_battle_orchestrator.dart';  // 【FEAT-513】
import '../../timeline/providers/timeline_provider.dart';  // FEAT-143 hotfix (2026-07-07)
import '../providers/habits_provider.dart';
import '../providers/home_bootstrap_provider.dart';
import '../widgets/home_drawer.dart';
import 'home_body.dart';
import 'home_listeners.dart';

class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  // ── ステータス枠の開閉状態 ──────────────────────────────────────────────
  bool _statusFrameOpen = false;

  // 【2026-06-27】サビセリフパネルの開閉状態（AppBar 左上アイコンでトグル）
  bool _sabiPanelOpen = false;

  /// 今日の日付を表示ラベルとして返す（例: 5月3日（土） / Sat, 5/3）
  String _todayLabel(AppLocalizations l10n) {
    final now = DateTime.now();
    final weekdays = [
      l10n.habitLoginBonusDayMon,
      l10n.habitLoginBonusDayTue,
      l10n.habitLoginBonusDayWed,
      l10n.habitLoginBonusDayThu,
      l10n.habitLoginBonusDayFri,
      l10n.habitLoginBonusDaySat,
      l10n.habitLoginBonusDaySun,
    ];
    return l10n.habitHomeDateLabel(now.month, now.day, weekdays[now.weekday - 1]);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // 初回フレーム後: feat426 移行案内を確認する。
    // 通知プロンプト・初回体験フラグは HomeListeners (home_listeners.dart) が担当。
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;

      // 【FEAT-143 hotfix (2026-07-07)】デフォルト予定 (timeline template) を
      // ホーム初回訪問時にも自動作成する。
      //
      // 旧: timelineAutoCreateProvider は TimelinePage を開いた時のみ発火 →
      //     ユーザーが夕方に初回起動して home だけ見ていた場合、当日中の
      //     デフォルト予定が作成されない = 「サビ時刻を通知したのに予定が
      //     並んでいない」体感の原因。
      // 新: home 初回訪問でも auto-create を発火。冪等性は provider 内の
      //     `createdIds` (SharedPreferences 日次キー) で保護されるため、
      //     timeline_page.dart:75 と重複しても POST は 1 回のみ。
      // offline 時は FEAT-370 で early return されるため safe。
      // 失敗は home 遷移を止めない (catchError で吞み込み)。
      _triggerTimelineAutoCreateForToday();

      // 【FEAT-513】ホーム初回訪問時にオートバトルを試行する。
      // fire-and-forget: 前提条件 (ON/charges/preset) を内部で確認するため常に呼んで安全。
      _maybeStartAutoBattle();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// バックグラウンドから復帰時に TimeSegment を更新
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      ref.read(timeSegmentProvider.notifier).refresh();
      // 【FEAT-372 (2026-05-28)】BUG-74 defense-in-depth: gcal_push_enabled を渡して
      // retryPendingPushes 側で OFF ユーザーの push を遮断させる。
      final gcalEnabled =
          ref.read(playerNotifierProvider).valueOrNull?.gcalPushEnabled ?? true;
      ref
          .read(googleCalendarSyncServiceProvider)
          .retryPendingPushes(gcalPushEnabled: gcalEnabled);

      // 【FEAT-143 hotfix (2026-07-07)】日付跨ぎ resume 対応: バックグラウンド
      // 中に日付が変わっていた場合、当日のデフォルト予定を自動作成する。
      // 冪等性は provider 内の `createdIds` (SharedPreferences 日次キー) で
      // 保護されるため、同日 resume では POST は走らない (no-op)。
      _triggerTimelineAutoCreateForToday();

      // 【FEAT-513】バックグラウンドから復帰時にオートバトルを試行する。
      _maybeStartAutoBattle();
    }
  }

  /// 【FEAT-143 hotfix (2026-07-07)】当日のデフォルト予定を fire-and-forget で
  /// 自動作成する。失敗しても home 遷移や lifecycle 処理を止めない。
  ///
  /// 冪等性: timeline_provider の `createdIds` (SharedPreferences per-date) で
  /// 二重作成が構造的に防がれるため、複数経路 (home initState / resume /
  /// timeline_page initState) から呼ばれても安全。
  ///
  /// 呼出タイミング:
  /// - HomePage の initState (毎回のアプリ起動、ホーム初回訪問)
  /// - didChangeAppLifecycleState.resumed (日付跨ぎ復帰対応)
  ///
  /// 【FEAT-370 (2026-05-28)】offline 時は provider 内部で早期 return される
  /// ため、network なし環境でも safe (POST は online 復帰時に自動 retry)。
  void _triggerTimelineAutoCreateForToday() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    ref.read(timelineAutoCreateProvider(today).future).catchError((_) {});
  }

  /// 【FEAT-513】オートバトルを fire-and-forget で試行する。
  void _maybeStartAutoBattle() {
    ref.read(ambientAutoBattleProvider.notifier).maybeStartAutoBattle();
  }

  /// 【FEAT-513】敗北 dialog 表示。BUG-65 準拠 (300ms delay + mounted チェック)。
  ///
  /// 🔴 【BUG-148 (2026-08-24)】ボタンは「閉じる」1 つで、**ここから
  /// オートバトルを再開しない**。回数が残っていれば次にホームへ来たときに
  /// 自然に再開する。旧「続ける」は同じ敵に戻ってまた負けるだけだった
  /// (理由は `AmbientBattleDefeatDialog` の doc コメント)。
  Future<void> _showAmbientDefeatDialog(
    String enemyName,
    int remainingBattles,
  ) async {
    await Future.delayed(const Duration(milliseconds: 300));
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AmbientBattleDefeatDialog(
        enemyName: enemyName,
        remainingBattles: remainingBattles,
        onClose: () => Navigator.of(dialogContext).pop(),
      ),
    );
  }

  /// 【gameplay_review 20260803 §2-2 d / 要素 C-4】ambient queue 1 run 分の戦果を
  /// サビ口調トーストで 1 回だけ通知する。
  ///
  /// preset を撃ち切って終わった場合のみ「次の相手を選んでくださいね」を添える
  /// (旧実装は無言で停止していたため「設定したのに動かなくなった」と読めた)。
  void _showAmbientSummaryToast(AmbientBattleSummary summary) {
    if (!mounted) return;
    final l10n = AppLocalizations.of(context)!;
    final buf = StringBuffer(
      l10n.battleAmbientSummaryToastSabi_message(
        summary.wins,
        summary.coins,
        summary.exp,
      ),
    );
    // 【FEAT-523 Phase 1】特別報酬をこの 1 通に畳んで消化する。
    //
    // per-battle では `isRunning` guard (c585e012) で抑止されているので、
    // **ここが ambient 経路で武器 / 初勝利ダイヤ / Max に触れる唯一の場所**。
    // guard を外したり条件付きにしたりしてはいけない (連戦中に
    // barrierDismissible: false のモーダルが次戦に覆いかぶさる問題に戻る)。
    //
    // 個別に 3 つ出さないのは ambient の思想が「ながら見」だから (§1.4)。
    // 戦果報告は 1 回で完結させる。
    //
    // 【Pre-mortem #1】`queueExhausted` を見ない。中断 run でも獲得済み。
    if (summary.weaponNames.isNotEmpty) {
      buf.write('\n');
      buf.write(l10n.battleAmbientSummaryWeaponSabi_message(
        summary.weaponNames.length,
        summary.weaponNames.join('、'),
      ));
    }
    if (summary.firstDiamond) {
      buf.write('\n');
      buf.write(l10n.battleAmbientSummaryFirstDiamondSabi_message);
    }
    if (summary.maxedJobs.isNotEmpty) {
      buf.write('\n');
      buf.write(l10n.battleAmbientSummaryMaxedJobSabi_message(
        summary.maxedJobs.length,
        summary.maxedJobs.join('、'),
      ));
    }
    if (summary.queueExhausted) {
      buf.write('\n');
      buf.write(l10n.battleAmbientQueueFinishedToastSabi_message);
    }
    ToastCenter.showSuccess(buf.toString());
  }

  /// 【FEAT-513】プリセット未設定 SnackBar。
  void _showAmbientEmptyPresetSnackBar() {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          AppLocalizations.of(context)!.habitHomeAmbientEmptyPresetSabi_message,
        ),
        duration: const Duration(seconds: 4),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // P0-1: ホームブートストラップ結線
    ref.watch(homeBootstrapControllerProvider);
    // 【FEAT-530】「ホームが今ここに居る」ことを autoDispose の element 1 つで表す。
    // 値は使わない —— バトル終了時の再取得分岐が `ref.exists` で見るためだけの標識。
    ref.watch(homeIsLiveProvider);

    // 【FEAT-513】Ambient Auto Battle の UI シグナルを受信して dialog / SnackBar を表示。
    ref.listen<AmbientBattleState>(ambientAutoBattleProvider, (_, next) {
      final defeatName = next.defeatEnemyName;
      final summary = next.summary;
      if (defeatName == null && summary == null && !next.showEmptyPresetSnackBar) {
        return;
      }
      // clearUiSignals() は空 state を publish して本 listener を再入させるが、
      // 上の early return で無害に抜ける。
      ref.read(ambientAutoBattleProvider.notifier).clearUiSignals();

      // 【gameplay_review 20260803 §2-2 d】per-battle モーダルを抑止した代わりに、
      // run 全体の戦果をここで 1 回だけ届ける。
      if (summary != null) _showAmbientSummaryToast(summary);

      if (defeatName != null) {
        // 【BUG-148】queue 全体の `remainingBattles` ではなく、
        // **この敵の**残り回数 (`defeatRemainingBattles`) を渡す。
        _showAmbientDefeatDialog(defeatName, next.defeatRemainingBattles);
      } else if (next.showEmptyPresetSnackBar) {
        _showAmbientEmptyPresetSnackBar();
      }
    });

    // 【FEAT-513 v1.1 hotfix 2026-07-31】task 達成による charges 増加を検知して
    // auto battle trigger する。閾値 (chargesPerBattle=3) を「跨いだ」edge trigger:
    // 例えば charges: 2 → 3 の変化で発火、3 → 4 → 5 では発火しない (二重発火防止)。
    // 修正前: home 到達 initState + app resume の 2 経路しか無かったため、
    // home 画面に居続けたまま task を積んでも auto battle が始まらない bug (user 報告 2026-07-31)。
    ref.listen<int>(
      battleAvailabilityProvider.select((a) => a.charges),
      (prev, next) {
        final threshold = BattleConstants.chargesPerBattle;
        if ((prev ?? 0) < threshold && next >= threshold) {
          _maybeStartAutoBattle();
        }
      },
    );

    final timeSegment = ref.watch(timeSegmentProvider);
    final segTheme = TimeSegmentTheme.of(timeSegment);
    // 【FEAT-493】opt-in ON 時は FAB を 📝 アイコン + /memos 遷移に切替
    final freeMemoEnabled =
        ref.watch(playerNotifierProvider).valueOrNull?.freeMemoEnabled ?? false;

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: segTheme.appBarColor,
        // 【2026-06-27】左上にサビシルエットアイコン。タップで sabiPanelOpen をトグル。
        leading: IconButton(
          icon: Stack(
            clipBehavior: Clip.none,
            children: [
              ClipOval(
                child: Image.asset(
                  'assets/images/sabi/sabi_silhouette.webp',
                  width: 32,
                  height: 32,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => const Icon(
                    Icons.pets,
                    color: Colors.white70,
                    size: 22,
                  ),
                ),
              ),
              Positioned(
                right: -2,
                bottom: -2,
                child: Container(
                  width: 14,
                  height: 14,
                  decoration: BoxDecoration(
                    color: AppTheme.primary,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 1.2),
                  ),
                  alignment: Alignment.center,
                  child: const Icon(
                    Icons.chat_bubble,
                    size: 7,
                    color: Colors.white,
                  ),
                ),
              ),
            ],
          ),
          tooltip: l10n.habitHomeSabiTooltip,
          onPressed: () =>
              setState(() => _sabiPanelOpen = !_sabiPanelOpen),
        ),
        title: Text(
          _todayLabel(l10n),
          style: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.3,
          ),
        ),
        actions: [
          // 人型アイコン（ステータス枠トグル）
          // 枠が開いているとき: 塗りつぶしアイコン + primary 色でアクティブを示す
          IconButton(
            icon: Icon(
              _statusFrameOpen ? Icons.person : Icons.person_outlined,
              color: _statusFrameOpen ? AppTheme.primary : null,
            ),
            tooltip: l10n.habitHomeStatusTooltip,
            onPressed: () {
              setState(() => _statusFrameOpen = !_statusFrameOpen);
            },
          ),
          // 【FEAT-464 (2026-06-23)】ハンバーガーに未読バッジを統合
          Consumer(
            builder: (_, ref, __) {
              final unread = ref.watch(unreadNotifCountProvider);
              return Badge.count(
                count: unread,
                isLabelVisible: unread > 0,
                textStyle: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  height: 1.0,
                ),
                largeSize: 18,
                padding: const EdgeInsets.symmetric(horizontal: 5),
                child: Builder(
                  builder: (ctx) => IconButton(
                    icon: const Icon(Icons.menu),
                    tooltip: l10n.habitHomeMenuTooltip,
                    onPressed: () => Scaffold.of(ctx).openEndDrawer(),
                  ),
                ),
              );
            },
          ),
          // 【BUG-87】Badge が右端で見切れないよう 8px 右マージン
          const SizedBox(width: 8),
        ],
      ),
      // 【FEAT-464 (2026-06-23)】右からスライドするドロワー
      endDrawer: const HomeDrawer(),
      // 【2026-06-28】BouncyFab: 押下時 0.95 縮小 + easeOutBack 復帰 + 紫リップル
      // 【FEAT-493 (2026-07-25) / 2026-07-26 更新】仮メモ kill-switch 分岐:
      //   ON (default、実質全 user): Icons.edit_note + /memos 遷移 (Home Quick Capture)
      //   OFF (user が Settings で明示 OFF、稀): Icons.add + /calendar/add 遷移
      // ※ migration 0186 で default True 化 + 既存 backfill 済のため、OFF 分岐は
      // 実質到達しにくい (Settings で明示 OFF にした user のみ)。dead code ではないが
      // 主経路は ON 側と理解すること。習慣追加は本 FAB とは別経路 (habit_filter_bar.dart:98
      // 常設「+ 追加」ピル + home_body.dart 0 件時「最初の習慣を始める」button) で提供。
      floatingActionButton: Padding(
        padding: const EdgeInsets.only(bottom: 48),
        child: BouncyFab(
          onPressed: () {
            if (freeMemoEnabled) {
              context.push(AppRoutes.memos, extra: {'entryPoint': 'home_fab'});
            } else {
              context.push(AppRoutes.calendarAdd, extra: DateTime.now());
            }
          },
          tooltip: freeMemoEnabled ? l10n.habitHomeFabMemoTooltip : l10n.habitHomeFabAddTooltip,
          child: Icon(
            freeMemoEnabled ? Icons.edit_note : Icons.add,
            color: Colors.white,
            size: 28,
          ),
        ),
      ),
      body: HomeListeners(
        child: HomeBody(
          statusFrameOpen: _statusFrameOpen,
          sabiPanelOpen: _sabiPanelOpen,
          onStatusFrameClose: () => setState(() => _statusFrameOpen = false),
          onSabiPanelClose: () => setState(() => _sabiPanelOpen = false),
        ),
      ),
    );
  }

  // 【FEAT-426 移行案内 SnackBar は 2026-07-19 に撤去】
  // 既存ユーザーへの一度限りの案内は目的達成済 + 新規ユーザーには不要のため。
}
