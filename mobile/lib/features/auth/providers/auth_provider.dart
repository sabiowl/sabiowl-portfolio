import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import '../../../core/analytics/posthog_service.dart';  // FEAT-200
import '../../../core/api/api_client.dart';
import '../../../core/cache/cache_service.dart';  // FEAT-280
import '../../../core/providers/account_suspension_provider.dart';  // 【FEAT-541】
// 【BUG-83 (2026-06-10)】logout / セッション失効時の provider 一斉 invalidate 用。
import '../../battle/providers/battle_provider.dart';
import '../../calendar/providers/calendar_provider.dart';
import '../../habits/providers/habits_provider.dart';
import '../../habits/providers/home_bootstrap_provider.dart';
import '../../sabi/providers/sabi_provider.dart';
import '../../social/providers/social_provider.dart';
import '../services/auth_service.dart';
import '../../../core/l10n/service_l10n.dart';  // 【FEAT-489 Phase 2F-a】

part 'auth_provider.g.dart';

// AuthService プロバイダー
@riverpod
AuthService authService(Ref ref) {
  final apiClient = ref.watch(apiClientProvider);
  return AuthService(apiClient);
}

// 認証状態
//
// FEAT-178: Magic Link / メールマージは完全廃止。
// needsMerge / mergeToken / magicLinkSent も削除。
enum AuthStatus {
  checking,
  authenticated,
  unauthenticated,
  // 【FEAT-238】`needsPlayerName` enum 値は FEAT-232 で未使用化したのち、
  // 全コードベースで参照ゼロ確認の上、本 FEAT で物理削除。
  // ソーシャル新規ユーザーは `_handleSocialResult` で直接 `authenticated` +
  // `justRegistered=true` に遷移し、OnboardingPage で name + gender + character を
  // 一括処理する設計。PostHog 計測は `SocialAuthResult.needsPlayerName`(bool)
  // を経由しており本 enum 値とは無関係。
}

class AuthState {
  final AuthStatus status;
  final String? error;
  final bool isLoading;
  /// BUG-01: 401 によるセッション失効が発生したか。
  /// true のとき GoRouter の redirect が `/auth/login` へ強制遷移し、
  /// AuthPage が SnackBar 表示後に [Auth.clearSessionExpired] を呼ぶ。
  /// 手動ログアウトでは false のまま（個別画面の context.go に任せる）。
  final bool sessionExpired;
  /// BUG-48: ソーシャルサインインがキャンセル/失敗したことを AuthPage に伝えるフラグ。
  /// AuthPage の ref.listen で検知して SnackBar を表示後、
  /// [Auth.clearSocialCancelled] でリセットする。
  final bool socialSignInCancelled;
  /// FEAT-178: 直近のソーシャル認証が新規ユーザーだったか。
  /// AuthPage が authenticated を観測したタイミングで参照し、
  /// 新規なら /onboarding、既存なら /home へ遷移分岐するために使う。
  final bool justRegistered;
  /// FEAT-189: ゲスト→既存ユーザー衝突発生時の merge_token。
  /// AuthPage が検知して確認ダイアログを表示、確定時に
  /// [Auth.confirmPromote] を呼ぶ。
  final String? pendingPromoteMergeToken;
  /// FEAT-189: 衝突相手の既存プレイヤー名（ダイアログ表示用）
  final String? pendingPromoteExistingName;
  /// FEAT-189: 衝突相手のプロバイダ（ダイアログ表示用）
  final String? pendingPromoteProvider;

  const AuthState({
    this.status = AuthStatus.checking,
    this.error,
    this.isLoading = false,
    this.sessionExpired = false,
    this.socialSignInCancelled = false,
    this.justRegistered = false,
    this.pendingPromoteMergeToken,
    this.pendingPromoteExistingName,
    this.pendingPromoteProvider,
  });

  AuthState copyWith({
    AuthStatus? status,
    String? error,
    bool? isLoading,
    bool? sessionExpired,
    bool? socialSignInCancelled,
    bool? justRegistered,
    String? pendingPromoteMergeToken,
    String? pendingPromoteExistingName,
    String? pendingPromoteProvider,
    bool clearError = false,
    bool clearPromote = false,
  }) {
    return AuthState(
      status: status ?? this.status,
      error: clearError ? null : (error ?? this.error),
      isLoading: isLoading ?? this.isLoading,
      sessionExpired: sessionExpired ?? this.sessionExpired,
      socialSignInCancelled:
          socialSignInCancelled ?? this.socialSignInCancelled,
      justRegistered: justRegistered ?? this.justRegistered,
      pendingPromoteMergeToken: clearPromote
          ? null
          : (pendingPromoteMergeToken ?? this.pendingPromoteMergeToken),
      pendingPromoteExistingName: clearPromote
          ? null
          : (pendingPromoteExistingName ?? this.pendingPromoteExistingName),
      pendingPromoteProvider: clearPromote
          ? null
          : (pendingPromoteProvider ?? this.pendingPromoteProvider),
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is AuthState &&
        other.status == status &&
        other.error == error &&
        other.isLoading == isLoading &&
        other.sessionExpired == sessionExpired &&
        other.socialSignInCancelled == socialSignInCancelled &&
        other.justRegistered == justRegistered &&
        other.pendingPromoteMergeToken == pendingPromoteMergeToken &&
        other.pendingPromoteExistingName == pendingPromoteExistingName &&
        other.pendingPromoteProvider == pendingPromoteProvider;
  }

  @override
  int get hashCode => Object.hash(
        status,
        error,
        isLoading,
        sessionExpired,
        socialSignInCancelled,
        justRegistered,
        pendingPromoteMergeToken,
        pendingPromoteExistingName,
        pendingPromoteProvider,
      );
}

@riverpod
class Auth extends _$Auth {
  @override
  AuthState build() {
    _checkInitialAuth();
    return const AuthState();
  }

  AuthService get _service => ref.read(authServiceProvider);
  ApiClient get _apiClient => ref.read(apiClientProvider);

  // ── 起動時確認 ──────────────────────────────────────────────────────────

  Future<void> _checkInitialAuth() async {
    final hasUserToken  = await _service.hasToken();
    final hasGuestToken = (await _apiClient.getGuestToken())?.isNotEmpty ?? false;
    state = state.copyWith(
      status: (hasUserToken || hasGuestToken)
          ? AuthStatus.authenticated
          : AuthStatus.unauthenticated,
    );
  }

  // ⛔ 【FEAT-542 (2026-09-23)】`refreshAuthStatus()` は削除した。
  //
  // BUG-161 の応急処置で、「オンボーディングが `authProvider` の外で
  // トークンを作ったあと、状態を追いつかせる」ためのものだった。
  //
  // 🔵 **本 FEAT でその迂回が無くなった。** オンボーディングは
  // トークンを作らず、ゲストは `startAsGuest()` を通ってから来る ——
  // **追いつかせるべき遅れが存在しない。**
  //
  // ⚠️ 「一応残しておく」を選ばないこと。読み手のいない再判定は、
  // 次の誰かが「ここでも呼んでおけば安全だろう」と迂回を足す口実になる。
  // 不変条件は `test/onboarding_lands_on_home_test.dart` が
  // 「`authProvider` の外でトークンを作っている箇所」の走査で縛っている。

  /// ゲストとして開始する（FEAT-128 / FEAT-188）。
  ///
  /// `/api/auth/guest-init/` を呼んでサーバー側でゲスト PlayerProfile を
  /// 作成 + ゲストトークンを取得し、ApiClient に保存する。
  /// すでにゲストトークンがあるなら再発行はしない（冪等）。
  ///
  /// 【BUG-127 (2026-06-14)】「リンク済アカウント → ログアウト → ゲストモード」遷移で
  /// home / guild 画面に旧アカウント情報が一瞬表示されるバグの構造解消。
  /// logout でも cache/provider はクリアされるが、Riverpod AsyncValue が `previous` で
  /// 旧 data を保持するため、guest 切替時にも防御的に `clearForPlayerSwitch` +
  /// `_invalidateAllPlayerScopedProviders()` を呼ぶ。`_finalizeSocialAuth` と同パターン。
  Future<void> startAsGuest() async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final existing = await _apiClient.getGuestToken();
      int? identifiedPlayerId;
      // 【BUG (2026-07-02)】既存ゲストトークン持ちで再度この経路を通る場合
      // (再ログイン等)、onboarding を再表示すべきかは tutorial 済判定に委ねる
      // 必要があるため、freshInit フラグで「今回 guestInit を新規に呼んだか」
      // を捕捉する。true のときだけ justRegistered=true にセットして
      // AuthPage の ref.listen 経路で onboarding へ飛ばす。
      final freshInit = existing == null || existing.isEmpty;
      if (freshInit) {
        // 【BUG-127】guestInit 前に cache を全削除 (旧アカウントの home_bootstrap 等が
        // SWR の初期 yield で表示される race を排除)。saveGuestToken 前に実行する。
        try {
          await ref.read(cacheServiceProvider).clearForPlayerSwitch();
        } catch (e) {
          debugPrint('[Auth.startAsGuest] cache clear failed: $e');
        }
        // 【BUG-127】Google カレンダー予定本文の端末内 SQLite も他人データ混入防止のため削除。
        try {
          await ref.read(localGoogleEventStoreProvider).clearAll();
        } catch (e) {
          debugPrint('[Auth.startAsGuest] LocalGoogleEventStore clear failed: $e');
        }
        final result = await _service.guestInit();
        await _apiClient.saveGuestToken(result.token);
        identifiedPlayerId = result.playerProfileId;
      }
      await _setGuestMode(true);
      // 【BUG-127】player-scoped Riverpod provider を一斉 invalidate。
      // logout でも invalidate されるが、AsyncValue.previous で旧 data が露見する race を
      // 構造的に遮断する (BUG-83 と同パターン)。
      _invalidateAllPlayerScopedProviders();
      // FEAT-200: ゲストセッション識別 + イベント送信
      if (identifiedPlayerId != null && identifiedPlayerId > 0) {
        await PosthogService.instance.identify(identifiedPlayerId, isGuest: true);
      }
      await PosthogService.instance.capture('guest_session_started');
      // 【BUG (2026-07-02)】新規ゲストは必ず OnboardingPage を通す。
      // 旧実装は justRegistered を設定せず false のままだったため、
      // AuthPage の ref.listen が `_onAuthenticated(isNewUser: false)` を発火し
      // 同フレーム内の `context.go(AppRoutes.home)` が `_onGuestStart` 側の
      // `context.go(AppRoutes.onboarding)` を race で無効化していた。
      // 結果: onboarding が表示されず name PATCH + character select が走らない
      // → 名前 = 'ゲスト' (guest-init 初期値)、active_character = null
      //   (fallback で zenon 画像) のまま home 到達、というバグ。
      // Social 新規ユーザーと同じ挙動 (justRegistered=true → ref.listen 経由で
      // onboarding 遷移) に統一することで race を構造的に解消する。
      // 既存ゲストトークン持ち (再ログイン等) は onboarding 経由不要のため
      // freshInit=false のときは justRegistered をセットしない (home へ)。
      state = state.copyWith(
        isLoading: false,
        status: AuthStatus.authenticated,
        justRegistered: freshInit,
      );
    } catch (e) {
      state = state.copyWith(isLoading: false, error: _parseError(e));
    }
  }

  // ── ゲストモードフラグ切り替えヘルパー ─────────────────────────────────
  //
  // ApiClient.setGuestMode は SharedPreferences への永続化を行うが、
  // isGuestModeProvider は FutureProvider.autoDispose<bool> でキャッシュを
  // 保持しているため、ここで明示的に invalidate しないと「ゲスト切り替え直後に
  // 古い値（false）が返り、…」という整合性バグが発生する。
  Future<void> _setGuestMode(bool value) async {
    await _apiClient.setGuestMode(value);
    ref.invalidate(isGuestModeProvider);
  }

  // ── ソーシャル認証 ──────────────────────────────────────────────────────

  Future<void> googleSignIn() async {
    state = state.copyWith(isLoading: true, clearError: true);
    // FEAT-200: サインイン試行をトラッキング（成功/キャンセル/失敗のファネル分析用）
    await PosthogService.instance.capture('social_signin_started', properties: {
      'provider': 'google',
    });
    try {
      final result = await _service.signInWithGoogle();
      await _handleSocialResult(result, provider: 'google');
    } on SocialSignInCancelledException {
      // BUG-48: キャンセル/サイレント失敗を AuthPage の SnackBar で通知する。
      state = state.copyWith(isLoading: false, socialSignInCancelled: true);
    } on GuestPromoteConflictException catch (e) {
      // FEAT-189: 衝突発生 → AuthPage が確認ダイアログを表示
      // FEAT-200: 衝突発生をトラッキング（連携完了率の母数分析用）
      await PosthogService.instance.capture('account_link_conflict', properties: {
        'provider': e.existingProvider,
      });
      state = state.copyWith(
        isLoading: false,
        pendingPromoteMergeToken:   e.mergeToken,
        pendingPromoteExistingName: e.existingUserName,
        pendingPromoteProvider:     e.existingProvider,
      );
    } catch (e) {
      state = state.copyWith(isLoading: false, error: _parseError(e));
    }
  }

  Future<void> appleSignIn() async {
    state = state.copyWith(isLoading: true, clearError: true);
    // FEAT-200: サインイン試行をトラッキング
    await PosthogService.instance.capture('social_signin_started', properties: {
      'provider': 'apple',
    });
    try {
      final result = await _service.signInWithApple();
      await _handleSocialResult(result, provider: 'apple');
    } on SocialSignInCancelledException {
      // BUG-48: キャンセル/サイレント失敗を AuthPage の SnackBar で通知する。
      state = state.copyWith(isLoading: false, socialSignInCancelled: true);
    } on GuestPromoteConflictException catch (e) {
      // FEAT-200: 衝突発生をトラッキング
      await PosthogService.instance.capture('account_link_conflict', properties: {
        'provider': e.existingProvider,
      });
      state = state.copyWith(
        isLoading: false,
        pendingPromoteMergeToken:   e.mergeToken,
        pendingPromoteExistingName: e.existingUserName,
        pendingPromoteProvider:     e.existingProvider,
      );
    } catch (e) {
      state = state.copyWith(isLoading: false, error: _parseError(e));
    }
  }

  Future<void> _handleSocialResult(
    SocialAuthResult result, {
    required String provider,
  }) async {
    // 【FEAT-280 Pre-mortem #2】ゲスト → 正式ユーザー昇格時、旧ゲストキャッシュを
    // 完全削除してから新ユーザー token を保存する（他人データ混入防止）。
    // saveToken の前に削除することで、削除中に旧 token で発火する API 呼び出しが
    // 旧データを cache に再書き込みする race を防ぐ。
    try {
      await ref.read(cacheServiceProvider).clearForPlayerSwitch();
    } catch (e) {
      debugPrint('[Auth._finalizeSocialAuth] cache clear failed: $e');
    }
    await _apiClient.saveToken(result.token);
    await _apiClient.markAsRegistered();
    // FEAT-188: ゲスト→正式ユーザー昇格が成功したらゲストトークンは破棄
    await _apiClient.deleteGuestToken();
    // FEAT-185: ヘルパー経由で setGuestMode + invalidate(isGuestModeProvider)
    await _setGuestMode(false);

    // FEAT-200: サインイン完了をトラッキング。新規ユーザーは `needsPlayerName` で判定。
    // 識別子 (player_id) の identify は次回 PlayerNotifier.build() で発火する
    // （fetchPlayer 完了後に確定するため、ここでは未送信）。
    await PosthogService.instance.capture('social_signin_completed', properties: {
      'provider':    provider,
      'is_new_user': result.needsPlayerName,
    });

    // 【FEAT-232】name sheet を廃止し OnboardingPage で名前入力を一本化。
    // 旧実装は `needsPlayerName` ステータスを経由して auth_page の name sheet を
    // 表示していたが、Render コールドスタート時に setPlayerName API の patch 待ちと
    // sheet dismiss の whenComplete が race して認証が誤って取り消される
    // 問題（freeze）があった。新規ユーザーは直接 `authenticated` + `justRegistered=true`
    // にして、OnboardingPage（既に name PATCH + character select + 設定済みフラグ
    // を完結する仕様）に委譲する。auth_page の `_onAuthenticated` 経路で
    // `justRegistered=true` なら `/onboarding` に遷移する。
    state = state.copyWith(
      isLoading: false,
      status: AuthStatus.authenticated,
      justRegistered: result.needsPlayerName,
    );
  }

  /// FEAT-189: 衝突ダイアログで「既存アカウントに切り替える」を選んだ場合。
  /// `/api/auth/social/promote-confirm/` で merge_token を確定 → DRF トークン取得。
  /// ゲストデータは backend で CASCADE 削除される。
  Future<void> confirmPromote() async {
    final token = state.pendingPromoteMergeToken;
    if (token == null || token.isEmpty) return;

    final provider = state.pendingPromoteProvider ?? '';
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final authToken = await _service.confirmPromote(token);
      await _apiClient.saveToken(authToken);
      await _apiClient.markAsRegistered();
      await _apiClient.deleteGuestToken();
      await _setGuestMode(false);
      // FEAT-200: 衝突確定 → 既存ユーザー側に合流した時点で連携完了とみなす。
      // PlayerNotifier の次回 build で identify が走り、既存ユーザーの distinct_id に切り替わる。
      await PosthogService.instance.capture('account_link_completed', properties: {
        if (provider.isNotEmpty) 'provider': provider,
        'via_conflict': true,
      });
      state = state.copyWith(
        isLoading: false,
        status: AuthStatus.authenticated,
        clearPromote: true,
      );
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: _parseError(e),
        clearPromote: true,
      );
    }
  }

  /// FEAT-189: 衝突ダイアログで「キャンセル（ゲストを保持）」を選んだ場合。
  /// 何もせず pending 状態だけクリア。
  void cancelPromote() {
    state = state.copyWith(clearPromote: true);
  }

  // 【FEAT-232 で削除】`setPlayerName` メソッドは name sheet 廃止に伴い不要化。
  // 新規ユーザーの名前入力は OnboardingPage._complete() 内の `/player/` PATCH で
  // 一本化されたため、本ヘルパーは呼び出し元ゼロでクリーンアップ。

  /// ソーシャル認証をキャンセルして未認証状態に戻す
  void cancelSocialSignIn() {
    state = const AuthState(status: AuthStatus.unauthenticated);
  }

  /// FEAT-178: 遷移処理後に justRegistered フラグをクリアする。
  void clearJustRegistered() {
    if (!state.justRegistered) return;
    state = state.copyWith(justRegistered: false);
  }

  // ── ログアウト ──────────────────────────────────────────────────────────

  Future<void> logout() async {
    await _service.logout();
    // 【FEAT-280 Pre-mortem #2】他人データ混入を防ぐためサインアウト時に全キャッシュ削除。
    // best-effort（ネットワーク不要、SharedPreferences のみで完結）。
    // 失敗してもログアウト自体は完了させる。
    try {
      await ref.read(cacheServiceProvider).clearForPlayerSwitch();
    } catch (e) {
      debugPrint('[Auth.logout] cache clear failed: $e');
    }
    // 【FEAT-426】Google カレンダー予定本文の端末内 SQLite も他人データ混入防止のため削除。
    try {
      await ref.read(localGoogleEventStoreProvider).clearAll();
    } catch (e) {
      debugPrint('[Auth.logout] LocalGoogleEventStore clear failed: $e');
    }
    // 【BUG-83 (2026-06-10)】Riverpod NotifierProvider の in-memory state を強制 reset。
    // cacheServiceProvider は SharedPreferences 層のみクリアするが、Provider state は
    // invalidate しない限り別アカウントログイン後も生存し続けるため、ホーム画面に
    // 直結する player-scoped provider をすべて明示的に dispose する。
    // 🔴 【FEAT-541 (2026-09-06)】アカウント停止フラグを必ず下ろす。
    //
    // 消し忘れると**ログイン画面の上に停止 overlay が乗ったまま**になり、
    // ログインボタンが押せなくなる —— **この機能で一番起きやすい詰み方**である。
    // overlay 側ではなく**ここ**に置くのは、設定画面のログアウトも
    // セッション失効も同じ経路を通るため (出口を 1 つにする)。
    ref.read(accountSuspendedProvider.notifier).clear();
    _invalidateAllPlayerScopedProviders();
    state = const AuthState(status: AuthStatus.unauthenticated);
  }

  /// 【BUG-129 (2026-06-14)】社会的アカウント連携を解除し、ゲストモードに戻す。
  /// 誤連携 (間違ったアカウントで連携してしまった) の救済経路。
  ///
  /// フロー:
  ///   1. `_service.unlinkSocialAccount()` で Backend + Firebase/Google ネイティブ清掃 →
  ///      新ゲストトークン取得
  ///   2. cache + LocalGoogleEventStore を全削除 (BUG-127 と同パターン)
  ///   3. ユーザートークン削除 + 新ゲストトークン保存 + guest mode = true
  ///   4. player-scoped Provider 一斉 invalidate (BUG-83 と同パターン)
  ///   5. state = authenticated (ゲストモード) → caller 側で SnackBar 表示
  ///
  /// データ (Habit/Timeline/Gacha 等) は保持される。ユーザーは正しい Google/Apple
  /// アカウントで再連携することで別アカウントに紐付け直せる。
  Future<void> unlinkSocialAccount() async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      // 1. Backend 連携解除 + Firebase/Google ネイティブ清掃 (auth_service に集約)
      final guestToken = await _service.unlinkSocialAccount();

      // 2. キャッシュ + ローカル DB を全削除 (旧アカウント残留防止、BUG-127 同パターン)
      try {
        await ref.read(cacheServiceProvider).clearForPlayerSwitch();
      } catch (e) {
        debugPrint('[Auth.unlinkSocialAccount] cache clear failed: $e');
      }
      try {
        await ref.read(localGoogleEventStoreProvider).clearAll();
      } catch (e) {
        debugPrint('[Auth.unlinkSocialAccount] LocalGoogleEventStore clear failed: $e');
      }

      // 3. トークン切替: ユーザー → 新ゲスト
      await _apiClient.deleteToken();
      await _apiClient.saveGuestToken(guestToken);
      await _setGuestMode(true);

      // 4. 全 player-scoped Provider を invalidate (BUG-83 同パターン)
      _invalidateAllPlayerScopedProviders();

      // 【BUG-136 (2026-06-17)】PostHog capture を try/catch でラップ。
      // Backend 解除完了 + Mobile token 切替成功後の best-effort 計測なので、
      // 失敗しても unlink 全体は成功扱いにする。旧バグ: PostHog 例外で全体失敗扱い
      // → 設定画面に「うまくいきませんでした」誤表示 + Sheet 閉じない、という症状。
      try {
        await PosthogService.instance.capture('social_account_unlinked');
      } catch (e) {
        debugPrint('[Auth.unlinkSocialAccount] PostHog capture failed: $e');
      }

      state = state.copyWith(
        isLoading: false,
        status: AuthStatus.authenticated,
      );
    } catch (e) {
      state = state.copyWith(isLoading: false, error: _parseError(e));
      rethrow;
    }
  }

  /// 【BUG-83 (2026-06-10)】player-scoped Riverpod provider を一斉 invalidate するヘルパー。
  ///
  /// logout / markSessionExpired から呼ぶ。autoDispose の効きはホーム画面が
  /// dispose されるタイミングに依存するため、ログイン跨ぎで state が引き継がれる
  /// ケース (= 前アカウント情報が表示される真因) を構造的に遮断する。
  ///
  /// **新規追加時の運用ルール**: player-scoped な Notifier / FutureProvider を新規追加
  /// したら、本リストにも対応する `ref.invalidate(...)` を必ず追加すること。
  void _invalidateAllPlayerScopedProviders() {
    // ── Habits / Player ──────────────────────────────────────────────
    ref.invalidate(playerNotifierProvider);
    ref.invalidate(habitsNotifierProvider);
    ref.invalidate(habitsSummaryProvider);
    ref.invalidate(archivedHabitsNotifierProvider);
    // homeBootstrapRawProvider は StreamProvider + ref.keepAlive() で autoDispose
    // 不可 = invalidate しない限り永続生存 = 旧アカウント情報残留の主犯。
    ref.invalidate(homeBootstrapRawProvider);
    // ── Calendar ────────────────────────────────────────────────────
    ref.invalidate(calendarHeatmapProvider);
    ref.invalidate(streakDataProvider);
    // ── Sabi (ホーム / SnackBar / 通知の "アプリの声") ───────────────
    ref.invalidate(sabiMessageProvider);
    // 【FEAT-484】bootstrap 注入キャッシュもリセット (旧ユーザーのメッセージ残留防止)
    ref.read(bootstrapSabiMessageProvider.notifier).state = null;
    // ── Social (friend / notifications) ─────────────────────────────
    ref.invalidate(friendListProvider);
    ref.invalidate(incomingRequestsProvider);
    ref.invalidate(notificationsProvider);
    // ── Battle ──────────────────────────────────────────────────────
    ref.invalidate(battleSessionProvider);
  }

  // ── BUG-01: 401 によるセッション失効検知 ─────────────────────────────────
  //
  // ApiClient の onError インターセプターから呼ばれる。
  // GoRouter の redirect は sessionExpired==true の間だけ /auth/login へ
  // 強制遷移する。AuthPage が SnackBar を表示した直後に
  // [clearSessionExpired] を呼んで再表示を防ぐ。
  void markSessionExpired() {
    // すでに失効通知中ならノーオペ（多重 401 で SnackBar が重ならないように）
    if (state.sessionExpired) return;
    // 【FEAT-280 Pre-mortem #2】セッション失効も実質的にアカウント切替の起点になり得る
    // （別ユーザーが同一端末で次にサインインするケース）。fire-and-forget で
    // キャッシュ削除（失敗しても session expired 状態遷移は止めない）。
    Future(() async {
      try {
        await ref.read(cacheServiceProvider).clearForPlayerSwitch();
      } catch (e) {
        debugPrint('[Auth.markSessionExpired] cache clear failed: $e');
      }
      // 【FEAT-426】Google カレンダー予定本文の端末内 SQLite も他人データ混入防止のため削除。
      try {
        await ref.read(localGoogleEventStoreProvider).clearAll();
      } catch (e) {
        debugPrint('[Auth.markSessionExpired] LocalGoogleEventStore clear failed: $e');
      }
    });
    // 【BUG-83 (2026-06-10)】logout 経路と同じく Riverpod provider state も強制 reset。
    // セッション失効後に別ユーザーがサインインするケースで、前ユーザーの provider state
    // が残らないことを保証する。fire-and-forget の cache clear と異なり、invalidate は
    // 同期実行で OK (Riverpod の dispose スケジューリングが面倒を見る)。
    // 🔴 【FEAT-541 (2026-09-06)】アカウント停止フラグを必ず下ろす。
    //
    // 消し忘れると**ログイン画面の上に停止 overlay が乗ったまま**になり、
    // ログインボタンが押せなくなる —— **この機能で一番起きやすい詰み方**である。
    // overlay 側ではなく**ここ**に置くのは、設定画面のログアウトも
    // セッション失効も同じ経路を通るため (出口を 1 つにする)。
    ref.read(accountSuspendedProvider.notifier).clear();
    _invalidateAllPlayerScopedProviders();
    state = state.copyWith(
      status: AuthStatus.unauthenticated,
      sessionExpired: true,
      isLoading: false,
      clearError: true,
    );
  }

  void clearSessionExpired() {
    if (!state.sessionExpired) return;
    state = state.copyWith(sessionExpired: false);
  }

  // BUG-48: ソーシャルサインインキャンセル通知のクリア。
  // AuthPage が SnackBar を出した直後に呼ぶ。
  void clearSocialCancelled() {
    if (!state.socialSignInCancelled) return;
    state = state.copyWith(socialSignInCancelled: false);
  }

  // ── 開発用 ────────────────────────────────────────────────────────────

  Future<void> devLogin() async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final authToken = await _service.devLogin();
      await _apiClient.saveToken(authToken);
      await _apiClient.markAsRegistered();
      // FEAT-188: ゲストトークンが残っていれば削除
      await _apiClient.deleteGuestToken();
      // 🔵 【FEAT-542】`markTutorialShown()` の後継。⚠️ **ゲストトークンを
      //    消したあとに呼ぶ** —— 持ち主はユーザートークン側である。
      await _apiClient.markProfileSetupCompleted();
      // FEAT-185: ヘルパー経由で setGuestMode + invalidate(isGuestModeProvider)
      await _setGuestMode(false);
      state = state.copyWith(
        isLoading: false,
        status: AuthStatus.authenticated,
      );
    } catch (e) {
      state = state.copyWith(isLoading: false, error: _parseError(e));
    }
  }

  // ── エラー解析 ─────────────────────────────────────────────────────────

  String _parseError(Object e) {
    final msg = e.toString();
    if (msg.contains('timeout') || msg.contains('Timeout')) {
      return ServiceL10n.current.authErrorServerWaking;
    }
    if (msg.contains('connection') || msg.contains('XMLHttpRequest')) {
      return ServiceL10n.current.authErrorNoConnectionSabi_message;
    }
    if (kDebugMode) return '[debug] $msg';
    return ServiceL10n.current.authErrorGenericSabi_message;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// ゲストモードプロバイダー
// ─────────────────────────────────────────────────────────────────────────────

/// ゲストモード中かどうかを返す FutureProvider。
final isGuestModeProvider = FutureProvider.autoDispose<bool>((ref) {
  return ref.watch(apiClientProvider).isGuestMode();
});
