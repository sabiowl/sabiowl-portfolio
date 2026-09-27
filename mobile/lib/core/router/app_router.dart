import 'dart:io' show Platform;
import 'dart:ui';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import '../../core/api/api_client.dart';
import '../../core/theme/app_theme.dart';
import '../../features/auth/pages/auth_page.dart';
import '../../features/auth/pages/onboarding_page.dart';
import '../../features/battle/pages/battle_page.dart';  // FEAT-295
import '../../features/calendar/pages/calendar_page.dart';
import '../../features/gamification/pages/character_page.dart';
import '../../features/gamification/pages/gacha_odds_page.dart';  // 【FEAT-518】
import '../../features/gamification/pages/gacha_page.dart';
import '../../features/gamification/pages/shop_page.dart';
import '../../features/shop/pages/diamond_pack_page.dart'; // FEAT-436
import '../../features/gamification/pages/stats_page.dart';
// 【廃止 (2026-06-26)】 titles_page.dart は実績 30 件統合で削除
import '../../features/habits/pages/add_habit_page.dart';
import '../../features/timeline/pages/add_event_page.dart';          // FEAT-151
import '../../features/timeline/pages/edit_event_page.dart';         // FEAT-159
import '../../features/timeline/pages/timeline_defaults_page.dart';  // FEAT-174
import '../../features/timeline/pages/add_template_page.dart';       // FEAT-175
import '../../features/timeline/pages/edit_template_page.dart';      // FEAT-175
import '../../features/timeline/models/timeline_models.dart'; // FEAT-159: TimelineEvent 型
import '../../features/habits/pages/add_todo_page.dart';    // FEAT-152
import '../../features/calendar/pages/calendar_add_page.dart'; // FEAT-154
import '../../features/habits/pages/archived_habits_page.dart';
import '../../features/habits/models/habit.dart' show Habit; // FEAT-161
import '../../features/habits/pages/edit_habit_page.dart';
import '../../features/habits/pages/edit_todo_page.dart';   // FEAT-161
import '../../features/habits/pages/habit_detail_page.dart';
import '../../features/habits/pages/home_page.dart';
import '../../features/habits/pages/todo_done_list_page.dart';
import '../../features/settings/pages/account_page.dart';
import '../../features/settings/pages/help_web_view_page.dart';  // 【FEAT-485】
// 【2026-07-05】アプリ内ネイティブ描画版 (privacy_policy_page / terms_of_service_page) を廃止し、
// GitHub Pages への外部 URL 遷移に統一。sabiowl-home-pages を Single Source of Truth 化して
// drift リスクを構造解消。Settings 側の launchUrl は `_openPrivacyPolicy` / `_openTermsOfService`。
// 【FEAT-396 (2026-05-31)】privacy_settings_page は廃止 (習慣内容は常に非公開、継続日数は常に公開固定)
import '../../features/settings/pages/profile_edit_page.dart';
import '../../features/settings/pages/reminder_settings_page.dart';
import '../../features/settings/pages/settings_page.dart';
import '../../features/auth/providers/auth_provider.dart';
import '../../features/social/pages/contact_page.dart';
import '../../features/social/pages/friend_add_page.dart';
import '../../features/social/pages/friend_list_page.dart';
import '../../features/social/pages/friend_profile_page.dart';
// 【FEAT-446 (2026-06-20)】messages_page.dart import 削除 (ファイル削除済)。
import '../../features/social/pages/notifications_page.dart';
import '../../features/gamification/pages/achievement_page.dart';
// 【FEAT-207】QuestPage を GuildPage にリブランディング（features/quests/ は本コミットで削除）
import '../../features/guild/pages/guild_page.dart';
import '../../features/challenge/pages/challenge_page.dart';  // FEAT-465
import '../../features/puzzle_world/pages/scene_selection_page.dart';  // FEAT-479
import '../../features/puzzle_world/pages/puzzle_scene_detail_page.dart';  // FEAT-479
import '../../features/free_memo/pages/memo_page.dart';  // 【FEAT-493 (2026-07-25)】フリーメモ
// 【ユーザー判断 2026-05-31】AppBar 城バッジを BottomNav ギルドタブに移動 (FEAT-311 + FEAT-398 統合)
import '../../features/battle/providers/battle_provider.dart';
import '../../l10n/app_localizations.dart';

part 'app_router.g.dart';

// 画面パス定数
class AppRoutes {
  static const splash      = '/';
  static const onboarding  = '/onboarding'; // 初回起動チュートリアル
  static const auth        = '/auth';       // 後方互換のため残す
  static const register    = '/auth/register';
  static const login       = '/auth/login';
  static const home = '/home';
  static const addHabit  = '/habits/add';
  static const addEvent         = '/timeline/add';      // FEAT-151
  static const editEvent        = '/timeline/edit';     // FEAT-159
  static const timelineDefaults = '/timeline/defaults';      // FEAT-174
  static const addTemplate      = '/timeline/defaults/add';  // FEAT-175
  static const editTemplate     = '/timeline/defaults/edit'; // FEAT-175: 予定編集（full-screen）
  static const addTodo      = '/habits/todo/add';  // FEAT-152
  static const editTodo     = '/habits/todo/edit'; // FEAT-161
  static const calendarAdd  = '/calendar/add';    // FEAT-154
  static const habitDetail = '/habits/:id';
  static const editHabit = '/habits/:id/edit';
  static const archivedHabits = '/habits/archived';
  static const todoDone = '/habits/todos/done';
  static const stats = '/stats';
  static const character = '/character';
  static const shop = '/shop';
  // 【FEAT-436 (2026-06-17)】ダイヤ購入画面 (RevenueCat 経由 IAP、iOS 先行)
  static const diamondPack = '/shop/diamond-pack';
  static const gacha = '/gacha';
  // 【FEAT-518 (2026-08-05)】ガチャ排出確率の開示 (App Store Guideline 3.1.1)。
  // 固定パス `/gacha/odds` は動的パスより前に定義すること (現状 /gacha 配下に
  // 動的パスは無いが、将来追加されたときの前方一致事故を防ぐため位置を固定)。
  static const gachaOdds = '/gacha/odds';
  // 【廃止 (2026-06-26)】 `/titles` ルートは実績 30 件統合で撤去。
  // 互換性のため const は残置せず削除。残存参照がある場合は実績 (/achievements) に誘導。
  static const guild = '/guild';   // 【FEAT-207】旧 quests からリブランディング
  static const challenges = '/challenges';  // 【FEAT-465】月次カテゴリチャレンジ
  static const puzzleWorld = '/puzzle-world';  // 【FEAT-479】パズル世界シーン選択
  static const calendar = '/calendar';
  static const friendList = '/friends';
  static const friendAdd = '/friends/add';
  static const friendProfile = '/friends/:playerId';
  // 【FEAT-446 (2026-06-20)】messages ルート削除: フレンド間メッセージ機能廃止
  // (トラブル / 悪用未然防止)。旧 '/messages/:playerId' を撤去。
  static const notifications = '/notifications';
  static const settings = '/settings';
  static const profileEdit = '/settings/profile';
  // 【FEAT-396 (2026-05-31)】privacySettings ルート廃止 (設定 UI 削除、固定挙動)
  // 【2026-07-05】privacyPolicy / termsOfService ルート廃止。GitHub Pages への
  // launchUrl 遷移に統一し drift リスクを構造解消 (Single Source of Truth 化)。
  static const accountDelete = '/settings/account/delete';
  static const reminderSettings  = '/settings/notifications';
  // 【FEAT-485 (2026-07-08)】使い方・ヘルプ (アプリ内 WebView、sabiowl-home-pages
  // の help ページを表示)。既存 FAQ (kSabiowlFaqUrl、外部ブラウザ) との使い分けは
  // help_web_view_page.dart の docstring 参照。
  static const help = '/settings/help';
  static const contact = '/contact';
  static const achievements = '/achievements';
  // 【FEAT-295】バトル全画面ページ。ホームウィジェットからの push 遷移のみ。
  static const battle = '/battle';
  // 【FEAT-493 (2026-07-25)】フリーメモ専用画面
  static const memos = '/memos';
}

// BUG-01: authProvider の sessionExpired 変化を GoRouter に通知するためのブリッジ。
// authProvider 全体を listen すると loading フラグ等の頻繁な変化でも redirect が
// 走ってしまうので、sessionExpired のエッジ変化だけを拾って notifyListeners する。
class _SessionExpiredNotifier extends ChangeNotifier {
  _SessionExpiredNotifier(Ref ref) {
    ref.listen<AuthState>(authProvider, (prev, next) {
      // 【BUG-156 (2026-09-11)】`status` の変化も拾う。
      //
      // `sessionExpired` は**ワンショット**で、AuthPage が表示直後に
      // クリアする。それだけを見張っていると、クリア後にホームへ戻った
      // ユーザーを誰も止められない —— **401 を受けてもホームに留まれる**。
      //
      // ⚠️ **`sessionExpired` と `status` の 2 つだけ**にすること。
      //    `isLoading` 等の頻繁な変化まで拾うと redirect が暴走する。
      if (prev?.sessionExpired != next.sessionExpired ||
          prev?.status != next.status) {
        notifyListeners();
      }
    });
  }
}

/// 【2026-07-08 hotfix】root Navigator への安定アクセス用 GlobalKey。
///
/// `MaterialApp.router.builder` 内の PuzzlePieceListener / Consumer 等、
/// go_router の Router 祖先に位置する widget から showDialog / showGeneralDialog
/// を叩く経路では `Navigator.of(context, rootNavigator: true)` が祖先に Navigator
/// を見つけられず null crash する ("TypeError: Null check operator used on a null value")。
///
/// GoRouter に本 key を明示することで、caller は `rootNavigatorKey.currentContext`
/// 経由で Navigator 内側の context を取得できる。用例:
///
/// ```dart
/// await showGeneralDialog(
///   context: rootNavigatorKey.currentContext ?? context,  // fallback で caller も許可
///   useRootNavigator: false,  // navContext は既に Navigator 内側
///   ...
/// );
/// ```
///
/// 参考 Sentry: `showPuzzlePieceQuestOverlay` (puzzle_piece_overlay_modal.dart)
/// で本 hotfix 前に null crash 観測 (2026-07 v1.0.2)。
final rootNavigatorKey = GlobalKey<NavigatorState>(debugLabel: 'rootNavigator');

// ──────────────────────────────────────────────────────────────────────────────
// 【BUG-156 (2026-09-11)】未認証でも到達してよいルート
// ──────────────────────────────────────────────────────────────────────────────
//
// 🔴 **このリストは load-bearing になった。**
//
// 以前は `sessionExpired` という**稀な条件のときだけ**使われていたが、
// 「未認証なら常に redirect」に広げたことで**常時効く**ようになった。
// ここから漏れた public ルートは**未認証ユーザーから到達不能**になる ——
// onboarding / register / login のどれかが漏れれば
// **新規ユーザーが登録できない**。
//
// ⚠️ 手で数えたリストを信用しない。`test/core/router_public_routes_test.dart`
//    が `AppRoutes` の全定数を走査し、**下の 2 つの箱のどちらかに
//    分類済みであること**を縛っている (BUG-153 と同じ形)。
//
// 🔵 【FEAT-542 (2026-09-23)】**`/onboarding` がここから消えた。**
//
// BUG-156 は「未認証なら `/login`」を規則にしたが、成立させるために
// `/onboarding` を public 例外として登録する必要があった ——
// **オンボーディングが認証より先に来て、途中で黙ってゲストを作っていた**
// からである。認証を先に済ませる順序では、あの画面に着いた時点で
// **必ずトークンがある**。
//
// 🔴 **規則と現実が一致した。** 未認証のユーザーは実際に認証画面にいる。
const kPublicRoutePrefixes = <String>[
  AppRoutes.splash,           // '/'
  AppRoutes.auth,
  AppRoutes.register,
  AppRoutes.login,
];

// 「認証が要る」と**意図して**分類したルート。
//
// 🔵 空の箱ではなく明示列挙にしているのは、新しいルートを足した人に
//    「public か / 認証必須か」を**必ず 1 回考えさせる**ためである。
//    どちらにも入れなければテストが名前を出して落ちる。
const kAuthRequiredRoutes = <String>[
  // 🔵 【FEAT-542】プロフィール設定は**認証の後**に来る。
  //    ここに着く人は必ずトークンを持っている。
  AppRoutes.onboarding,
  AppRoutes.home,
  AppRoutes.addHabit, AppRoutes.editHabit, AppRoutes.habitDetail,
  AppRoutes.archivedHabits, AppRoutes.todoDone,
  AppRoutes.addTodo, AppRoutes.editTodo,
  AppRoutes.addEvent, AppRoutes.editEvent,
  AppRoutes.timelineDefaults, AppRoutes.addTemplate, AppRoutes.editTemplate,
  AppRoutes.calendar, AppRoutes.calendarAdd,
  AppRoutes.stats, AppRoutes.character, AppRoutes.achievements,
  AppRoutes.shop, AppRoutes.diamondPack,
  AppRoutes.gacha, AppRoutes.gachaOdds,
  AppRoutes.guild, AppRoutes.challenges, AppRoutes.puzzleWorld,
  AppRoutes.friendList, AppRoutes.friendAdd, AppRoutes.friendProfile,
  AppRoutes.notifications,
  AppRoutes.settings, AppRoutes.profileEdit, AppRoutes.reminderSettings,
  AppRoutes.accountDelete, AppRoutes.help, AppRoutes.contact,
  // 🔵 この 2 件は手書きのリストから**漏れていた**。
  //    走査テストが名前を出して落としてくれた —— 手で数えたリストは
  //    書いた瞬間から腐る、という前提で作った仕組みが実際に効いた形である。
  AppRoutes.battle, AppRoutes.memos,
];

@riverpod
GoRouter appRouter(Ref ref) {
  final sessionNotifier = _SessionExpiredNotifier(ref);
  ref.onDispose(sessionNotifier.dispose);

  return GoRouter(
    navigatorKey: rootNavigatorKey,  // 【2026-07-08 hotfix】上記コメント参照
    observers: [HeroController()],  // Hero アニメーションを CustomTransitionPage でも有効化
    initialLocation: AppRoutes.splash,
    debugLogDiagnostics: true,
    refreshListenable: sessionNotifier,
    redirect: (context, state) {
      final auth = ref.read(authProvider);

      // 🔴 【BUG-156 (2026-09-11)】判定中は動かさない。
      //
      // 起動直後は `checking` なので、除外しないと**必ずログイン画面を
      // 経由して**ちらつく。
      if (auth.status == AuthStatus.checking) return null;

      // BUG-01: 401 によるセッション失効。
      // 【BUG-156】`unauthenticated` でも飛ばす。
      //
      // `sessionExpired` は**ワンショット**で AuthPage が即クリアするため、
      // これだけを見ていると**クリア後にホームへ戻ったユーザーを誰も
      // 止められない**。実際、401 を受けても読み込みエラーだらけの
      // ホームに留まり続ける状態になっていた。
      if (!auth.sessionExpired &&
          auth.status != AuthStatus.unauthenticated) {
        return null;
      }

      // 認証フロー / スプラッシュは遷移させない（無限ループ防止）
      final loc = state.matchedLocation;
      // splash パス '/' は startsWith では他ルートと衝突するため等価比較
      if (loc == AppRoutes.splash) return null;
      if (kPublicRoutePrefixes
          .any((p) => p != AppRoutes.splash && loc.startsWith(p))) {
        return null;
      }
      return AppRoutes.login;
    },
    routes: [
      GoRoute(
        path: AppRoutes.splash,
        builder: (context, state) => const _SplashScreen(),
      ),
      GoRoute(
        path: AppRoutes.onboarding,
        pageBuilder: (context, state) => CustomTransitionPage(
          child: const OnboardingPage(),
          transitionsBuilder: (context, animation, _, child) => FadeTransition(
            opacity: CurvedAnimation(
                parent: animation, curve: Curves.easeIn),
            child: child,
          ),
        ),
      ),
      GoRoute(
        path: AppRoutes.auth,
        // 後方互換：/auth は登録画面へリダイレクト
        redirect: (_, __) => AppRoutes.register,
      ),
      GoRoute(
        path: AppRoutes.register,
        // FEAT-128: AuthMode 削除 → 統一サインインページ
        builder: (context, state) => const AuthPage(),
      ),
      GoRoute(
        path: AppRoutes.login,
        // FEAT-128: AuthMode 削除 → 統一サインインページ
        builder: (context, state) => const AuthPage(),
      ),
      // Phase 2: BottomNav の外に配置（全画面遷移）
      GoRoute(
        path: AppRoutes.addHabit,
        builder: (context, state) {
          // 【FEAT-493】extra が Map の場合は initialTitle を受け取る (フリーメモ変換経路)
          final extra = state.extra as Map<String, dynamic>?;
          return AddHabitPage(initialTitle: extra?['initialTitle'] as String?);
        },
      ),
      // FEAT-151: タイムライン予定追加（全画面遷移）
      // 【FEAT-493】extra が DateTime の場合はそのまま (既存経路)、
      //   Map の場合は initialDate / initialTitle を受け取る (フリーメモ変換経路)
      GoRoute(
        path: AppRoutes.addEvent,
        builder: (context, state) {
          final extra = state.extra;
          if (extra is DateTime) {
            return AddEventPage(initialDate: extra);
          }
          final extraMap = extra as Map<String, dynamic>?;
          return AddEventPage(
            initialDate: extraMap?['initialDate'] as DateTime? ?? DateTime.now(),
            initialTitle: extraMap?['initialTitle'] as String?,
          );
        },
      ),
      // FEAT-159: 予定編集全画面ページ
      GoRoute(
        path: AppRoutes.editEvent,
        builder: (context, state) {
          final event = state.extra as TimelineEvent;
          return EditEventPage(event: event);
        },
      ),
      // FEAT-174: デフォルト設定 全画面ページ
      GoRoute(
        path: AppRoutes.timelineDefaults,
        builder: (context, state) => const TimelineDefaultsPage(),
      ),
      // FEAT-175: テンプレート追加ページ
      GoRoute(
        path: AppRoutes.addTemplate,
        builder: (context, state) => const AddTemplatePage(),
      ),
      // FEAT-175: テンプレート編集ページ（extra で TimelineTemplate を受け取る）
      GoRoute(
        path: AppRoutes.editTemplate,
        builder: (context, state) {
          final template = state.extra as TimelineTemplate;
          return EditTemplatePage(template: template);
        },
      ),
      // FEAT-152: ToDo 追加（全画面遷移）
      // 【FEAT-493】extra が Map の場合は initialTitle を受け取る (フリーメモ変換経路)
      GoRoute(
        path: AppRoutes.addTodo,
        builder: (context, state) {
          final extra = state.extra as Map<String, dynamic>?;
          return AddTodoPage(initialTitle: extra?['initialTitle'] as String?);
        },
      ),
      // FEAT-161: ToDo 編集全画面ページ
      // FEAT-168: EditTodoArgs（readOnly フラグ付き）も受け付ける
      GoRoute(
        path: AppRoutes.editTodo,
        builder: (context, state) {
          final extra = state.extra;
          if (extra is EditTodoArgs) {
            return EditTodoPage(todo: extra.todo, readOnly: extra.readOnly);
          }
          return EditTodoPage(todo: extra as Habit);
        },
      ),
      // FEAT-154: カレンダー追加タブページ（全画面遷移）
      // 【2026-06-28】FAB 「軽快なタップ感」 一式の一部: 画面遷移を CustomTransitionPage
      // 化し、下からフェード (FadeTransition + SlideTransition (begin Offset(0, 0.08)))
      // を 220ms / Curves.easeOutCubic で実行。FAB の縮小バック (160ms) + 120ms 遅延
      // 発火と合わせて、タップから画面到着まで体感 340ms ほどの一貫した「軽い」リズム。
      GoRoute(
        path: AppRoutes.calendarAdd,
        pageBuilder: (context, state) {
          final date = state.extra as DateTime? ?? DateTime.now();
          return CustomTransitionPage(
            child: CalendarAddPage(initialDate: date),
            transitionDuration: const Duration(milliseconds: 220),
            reverseTransitionDuration: const Duration(milliseconds: 200),
            transitionsBuilder: (context, animation, _, child) {
              final curve = CurvedAnimation(
                parent: animation,
                curve: Curves.easeOutCubic,
              );
              return FadeTransition(
                opacity: curve,
                child: SlideTransition(
                  position: Tween<Offset>(
                    begin: const Offset(0, 0.08),
                    end: Offset.zero,
                  ).animate(curve),
                  child: child,
                ),
              );
            },
          );
        },
      ),
      // todoDone / archivedHabits は habitDetail より必ず先に定義する
      // （固定パスが動的パス /habits/:id にマッチしてしまうため）
      GoRoute(
        path: AppRoutes.todoDone,
        builder: (context, state) => const TodoDoneListPage(),
      ),
      GoRoute(
        path: AppRoutes.archivedHabits,
        builder: (context, state) {
          final extra = state.extra as Map<String, dynamic>?;
          final initialTab = extra?['tab'] == 'trash' ? 1 : 0;
          return ArchivedHabitsPage(initialTab: initialTab);
        },
      ),
      GoRoute(
        path: AppRoutes.habitDetail,
        builder: (context, state) {
          final id = int.parse(state.pathParameters['id']!);
          return HabitDetailPage(habitId: id);
        },
      ),
      // 【FEAT-479 Phase 2c (2026-07-06)】パズル世界シーン詳細 (30 マス拡大 + 完成履歴)。
      // 意図的に ShellRoute の外に配置 (fullscreen 遷移 = BottomNav 非表示)。
      // /puzzle-world (SceneSelectionPage) から context.push でタップ遷移。
      GoRoute(
        path: '/puzzle-world/scene/:sceneKey',
        builder: (context, state) {
          final sceneKey = state.pathParameters['sceneKey']!;
          return PuzzleSceneDetailPage(sceneKey: sceneKey);
        },
      ),
      GoRoute(
        path: AppRoutes.editHabit,
        builder: (context, state) {
          final id = int.parse(state.pathParameters['id']!);
          return EditHabitPage(habitId: id);
        },
      ),
      GoRoute(
        path: AppRoutes.stats,
        pageBuilder: (context, state) => CustomTransitionPage(
          child: const StatsPage(),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            // フェードイン + 上方向スライド（カードが展開するイメージ）
            return FadeTransition(
              opacity: animation,
              child: SlideTransition(
                position: Tween<Offset>(
                  begin: const Offset(0, 0.05),
                  end: Offset.zero,
                ).animate(CurvedAnimation(
                  parent: animation,
                  curve: Curves.easeOut,
                )),
                child: child,
              ),
            );
          },
        ),
      ),
      GoRoute(
        path: AppRoutes.achievements,
        builder: (context, state) => const AchievementPage(),
      ),
      GoRoute(
        path: AppRoutes.character,
        builder: (context, state) => const CharacterPage(),
      ),
      // 【FEAT-518】固定パス `/gacha/odds` は `/gacha` より **前** に定義する。
      // GoRouter は定義順に前方一致で解決するため、順序を逆にすると将来
      // `/gacha/:id` 等を足したときに odds が id として解釈される。
      GoRoute(
        path: AppRoutes.gachaOdds,
        builder: (context, state) => const GachaOddsPage(),
      ),
      GoRoute(
        path: AppRoutes.gacha,
        builder: (context, state) => const GachaPage(),
      ),
      // 【廃止 (2026-06-26)】 GoRoute(/titles, TitlesPage) は実績 30 件統合で削除
      // 【FEAT-295】バトル全画面ページ（ShellRoute 外、push 遷移のみ）
      GoRoute(
        path: AppRoutes.battle,
        builder: (context, state) => const BattlePage(),
      ),
      // ── Phase 5: Social (全画面遷移) ──────────────────────────
      // friendList は ShellRoute から移動（BottomNav なし全画面）
      GoRoute(
        path: AppRoutes.friendList,
        builder: (context, state) => const FriendListPage(),
      ),
      GoRoute(
        path: AppRoutes.friendAdd,
        builder: (context, state) => const FriendAddPage(),
      ),
      GoRoute(
        path: AppRoutes.friendProfile,
        builder: (context, state) {
          final id = int.parse(state.pathParameters['playerId']!);
          return FriendProfilePage(playerId: id);
        },
      ),
      // 【FEAT-446 (2026-06-20)】messages GoRoute 削除: フレンド間メッセージ機能廃止。
      GoRoute(
        path: AppRoutes.notifications,
        builder: (context, state) => const NotificationsPage(),
      ),
      GoRoute(
        path: AppRoutes.contact,
        builder: (context, state) => const ContactPage(),
      ),
      // ── Phase 6: Settings (全画面遷移) ────────────────────
      GoRoute(
        path: AppRoutes.profileEdit,
        builder: (context, state) => const ProfileEditPage(),
      ),
      // 【FEAT-396 (2026-05-31)】privacySettings ルート廃止 (UI 削除)
      // 【2026-07-05】privacyPolicy / termsOfService GoRoute 廃止。Settings 画面の
      // `_openPrivacyPolicy` / `_openTermsOfService` から launchUrl で GitHub Pages に
      // 直接遷移する方式に統一 (release_notes / 特商法 / FAQ と同パターン)。
      GoRoute(
        path: AppRoutes.accountDelete,
        builder: (context, state) => const AccountPage(),
      ),
      GoRoute(
        path: AppRoutes.reminderSettings,
        builder: (context, state) => const ReminderSettingsPage(),
      ),
      // 【FEAT-493 (2026-07-25)】フリーメモ専用画面 (ShellRoute 外、全画面遷移)
      // extra に {'selectedDate': DateTime, 'entryPoint': String} を渡す。
      // selectedDate: Calendar FAB からの date コンテキスト引き継ぎ
      // entryPoint: 'home_fab' / 'calendar_fab' / 'home_section' (PostHog 計測用)
      GoRoute(
        path: AppRoutes.memos,
        builder: (context, state) {
          final extra = state.extra as Map<String, dynamic>?;
          return MemoPage(
            selectedDate: extra?['selectedDate'] as DateTime?,
            entryPoint: extra?['entryPoint'] as String? ?? 'home_fab',
          );
        },
      ),
      // 【FEAT-485 (2026-07-08)】使い方・ヘルプ画面 (アプリ内 WebView)。
      // 既存の GitHub Pages 外部ブラウザ経路 (privacy_policy / terms_of_service /
      // release_notes / 特商法 / FAQ) は「一度読めば済む」情報向けに残置し、
      // 使い方は「繰り返し参照する」性質のため WebView で context 保持する設計。
      GoRoute(
        path: AppRoutes.help,
        builder: (context, state) => const HelpWebViewPage(),
      ),
      // 【SEC-12】Shop は BottomNav から外し、ギルド画面 + ステータス画面からの
      // 遷移のみに変更。ShellRoute 外に独立ルートとして配置し `context.push('/shop')`
      // で全画面遷移する（dead UX 15 個削除と合わせて、Shop の存在感を「重要 4 機能」から
      // 「サブ画面」へ降格する位置付け）。URL `/shop` 自体は維持し、将来 Shop を再昇格
      // させる場合は ShellRoute 内に戻すだけで済む設計とした。
      GoRoute(
        path: AppRoutes.shop,
        // 【2026-07-05】?inventory=true で ShopPage を所持品リストモードで
        // 初期表示 (GuildDrawer「所持品リスト」動線用)。省略時は従来通り
        // ショップ (購入) モード。
        builder: (context, state) {
          final inventory =
              state.uri.queryParameters['inventory'] == 'true';
          return ShopPage(initialShowInventory: inventory);
        },
      ),
      // 【FEAT-436 (2026-06-17)】ダイヤ購入画面 (RevenueCat 経由 IAP)
      GoRoute(
        path: AppRoutes.diamondPack,
        builder: (_, __) => const DiamondPackPage(),
      ),
      ShellRoute(
        builder: (context, state, child) => _ScaffoldWithBottomNav(child: child),
        routes: [
          // 【2026-07-09 hotfix】BottomNav の 4 タブ間遷移で pageBuilder を使う。
          // 通常の builder は GoRouter default page (iOS: CupertinoPage) を返し、
          // 「常に右から左へ slide」になる (user 報告: チャレンジ → ホームでも右から入る違和感)。
          // pageBuilder + _buildTabPage で「タブ index が増える方向 = 右から、減る方向 = 左から」の
          // 直感的な directional slide に切替。
          //
          // 対象は BottomNav 4 タブのみ (home / challenges / guild / calendar)。
          // puzzleWorld / settings は BottomNav に無く、tab index 概念が無いため、
          // NoTransitionPage で「無方向」= 従来通り default 遷移に落とす。
          GoRoute(
            path: AppRoutes.home,
            pageBuilder: (_, state) => _buildTabPage(state, const HomePage()),
          ),
          // 【FEAT-465 (2026-06-24)】月次カテゴリチャレンジ。FEAT-464 の 3 タブ
          // 構成 (ホーム / ギルド / カレンダー) にホーム直後で挿入し 4 タブ化。
          GoRoute(
            path: AppRoutes.challenges,
            pageBuilder: (_, state) => _buildTabPage(state, const ChallengePage()),
          ),
          // 【FEAT-479 (2026-07-06)】パズル世界シーン選択画面。
          // アクティブ切替 + 額縁表示切替の両方を担う single page。
          // BottomNav 4 タブに含まれないので direction 無し (NoTransitionPage 経路)。
          GoRoute(
            path: AppRoutes.puzzleWorld,
            builder: (_, __) => const SceneSelectionPage(),
          ),
          GoRoute(
            path: AppRoutes.guild,
            pageBuilder: (_, state) => _buildTabPage(state, const GuildPage()),
          ),
          GoRoute(
            path: AppRoutes.calendar,
            pageBuilder: (_, state) => _buildTabPage(state, const CalendarPage()),
          ),
          GoRoute(
            path: AppRoutes.settings,
            // 【FEAT-243】`?openAccountLink=true` クエリパラメータでアカウント連携シート
            // を自動展開する経路を提供。ホーム上部バナー / GuestLinkPromptCard /
            // バックアップシート の 3 経路から共通動線で叩かれる。
            builder: (context, state) {
              final openAccountLink =
                  state.uri.queryParameters['openAccountLink'] == 'true';
              return SettingsPage(openAccountLink: openAccountLink);
            },
          ),
        ],
      ),
    ],
  );
}

// ─────────────────────────────────────────────────
// スプラッシュ（起動時の認証チェック → 画面振り分け）
// ─────────────────────────────────────────────────
class _SplashScreen extends ConsumerStatefulWidget {
  const _SplashScreen();

  @override
  ConsumerState<_SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends ConsumerState<_SplashScreen> {
  @override
  void initState() {
    super.initState();
    // フレーム描画後に認証チェック開始（context が有効になってから）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkAuth(context, ref);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.surface,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // 【FEAT-316】sabi_normal.png → sabi_unified.png に統一（PixelLab 92×92 ドット絵）。
            // Nearest Neighbor 補間でドット感維持。
            Image.asset(
              'assets/images/sabi/sabi_unified.webp',
              width:  120,
              height: 120,
              fit:    BoxFit.contain,
              filterQuality: FilterQuality.none,
            ),
            const SizedBox(height: 16),
            const Text(
              'Sabiowl',
              style: TextStyle(
                color:      Colors.white,
                fontSize:   28,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              AppLocalizations.of(context)!.coreSplashSubtitle,
              style: const TextStyle(color: Colors.white54, fontSize: 13),
            ),
            const SizedBox(height: 48),
            const SizedBox(
              width:  24,
              height: 24,
              child:  CircularProgressIndicator(
                strokeWidth: 2,
                color: AppTheme.primary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 認証チェックと最低 1.5 秒表示を並行実行して遷移先を決定する
  Future<void> _checkAuth(BuildContext context, WidgetRef ref) async {
    final results = await Future.wait([
      _performAuthCheck(ref),
      Future<void>.delayed(const Duration(milliseconds: 1500)),
    ]);
    if (!context.mounted) return;
    final destination = results[0] as String;
    context.go(destination);
  }

  /// 認証状態から遷移先パスを返す
  Future<String> _performAuthCheck(WidgetRef ref) async {
    final apiClient = ref.read(apiClientProvider);

    // A. 通常ユーザートークンあり → サーバー検証（24時間キャッシュ付き）
    //
    // ⚠️ 【FEAT-542】**ここでは設定完了を見ない。** 見ると、既存ユーザーが
    // 端末を替えた / 入れ直したときに `profile_setup_completed_for` が
    // 無いので**設定済みの人をオンボーディングへ送り、名前とキャラを
    // 上書きする** —— BUG-167 と同じ事故になる。
    // 🔵 ソーシャルの新規ユーザーは `justRegistered` で
    // `AuthPage._onAuthenticated` が設定へ送るので、この分岐は要らない。
    final token = await apiClient.getToken();
    if (token != null && token.isNotEmpty) {
      final isValid = await _validateTokenWithServer(ref, apiClient);
      return isValid ? AppRoutes.home : AppRoutes.login;
    }

    // B. FEAT-188: ゲストトークンあり → プロフィール設定の完了状況で分岐。
    // 【BUG (2026-07-02)】旧実装は無条件に home に飛ばしていたため、
    // OnboardingPage の途中で app を kill して再起動すると、名前 = 'ゲスト' +
    // active_character = null (fallback で zenon 画像) のまま home に到達
    // してしまう問題があった。未完了なら onboarding に戻して
    // 名前入力 + キャラ選択を確実に完了させる。
    //
    // 🔴 【FEAT-542 (2026-09-23)】判定を `has_seen_tutorial` から
    // `profile_setup_completed_for` に替えた。**持ち主を見る**ので、
    // 「古い設定済みを新しいゲストが引き継ぐ」経路が消える:
    //
    //   連携済みユーザーのトークンが消える -> 「ゲストとして始める」
    //   -> 新しいゲスト -> 設定の途中で kill -> 再起動
    //   -> 旧実装はフラグを見てホームへ（名前「ゲスト」+ キャラ未選択）
    //   -> 新実装は**持ち主が違う**ので「未設定」と読み、設定へ戻す
    //
    // ⚠️ **新順序では「トークンあり + 設定未完了」が通常の中間状態である。**
    //    ゲストは認証画面で `startAsGuest` を通ってからここへ来るので、
    //    旧順序より頻繁にこの分岐を通る。
    final guestToken = await apiClient.getGuestToken();
    if (guestToken != null && guestToken.isNotEmpty) {
      final setupDone = await apiClient.isProfileSetupCompleted();
      return setupDone ? AppRoutes.home : AppRoutes.onboarding;
    }

    // ⛔ 【FEAT-542】旧 case B'（`guest_mode` だけ立っていてトークンが無い）は
    //    削除した。**オンボーディングはもうトークンを作らない**ので、
    //    あそこへ送ると認証ヘッダー無しで `PATCH /player/` を叩いて 401 になる。
    //    フラグだけでは身元にならない —— 下の case C が認証画面へ送り、
    //    ユーザーに「サインインするか、新しく始めるか」を選ばせる。

    // C. 🔴 【BUG-166 (2026-09-12)】トークンが無ければ**必ず認証画面**へ。
    //
    // ## 旧実装は何をしていたか
    //
    // ```dart
    // final tutorialShown = await apiClient.hasTutorialBeenShown();
    // if (!tutorialShown) return AppRoutes.onboarding;   // ← これ
    // ```
    //
    // 🔴 **認証済みユーザーが再インストールすると、ここを通っていた。**
    // BUG-156 の掃除が `has_seen_tutorial` ごと消すので `tutorialShown` は
    // false になり、**オンボーディングへ送られていた**。
    //
    // ⚠️ さらに悪いことに、`OnboardingPage._complete()` は
    // 「トークンが無ければ `guest-init` を呼ぶ」ので、
    // **Google 連携済みのユーザーが再インストールしただけで
    // 「新しいゲスト」になっていた** —— 入力した名前とキャラの、
    // 習慣が 1 つも無いプロフィールに着く（dev 実機確認 2026-09-12）。
    //
    // 🔵 What's New の「既存ユーザーが一度だけログアウトされる」は
    // **ログイン画面が出る前提の文言**である。
    //
    // ## なぜ「認証画面へ」が正しいのか
    //
    // 🔴 **トークンが無いユーザーに必要なのは「サインインするか、
    // 新しく始めるか」の選択であり、それを提示できるのは認証画面だけである。**
    // オンボーディングは**黙ってゲストを作る**ので、選択の機会が無い。
    //
    // 🔵 保存先に依存しないのも利点である。`has_seen_tutorial` は
    // secure storage にあり、**iOS では再インストールで残るが Android では
    // 消える**。フラグの生存を当てにした分岐は**プラットフォームで挙動が
    // 分かれる**。
    //
    // ⚠️ **新規ユーザーの最初の画面が認証の選択になる。** 世界観を見せる前に
    // 決めさせる形なので、登録率が下がる方向に働く ——
    // **ユーザー判断 2026-09-12 で、払う価値があると確認済み**。
    // 🔵 チュートリアルを認証画面から開く形は FEAT-542 で作る。
    //
    // ⚠️ **case B の設定完了判定は残す。** あちらは
    // 「ゲストトークンはあるが設定が途中」の再開判定で、役目が別である。
    final registered = await apiClient.isRegistered();
    return registered ? AppRoutes.login : AppRoutes.register;
  }

  /// キャッシュ付きサーバートークン検証（24時間以内は再検証スキップ）
  Future<bool> _validateTokenWithServer(
      WidgetRef ref, ApiClient apiClient) async {
    const cacheHours = 24;

    // キャッシュチェック
    final lastValidated = await apiClient.getTokenValidatedAt();
    if (lastValidated != null) {
      final elapsed = DateTime.now().difference(lastValidated);
      if (elapsed.inHours < cacheHours) return true;
    }

    // サーバー検証
    try {
      await ref.read(apiClientProvider).dio.get('/player/');
      await apiClient.updateTokenValidatedAt();
      return true;
    } on DioException catch (e) {
      if (e.response?.statusCode == 401) {
        await apiClient.deleteToken();
        return false;
      }
      // ネットワークエラー / タイムアウト → オフライン判定・楽観的にホームへ
      return true;
    }
  }
}

// ── Nav Bar 高さ定数（FEAT-145 / FEAT-146 で参照）─────────────────────────────
// BUG-55: M3 デフォルト 80dp は上部に不自然な余白を生むため 60dp に調整。
// SafeArea でシステム padding を別途加算するため、この値はコンテンツ高さのみ。
const double kNavBarHeight = 60.0;

// ─────────────────────────────────────────────────
// 【2026-07-09 hotfix】BottomNav directional slide transition。
// ─────────────────────────────────────────────────
//
// 【症状】user 報告 (iOS): 「ホーム → チャレンジは右から画面が入って自然だが、
//         チャレンジ → ホームでも右から入って違和感」。
// 【原因】BottomNav 4 タブは全て context.go() で切替、GoRouter の default page
//         (iOS: CupertinoPage) は「常に右から左へ slide」の push/pop 用挙動を
//         使うため、tab index が減る方向 (右→左タブ) でも視覚的に右から入っていた。
// 【修正】tab index の増減方向を _pendingTabDirection に記録、pageBuilder が
//         SlideTransition で「index 増 = 右から (forward)」「index 減 = 左から
//         (backward)」の directional slide に切替。
//
// 適用対象: BottomNav 4 タブ (home / challenges / guild / calendar) のみ。
//   puzzleWorld / settings は BottomNav 対象外 = direction 概念が無いので
//   NoTransitionPage で default 遷移に落とす。
enum _TabSlideDirection { forward, backward, none }

/// 【状態】次に発火するタブ遷移の direction。
/// _ScaffoldWithBottomNav._onTap が set、_buildTabPage が read + consume する。
/// 起動時 / deep link / puzzleWorld 経由等の直接 URL 遷移は none のまま =
/// NoTransitionPage (=無方向、default 遷移) に落ちる。
_TabSlideDirection _pendingTabDirection = _TabSlideDirection.none;

/// BottomNav 4 タブ経路の pageBuilder helper。
///
/// _pendingTabDirection を consume して directional SlideTransition を返す。
/// direction=none (初回起動 / deep link 等) は NoTransitionPage で fallback。
///
/// 【アニメ設計】
///   - forward (index 増、ホーム → チャレンジ等): NEW page が右から (Offset(1,0)→(0,0))
///   - backward (index 減、チャレンジ → ホーム等): NEW page が左から (Offset(-1,0)→(0,0))
///   - 260ms + easeOutCubic (iOS CupertinoPage の 300ms より僅かに軽快感を優先)
Page<void> _buildTabPage(GoRouterState state, Widget child) {
  final direction = _pendingTabDirection;
  _pendingTabDirection = _TabSlideDirection.none;  // consume (1 回のみ有効)

  if (direction == _TabSlideDirection.none) {
    return NoTransitionPage<void>(key: state.pageKey, child: child);
  }

  final beginOffset = direction == _TabSlideDirection.forward
      ? const Offset(1.0, 0.0)   // 右から入場
      : const Offset(-1.0, 0.0); // 左から入場

  return CustomTransitionPage<void>(
    key: state.pageKey,
    child: child,
    transitionDuration: const Duration(milliseconds: 260),
    reverseTransitionDuration: const Duration(milliseconds: 260),
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      return SlideTransition(
        position: Tween<Offset>(
          begin: beginOffset,
          end: Offset.zero,
        ).chain(CurveTween(curve: Curves.easeOutCubic)).animate(animation),
        child: child,
      );
    },
  );
}

// BottomNavigationBar を持つシェル（FEAT-145: ブラー + スクロール連動表示/非表示）
class _ScaffoldWithBottomNav extends StatefulWidget {
  final Widget child;
  const _ScaffoldWithBottomNav({required this.child});

  @override
  State<_ScaffoldWithBottomNav> createState() => _ScaffoldWithBottomNavState();
}

class _ScaffoldWithBottomNavState extends State<_ScaffoldWithBottomNav> {
  bool   _navVisible      = true;
  double _downScrollAccum = 0;   // 下スクロール累積量（非表示判定用）
  double _upScrollAccum   = 0;   // 上スクロール累積量（表示判定用）

  // 表示・非表示の切り替え閾値（px）。
  // iOS の慣性スクロールで微小な delta が頻発するため、閾値を上げて
  // Android と同様の安定した操作感を実現する。
  // - 旧実装: 下は即時、上は 20px → iOS でチカチカ
  // - 新実装: 両方向とも 40px 累積で初めて切替
  static const double _toggleThreshold = 40.0;

  // 「ノイズ」とみなす delta の絶対値。iOS の bounce / overscroll で
  // ±1px 程度のブレが頻発するため、この値未満は無視する。
  static const double _minDeltaToCount = 2.0;

  // 【iOS NavBar Bounce Fix】画面上端からこの距離以内では常にナビ表示固定。
  // iOS の rubber-band overscroll に伴う spring-back で誤って「下スクロール」
  // 判定されることで、ナビが出現直後に引っ込む UX 不具合を防ぐ。
  // 50px は iOS NavigationBar の慣習値（Apple HIG「上端では常に visible」哲学）。
  static const double _topPinThreshold = 50.0;

  bool _onScrollNotification(ScrollNotification notification) {
    if (notification is ScrollUpdateNotification) {
      final metrics = notification.metrics;

      // 【iOS NavBar Bounce Fix】overscroll 領域（rubber-band bounce）では
      // state を変更しない。pixels < 0 は上端 bounce、> maxScrollExtent は
      // 下端 bounce。指を離した瞬間の spring-back が delta として誤検出され、
      // ナビが出現直後に引っ込む真因。
      if (metrics.pixels < 0 ||
          metrics.pixels > metrics.maxScrollExtent) {
        return false;
      }

      // 【iOS NavBar Bounce Fix】画面上端付近では常にナビ表示。
      // ヘッダー読書時のチカチカ防止 + Apple HIG「上端 visible」整合。
      if (metrics.pixels < _topPinThreshold && !_navVisible) {
        setState(() => _navVisible = true);
        _downScrollAccum = 0;
        _upScrollAccum   = 0;
        return false;
      }

      final delta = notification.scrollDelta ?? 0;

      // ノイズフィルタ: iOS bounce による微小揺れを無視
      if (delta.abs() < _minDeltaToCount) return false;

      if (delta > 0) {
        // 下スクロール: 累積して閾値超えたら非表示
        _upScrollAccum = 0;
        _downScrollAccum += delta;
        if (_downScrollAccum >= _toggleThreshold && _navVisible) {
          setState(() => _navVisible = false);
          _downScrollAccum = 0;
        }
      } else if (delta < 0) {
        // 上スクロール: 累積して閾値超えたら表示
        _downScrollAccum = 0;
        _upScrollAccum += delta.abs();
        if (_upScrollAccum >= _toggleThreshold && !_navVisible) {
          setState(() => _navVisible = true);
          _upScrollAccum = 0;
        }
      }
    } else if (notification is ScrollEndNotification) {
      // スクロール終了時に両方の累積をリセット
      _downScrollAccum = 0;
      _upScrollAccum   = 0;
    }
    return false;  // 通知を上位にも伝播させる
  }

  @override
  Widget build(BuildContext context) {
    final l10n          = AppLocalizations.of(context)!;
    final location      = GoRouterState.of(context).matchedLocation;
    final currentIndex  = _locationToIndex(location);
    final sysPadBottom  = MediaQuery.of(context).padding.bottom;

    // 【新規 (2026-07-05)】BottomNav の 4 タブ (ホーム / チャレンジ / ギルド /
    // カレンダー) では戻るボタン (Android システム back / iOS スワイプ back /
    // BackButton) を無効化し、アプリのホーム画面を経由せずに OS ホームへ抜ける
    // 導線を絞る。settings は同じ ShellRoute 内で push 経由到達のため通常の
    // 戻る動作 (settings → home) を維持したい → location 別に canPop を切替。
    //
    // 意図: 「習慣アプリを触っている流れの中で誤って OS ホームに戻ってしまう」
    // 事故を防ぐ (特に片手操作中の誤タップ)。OS ホームへ戻りたいユーザーは
    // ホームボタン / ジェスチャーで意図的に離脱する。
    final isMainTab = location == AppRoutes.home ||
        location == AppRoutes.challenges ||
        location == AppRoutes.guild ||
        location == AppRoutes.calendar;

    return PopScope(
      canPop: !isMainTab,
      child: Scaffold(
      // bottomNavigationBar は廃止し Stack で重ねる
      body: Stack(
        children: [
          // ── ① コンテンツ（bottom padding を nav bar 込みで上書き）─────
          MediaQuery(
            // 子ページが padding.bottom を参照するとき nav bar 高さ込みになるよう補正
            data: MediaQuery.of(context).copyWith(
              padding: MediaQuery.of(context).padding.copyWith(
                bottom: sysPadBottom + kNavBarHeight,
              ),
            ),
            child: NotificationListener<ScrollNotification>(
              onNotification: _onScrollNotification,
              child: widget.child,
            ),
          ),

          // ── ② ナビゲーションバー（ブラー + スライドアニメーション）────
          Positioned(
            left:   0,
            right:  0,
            bottom: 0,
            child: AnimatedSlide(
              duration: const Duration(milliseconds: 200),
              curve:    Curves.easeInOut,
              offset:   _navVisible ? Offset.zero : const Offset(0, 1),
              child: ClipRect(
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                  child: Container(
                    // 半透明の背景でブラーを生かす
                    color: const Color(0xFF1E1E2E).withValues(alpha: 0.75),
                    // BUG-55: SafeArea でシステムホームバー分の padding を加算。
                    // ブラー背景はホームバー領域も含めて全体を覆い、
                    // NavigationBar コンテンツはホームバー上に正しく配置される。
                    // BUG-57: M3 NavigationBar の内部 top padding（12dp / 60dp 中の 20%）は
                    // height や Theme で上書きできないため、Row + Column のカスタム実装に
                    // 置き換える。MainAxisAlignment.center で完全センタリング → 余白ゼロ。
                    child: SafeArea(
                      top: false,
                      child: SizedBox(
                        height: kNavBarHeight,
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceAround,
                          children: [
                            _buildNavItem(context, 0, Icons.home_outlined,           Icons.home,           l10n.coreNavHome,      currentIndex),
                            // 【FEAT-465 (2026-06-24)】月次カテゴリチャレンジ。ハンバーガー
                            // (FEAT-464) と異なる視覚として Icons.flag を採用。
                            _buildNavItem(context, 1, Icons.flag_outlined,          Icons.flag,           l10n.coreNavChallenge, currentIndex),
                            // 【FEAT-207】クエスト → ギルド（剣士の RPG 感を出す砦/城アイコン）
                            // ※ 指示書は `Icons.fort_awesome` を指定していたが標準 Material Icons
                            //   に存在せず、最も意図に近い `Icons.castle` / `Icons.castle_outlined`
                            //   に置換。font_awesome_flutter 導入時に `FontAwesomeIcons.fortAwesome`
                            //   への再差し替えを検討可。
                            // 【ユーザー判断 2026-05-31】badgeWrap で FEAT-311 ✓×N + FEAT-398 🔒
                            // バッジを城アイコンに付与。旧 AppBar の城アイコン (home_page.dart)
                            // から移動、UI 一貫性とスッキリさを両立。
                            _buildNavItem(
                              context, 2, Icons.castle_outlined, Icons.castle, l10n.coreNavGuild, currentIndex,
                              badgeWrap: (child) => Consumer(builder: (_, ref, __) {
                                final avail = ref.watch(battleAvailabilityProvider);
                                return Badge(
                                  // 【FEAT-409 (2026-06-01)】文字量過多解消。
                                  // 旧: 常時表示で「達成 N/3 → 次戦」(10 文字) が
                                  //     charges<3 のとき過剰占有していた
                                  // 新: charges>=3 (戦える) or 日次上限到達時のみ表示。
                                  //     最大「✓×3」or「🔒」の 3 文字で簡潔。
                                  //     進捗確認はギルド画面 subtext
                                  //     「あと N 回の習慣達成で出陣可能 🪶」が担う。
                                  isLabelVisible: avail.shouldShowBadge,
                                  label: Text(
                                    avail.badgeLabel,  // ✓×N / 🔒 (戦える時のみ)
                                    style: const TextStyle(fontSize: 10),
                                  ),
                                  backgroundColor: avail.dailyBattleLimitReached
                                      ? Colors.grey
                                      : avail.canBattle
                                          ? AppTheme.primary
                                          : Colors.orange,
                                  child: child,
                                );
                              }),
                            ),
                            _buildNavItem(context, 3, Icons.calendar_month_outlined, Icons.calendar_month, l10n.coreNavCalendar, currentIndex),
                            // 【FEAT-464 (2026-06-23)】マイページタブ削除、ハンバーガーメニュー
                            // (HomeDrawer) に動線集約。AppRoutes.settings 自体は維持し、
                            // ハンバーガー + 既存 ?openAccountLink=true クエリ経路から到達可能。
                            // 【FEAT-465 (2026-06-24)】チャレンジタブを 4 タブ目として追加済み。
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    ),  // Scaffold 終了
    );  // PopScope 終了
  }

  int _locationToIndex(String location) {
    // 【FEAT-465 (2026-06-24)】チャレンジタブ追加で 3 タブ → 4 タブ に再配線
    // (ホーム / チャレンジ / ギルド / カレンダー)。
    // `/settings` はハンバーガー経由になったため BottomNav インデックス対象外 (FEAT-464)。
    // `/shop` は ShellRoute 外（push 遷移）になったため、ここでは扱わない (SEC-12)。
    if (location.startsWith('/challenges')) return 1;  // FEAT-465
    if (location.startsWith('/guild'))      return 2;  // FEAT-207
    if (location.startsWith('/calendar'))   return 3;
    return 0;
  }

  // BUG-57: カスタムナビゲーションアイテム。
  // M3 NavigationBar の固定 top padding（12dp）を排除してアイコン＋ラベルを
  // 完全センタリングする。SizedBox(width: 64) で各タブ幅を固定し、
  // Row(spaceAround) と組み合わせて 5 タブを均等配置する。
  Widget _buildNavItem(
    BuildContext context,
    int index,
    IconData icon,
    IconData selectedIcon,
    String label,
    int currentIndex, {
    // 【ユーザー判断 2026-05-31】ギルドタブで FEAT-311 + FEAT-398 バッジを wrap する用。
    // null なら Icon そのまま、関数を渡すと Icon を Badge 等で包装可能。
    Widget Function(Widget child)? badgeWrap,
  }) {
    final isSelected = index == currentIndex;
    // 【FEAT-275】iOS では Safe Area (ホームインジケータ用 ~34px) が NavItem の
    // 下に存在するため、アイコンを center に置くと Safe Area との間に視覚的な
    // 「空き」が生まれて不自然に感じる。iOS のときだけ end alignment にして
    // アイコン+ラベルを NavItem の下端に寄せ、Safe Area のすぐ上に配置する。
    // Android はシステム UI (ボタン or ジェスチャバー) が Safe Area を埋める
    // ため center のままで違和感なし。
    final navItemAlignment = Platform.isIOS
        ? MainAxisAlignment.end
        : MainAxisAlignment.center;
    return GestureDetector(
      onTap: () => _onTap(context, index),
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: 64,
        height: kNavBarHeight,
        child: Column(
          mainAxisAlignment: navItemAlignment,
          children: [
            // 【ユーザー判断 2026-05-31】badgeWrap が指定されていれば Icon を Badge で包装。
            // ギルドタブで FEAT-311 (✓×N) + FEAT-398 (🔒) バッジを表示する用。
            badgeWrap != null
                ? badgeWrap(Icon(
                    isSelected ? selectedIcon : icon,
                    size:  22,
                    color: isSelected ? AppTheme.primary : Colors.white38,
                  ))
                : Icon(
                    isSelected ? selectedIcon : icon,
                    size:  22,
                    color: isSelected ? AppTheme.primary : Colors.white38,
                  ),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                fontSize:   10,
                color:      isSelected ? AppTheme.primary : Colors.white38,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
            // 【FEAT-291】FEAT-275 で iOS のラベル下に 6px breathing room を入れて
            // いたが、実機で「ボトムメニュー下にまだ余白がある」報告があり、iOS
            // ネイティブ TabBar (UIKit) と同じく「Safe Area すぐ上にラベル密着」
            // レイアウトに変更。Safe Area (~34px、ホームインジケータ) は HIG 上
            // 削除できないため、ここでの breathing room 撤去が UI 側で削れる
            // 最大の余白。さらに削るには kNavBarHeight 60 → 54 等の追加調整が必要。
          ],
        ),
      ),
    );
  }

  void _onTap(BuildContext context, int index) {
    // 【FEAT-465 (2026-06-24)】チャレンジタブ追加で 4 タブに再配線。
    // settings へはハンバーガー (HomeDrawer) 経由で到達 (FEAT-464)。
    //
    // 【2026-07-09 hotfix】BottomNav directional slide の direction を決定。
    // 現在の URL から currentIndex を算出、target index との大小関係で
    // forward (右のタブへ移動) / backward (左のタブへ移動) を決定、
    // _pendingTabDirection に set。_buildTabPage が pageBuilder 内で
    // consume して SlideTransition の方向を切替える。
    final currentLocation = GoRouterState.of(context).matchedLocation;
    final currentIndex    = _locationToIndex(currentLocation);
    if (index > currentIndex) {
      _pendingTabDirection = _TabSlideDirection.forward;
    } else if (index < currentIndex) {
      _pendingTabDirection = _TabSlideDirection.backward;
    } else {
      // 同一 index (再タップ、副次経路) は direction なし = NoTransitionPage
      _pendingTabDirection = _TabSlideDirection.none;
    }

    switch (index) {
      case 0: context.go(AppRoutes.home);
      case 1: context.go(AppRoutes.challenges);  // FEAT-465
      case 2: context.go(AppRoutes.guild);       // FEAT-207
      case 3: context.go(AppRoutes.calendar);
    }
  }
}

