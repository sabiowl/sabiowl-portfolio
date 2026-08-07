import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'l10n/app_localizations.dart';  // 【FEAT-489 Phase 1 (2026-07-29)】i18n 基盤
import 'package:hive_flutter/hive_flutter.dart';  // 【FEAT-476】Hive HTTP キャッシュ
import 'package:sentry_flutter/sentry_flutter.dart';  // 【FEAT-470】
import 'package:shared_preferences/shared_preferences.dart';  // FEAT-280
import 'core/analytics/posthog_service.dart';  // FEAT-200
import 'core/cache/cache_service.dart';  // FEAT-280
import 'core/l10n/app_locale.dart';  // 【FEAT-489 Phase 2G-a】locale 解決 (BUG-27 防御)
import 'core/l10n/service_l10n.dart';  // 【FEAT-489 Phase 2D】service 層の l10n 同期
import 'core/router/app_router.dart';
import 'core/services/notification_service.dart';
import 'features/battle/providers/battle_provider.dart'
    show ambientAutoBattleEnabledProvider;  // 【FEAT-513 gameplay_review 20260803 §2-1】
import 'features/battle/services/ambient_auto_battle_preferences.dart';  // 同上
import 'features/challenge/services/challenge_notification_service.dart';  // 【FEAT-509】
import 'core/services/popup_serializer.dart';  // 【gameplay_review 20260627 P2-1】popup 直列化
import 'core/services/toast_center.dart';  // FEAT-247
import 'core/theme/app_theme.dart';
import 'core/widgets/boot_gate.dart';           // 【2026-07-07】起動時パラレルプローブ
import 'core/widgets/connection_error_overlay.dart';  // 【2026-07-09】通信/サーバエラー画面
import 'core/widgets/maintenance_overlay.dart';  // FEAT-463
import 'features/habits/providers/habits_provider.dart';  // FEAT-438
import 'features/habits/widgets/monthly_ticket_awarded_dialog.dart';  // FEAT-438
import 'features/puzzle_world/widgets/puzzle_piece_listener.dart';  // 【FEAT-479 global hotfix 2026-07-07】

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 【FEAT-476 Pre-mortem S4】Hive 初期化: HiveCacheStore (Dio HTTP キャッシュ) の
  // 構築より前に完了必須。main() 冒頭、他のすべての初期化より先に実施。
  await Hive.initFlutter();

  // 縦向き固定（Android も明示的に制限）
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
  ]);

  // Firebase FCM 初期化（Firebase 設定後に有効化）
  await NotificationService.initialize();

  // 【FEAT-509】端末再起動 / OS 削除でチャレンジ結果通知の予約が消えている場合に再予約。
  // fire-and-forget: enabled=false なら即 return、enabled=true で pending 確認後に再予約。
  final challengeNotifService = ChallengeNotificationService(
    FlutterLocalNotificationScheduler(NotificationService.localNotifications),
  );
  // ignore: discarded_futures — fire-and-forget reschedule
  challengeNotifService.rescheduleIfNeeded();

  // FEAT-200: PostHog プロダクトアナリティクス初期化
  // API キーは --dart-define=POSTHOG_API_KEY=... で注入する。
  // キー未設定時は no-op として動作するため、ローカル開発・テストでも動作に支障なし。
  await PosthogService.instance.init();

  // 【FEAT-280】オフラインキャッシュ初期化。
  // SharedPreferences を 1 回 await で取得 → CacheService を Riverpod に注入。
  // 起動直後にバックグラウンド GC（fire-and-forget、起動を遅らせない）。
  final prefs = await SharedPreferences.getInstance();
  final cacheService = CacheService(prefs);

  // 【FEAT-489 Phase 2G-a】起動時 locale を runApp 前に確定させる。
  //
  // 最初のフレームから正しい言語で描画するため (一瞬 ja で出てから en に
  // 切り替わる flash を防ぐ)。端末 locale は **先頭 1 つだけ** を見て ja/en に
  // 丸める —— zh / ko 端末を en に落とすと BUG-27 の条件に入るため
  // (詳細は core/l10n/app_locale.dart の doc comment)。
  final initialLocale = resolveInitialLocale(
    savedLanguageCode: prefs.getString(kPreferredLanguageKey),
    deviceLocale: WidgetsBinding.instance.platformDispatcher.locale,
  );

  // 【FEAT-513 / gameplay_review 20260803 §2-1】オートバトル ON/OFF も runApp 前に確定させる。
  //
  // 旧: `ambientAutoBattleEnabledProvider` の初期値は常に false で、prefs の値を
  //     流し込むのは `GuildPage.initState` の 1 箇所だけだった。ShellRoute 配下の
  //     GuildPage は **ギルドタブを開くまで build されない** ため、
  //     「起動 → ホーム着地 → その session ではまだギルド未訪問」という最も普通の
  //     導線で、オーケストレータ (prefs 直読み) は countdown を回すのに、
  //     それを描画する overlay 側は false のまま = **中止する手段が画面に無いまま
  //     自動出陣が始まる**状態だった。
  // 新: locale (Phase 2G-a) と同じ処方で runApp 前に解決して override する。
  //     「発火の真実値 = prefs」と「描画の真実値 = provider」が起動直後から一致する。
  final ambientAutoBattleEnabled = AmbientAutoBattlePreferences.isEnabled(prefs);

  // ignore: discarded_futures — fire-and-forget GC
  cacheService.garbageCollect();

  // 【FEAT-470 (2026-07-03)】Sentry クラッシュ監視。DSN 未設定時は init のみ no-op。
  await SentryFlutter.init(
    (options) {
      options.dsn = const String.fromEnvironment('SENTRY_DSN_FLUTTER', defaultValue: '');
      options.tracesSampleRate = 0.1;
      // 個人情報を Sentry に送らない (プライバシーポリシー整合)
      options.beforeSend = (event, hint) => event.copyWith(user: null);
    },
    appRunner: () => runApp(
      ProviderScope(
        overrides: [
          cacheServiceProvider.overrideWithValue(cacheService),
          // 【FEAT-489 Phase 2G-a】main() で解決した locale を注入。
          initialLocaleProvider.overrideWithValue(initialLocale),
          // 【gameplay_review 20260803 §2-1】main() で解決したオートバトル ON/OFF を注入。
          ambientAutoBattleEnabledProvider
              .overrideWith((ref) => ambientAutoBattleEnabled),
        ],
        child: const RestackApp(),
      ),
    ),
  );
}

/// P0-5: 起動後、最初のフレーム描画完了後にクリティカルアセットをバックグラウンドでプリキャッシュ。
/// splash 表示中に裏で実施するため、起動時のメモリ圧迫を防ぎつつ
/// ガチャ演出・world_frame の初回描画遅延を消す。
Future<void> _precacheCriticalAssets(BuildContext context) async {
  await Future.wait([
    precacheImage(
      const AssetImage('assets/animations/world/bar.webp'), context),
    precacheImage(
      const AssetImage('assets/animations/world/glass.webp'), context),
  ]);
}

class RestackApp extends ConsumerStatefulWidget {
  const RestackApp({super.key});

  @override
  ConsumerState<RestackApp> createState() => _RestackAppState();
}

class _RestackAppState extends ConsumerState<RestackApp> {
  // 【FEAT-226】precache 初回限定フラグ。MaterialApp.router の再 build 毎に
  // addPostFrameCallback が登録され WebP 2 枚の再デコードリクエストが
  // 走るのを防ぐ。
  bool _precached = false;

  @override
  void initState() {
    super.initState();
    // 【BUG-101】FCM タップ (foreground / background / terminated) からの deep link を
    // 受け取って GoRouter で遷移する。NotificationService.initialize 内で
    // getInitialMessage 済の値も RestackApp 起動完了後にここで消化される。
    // 二重発火 (getInitialMessage + onMessageOpenedApp の race) は ValueNotifier の
    // `==` 比較で自動 dedupe される (同値書き込み時は listener 発火しない)。
    NotificationService.pendingDeepLink.addListener(_onPendingDeepLinkChanged);
    // 起動完了後の 1 フレーム遅延で初回チェック (terminated launch 経路)。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _onPendingDeepLinkChanged();
    });
    // 【FEAT-463 → 2026-07-07】起動時 maintenance 状態確認は BootGate widget が
    // パラレルプローブ (health + maintenance、3s timeout) で実行する経路に統合済。
    // 旧: `ref.read(maintenanceStatusProvider.notifier).refresh()` fire-and-forget
    //     を initState で呼んでいたが、blocking しないため通常 UI 描画が先行し、
    //     Backend 障害検知が遅れる問題があった。
    // 新: BootGate が MaterialApp.router.builder の最上位で probe → splash 表示 →
    //     完了後に通常 UI 描画。migration bug 由来の schema drift も health check
    //     の 503 で自動検知される。
  }

  @override
  void dispose() {
    NotificationService.pendingDeepLink.removeListener(_onPendingDeepLinkChanged);
    super.dispose();
  }

  void _onPendingDeepLinkChanged() {
    final route = NotificationService.pendingDeepLink.value;
    if (route == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final router = ref.read(appRouterProvider);
      router.go(route);
      NotificationService.clearDeepLink();
    });
  }

  @override
  Widget build(BuildContext context) {
    final router = ref.watch(appRouterProvider);

    // P0-5: ホーム到達後の idle フレームでアセットをプリキャッシュ（初回のみ）
    if (!_precached) {
      _precached = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _precacheCriticalAssets(context);
      });
    }

    // 【FEAT-489 Phase 2G-a】言語切替で MaterialApp ごと rebuild させる。
    // Localizations は InheritedWidget なので、AppLocalizations.of(context) を
    // 使っている widget は自動的に再 build される (S2 の 2 言語混在対策)。
    final appLocale = ref.watch(appLocaleProvider);

    return MaterialApp.router(
      title: 'Sabiowl',  // OPS-01: アプリ名変更
      theme: AppTheme.darkTheme,
      routerConfig: router,
      // 【FEAT-247】アプリ全体で共有する ScaffoldMessenger。TimelineService の
      // fire-and-forget Google push 失敗通知を ToastCenter 経由でホーム /
      // add_event_page / quick_add_task_sheet からも届けるための集約点。
      scaffoldMessengerKey: ToastCenter.messengerKey,
      debugShowCheckedModeBanner: false,
      // 【FEAT-438 (2026-06-17)】月間 21 日達成 SSR 確定チケット獲得時の global dialog。
      // 旧 SnackBar (FEAT-433) からポップアップに昇格。タスク達成がどの画面 (ホーム /
      // カレンダー / タイムライン等) で起きても、アプリ全体で 1 回だけ確実にダイアログ
      // を表示する単一監視点。ShellRoute 配下の各 page に ref.listen を分散させると
      // kAlive で多重発火するため、本 MaterialApp.router の builder に集約する設計。
      //
      // builder の context は Navigator 直下に位置する (公式仕様) ため、showDialog の
      // Navigator.of(context, rootNavigator: true) が確実に root Navigator を解決する。
      //
      // 多重発火防止: ① edge trigger (next==true && prev!=true) ② postFrame で
      // 即座に false へ reset することで「true 永続中の build 再実行」でも誤発火しない。
      builder: (dialogContext, child) {
        // 【FEAT-489 Phase 2D (2026-08-02)】BuildContext を持たない層
        // (NotificationService / MaintenanceStatus.placeholderOn / formatApiError /
        // IAP Exception / app_urls の mailto テンプレ) が参照する AppLocalizations を
        // ここで同期する。builder の context は Localizations の子孫 (公式仕様)。
        // Phase 5 で言語切替 UI が入っても、locale 変更 → 再 build → 自動追従する。
        ServiceL10n.syncFrom(dialogContext);

        // 【2026-08-02】Android 通知チャンネル名を locale に追従させる。
        //
        // `NotificationService.initialize()` は main() 冒頭 = locale 確定より
        // 前に走るため、チャンネルは必ず ja の名前で作られる。ここで作り直す。
        // locale が変わった時だけ実際に platform channel を叩く実装なので、
        // builder が再 build されても無駄打ちしない。
        // ignore: discarded_futures — fire-and-forget、失敗しても通知は届く
        NotificationService.refreshChannelsIfLocaleChanged();

        // 【2026-07-07】BootGate で起動時に /api/health/ + /api/maintenance/ を
        // パラレルプローブ (max 3s)。Backend 障害検知時は maintenance overlay
        // に自動遷移して user に状況通知する。
        //
        // 【FEAT-463】MaintenanceOverlay で全体を包み込み、go_router ShellRoute
        // より上位で全画面 overlay を表示できるようにする。
        //
        // 【FEAT-479 global hotfix 2026-07-07】PuzzlePieceListener を builder に
        // 移設。旧配置 (home_body.dart の Positioned) では user が Guild /
        // Timeline / Battle 等のホーム外にいる時に `ref.listen` が edge-triggered
        // で状態変化を見逃し、quest piece 演出が発火しない bug があった。
        // main.dart 直下なら全画面で常時 mount = 確実に検知。
        //
        // 【2026-07-09】ConnectionErrorOverlay を MaintenanceOverlay の 1 段内側に
        // 追加。admin 意図の maintenance と mobile 側の通信/サーバエラー を別画面で
        // 表示する。UI 優先順位: MaintenanceOverlay > ConnectionErrorOverlay > 通常 UI。
        // Stack の layer 順 (children の後ろほど上位) で担保。
        //
        // Layer 順 (外 → 内):
        //   BootGate              : 起動時 probe を fire-and-forget、子を即座に描画
        //   MaintenanceOverlay    : `maintenanceStatusProvider.isEnabled` を watch
        //                            して isEnabled=true 時に overlay 表示
        //   ConnectionErrorOverlay: `connectionErrorProvider.hasError` を watch
        //                            して hasError=true かつ maintenance OFF 時に表示
        //   PuzzlePieceListener   : puzzlePieceAwardedProvider / Colored を watch
        //                            して piece 演出発火 (全画面共通)
        //   Consumer              : 月間チケット SSR 確定 dialog の global listener
        return BootGate(
          child: MaintenanceOverlay(
            child: ConnectionErrorOverlay(
              child: PuzzlePieceListener(
                child: Consumer(
                  builder: (consumerContext, consumerRef, _) {
                    consumerRef.listen<bool>(
                      monthlyTicketAwardedNotifierProvider,
                      (prev, next) {
                        if (next != true || prev == true) return;
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          if (!consumerContext.mounted) return;
                          consumerRef
                              .read(monthlyTicketAwardedNotifierProvider.notifier)
                              .state = false;
                          // 【gameplay_review 20260627 P2-1】祝祭系 popup 直列化のため
                          // PopupSerializer 経由に変更。レベルアップ等が同時発火しても順次表示。
                          // 【2026-07-08 hotfix】consumerContext は MaterialApp.router.builder
                          // 内 = go_router の Router/Navigator の祖先。
                          // `Navigator.of(context, rootNavigator: true)` が null crash する
                          // 経路のため、rootNavigatorKey.currentContext (Navigator 内側) を
                          // 直接使う。fallback で起動直後の未 attach 状態も consumerContext
                          // で救済。詳細は app_router.dart:rootNavigatorKey コメント参照。
                          PopupSerializer.enqueueShowDialog<void>(
                            context: rootNavigatorKey.currentContext ?? consumerContext,
                            useRootNavigator: false,  // navContext は既に Navigator 内側
                            barrierDismissible: true,
                            builder: (_) => const MonthlyTicketAwardedDialog(),
                          );
                        });
                      },
                    );
                    return child ?? const SizedBox.shrink();
                  },
                ),
              ),
            ),
          ),
        );
      },
      // 【BUG-27】端末言語が中文等の場合、漢字が中国語グリフでフォールバック描画
      // される。日本語フォントは同梱していないため、**locale に明示値を渡すことが
      // 唯一の防御**。`locale: null` (= 端末任せ) にすると中文端末で再発する。
      //
      // 【FEAT-489 Phase 2G-a (2026-08-02)】en を解禁。
      // Phase 1-2F で arb 1,380 key が埋まったため supportedLocales に en を追加し、
      // 設定画面から切替可能にした。ただし **locale は常に non-null** で、
      // 値は ja_JP / en の 2 つに限定される (core/l10n/app_locale.dart)。
      // この不変条件は test/i18n_locale_guard_test.dart が CI で固定している。
      locale: appLocale,
      supportedLocales: kSupportedLocales,
      // BUG-28: supportedLocales を ja_JP のみに絞ると DefaultMaterialLocalizations
      // (英語のみ対応) では解決できず AppBar 等で assertion エラーになる。
      // GlobalMaterialLocalizations 系のデリゲートを登録して ja_JP を解決可能にする。
      localizationsDelegates: const [
        AppLocalizations.delegate,  // 【FEAT-489 Phase 1】i18n 基盤
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
    );
  }
}
