import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../shared/widgets/guest_promote_conflict_dialog.dart';  // 【2026-07-02】
import '../../../shared/widgets/sabi_loading_skeleton.dart';  // FEAT-202
import '../providers/auth_provider.dart';
import '../widgets/social_sign_in_button.dart';
import '../../../l10n/app_localizations.dart';

// ── 開発用フラグ ──────────────────────────────────────────────────────────────
/// 起動時に認証画面をスキップして devLogin を自動実行するか。
///
/// 【SEC-13 H-13】 hardcoded `true` を `bool.fromEnvironment` 駆動に変更。
/// デフォルトは `false` のため、誤って release ビルドで `kDebugMode` を
/// 残したまま配布しても devLogin 経路は走らない。
///
/// 開発時の有効化:
///   flutter run --dart-define=DEV_AUTH_SKIP=true
///
/// FEAT-200 (PostHog API キー注入) と同じ `--dart-define` ベースの設計で、
/// CI / release ビルドの引数に含めない限り無効化される。
const bool _kDevAuthSkipEnabled = bool.fromEnvironment(
  'DEV_AUTH_SKIP',
  defaultValue: false,
);
// ─────────────────────────────────────────────────────────────────────────────

// FEAT-178: Magic Link / メール連携 / マージ確認シートを完全撤去。
// Google / Apple サインインのみのシンプルなフローへ刷新。

class AuthPage extends ConsumerStatefulWidget {
  const AuthPage({super.key});

  @override
  ConsumerState<AuthPage> createState() => _AuthPageState();
}

class _AuthPageState extends ConsumerState<AuthPage> {
  // 【FEAT-232】`_nameSheetShown` フラグは name sheet 廃止に伴い削除。

  /// BUG-01: セッション切れ SnackBar を 1 度だけ出すための再入防止フラグ
  bool _sessionSnackbarHandled = false;

  @override
  void initState() {
    super.initState();
    if (kDebugMode && _kDevAuthSkipEnabled) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        // BUG-46: ログアウト後（status == unauthenticated）は自動ログインしない。
        // コールドスタート時のみ（status == checking）自動実行する。
        if (ref.read(authProvider).status == AuthStatus.checking) {
          ref.read(authProvider.notifier).devLogin();
        }
      });
    }
  }

  // ── 認証成功時の遷移分岐（FEAT-178）─────────────────────────────────────
  void _onAuthenticated({required bool isNewUser}) {
    if (!mounted) return;
    ref.read(authProvider.notifier).clearJustRegistered();
    // 新規 → オンボーディング（FEAT-102）
    // 既存 → ホーム
    context.go(isNewUser ? AppRoutes.onboarding : AppRoutes.home);
  }

  // 【FEAT-232】`_showNameSheet` / `_submitName` は完全削除。
  // 旧実装は新規ソーシャルユーザー向けの名前入力シートだったが、Render コールドスタート時に
  // `setPlayerName` API の patch 待ちと sheet dismiss の `whenComplete` が race して
  // 認証が誤って取り消される問題（freeze）があった。`_handleSocialResult` で
  // 直接 `authenticated` + `justRegistered=true` にして OnboardingPage の
  // `_complete()` で name + gender + character + 設定済みフラグを一括処理する
  // 設計に統一（ゲスト / Google / Apple の 3 経路を OnboardingPage 単一エントリへ集約）。
  //
  // 🔵 【FEAT-542 (2026-09-23)】**その集約がようやく例外なしになった。**
  // スプラッシュから直接オンボーディングへ行く経路（= 黙ってゲストを作る経路）が
  // 消え、**3 経路すべてが「認証 → プロフィール設定 → ホーム」の順**になった。

  // ── FEAT-189: ゲスト→既存ユーザー衝突確認ダイアログ ───────────────────────
  // 【2026-07-02】旧実装 (~70 LOC の inline AlertDialog) を GuestPromoteConflictDialog
  // widget に抽出。同文言が settings_page.dart にも独立実装されており、赤字強調の
  // 同期漏れが発生した反省から共通化。今後の文言変更は widget 側 1 箇所で完結する。
  Future<void> _showPromoteConfirmDialog(AuthState s) async {
    final ok = await GuestPromoteConflictDialog.show(
      context: context,
      existingProvider: s.pendingPromoteProvider,
      existingUserName: s.pendingPromoteExistingName,
    );
    if (!mounted) return;
    if (ok) {
      await ref.read(authProvider.notifier).confirmPromote();
    } else {
      ref.read(authProvider.notifier).cancelPromote();
    }
  }

  // ── ビルド ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final authState = ref.watch(authProvider);

    // BUG-01: GoRouter の redirect で /auth/login に飛ばされたら
    // 「セッションが切れました」SnackBar を 1 度だけ表示し、フラグをクリア。
    if (authState.sessionExpired && !_sessionSnackbarHandled) {
      _sessionSnackbarHandled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.authPageSessionExpiredSnackbarSabi_message),
            backgroundColor: AppTheme.primary,
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 4),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
        );
        ref.read(authProvider.notifier).clearSessionExpired();
      });
    }

    ref.listen(authProvider, (prev, next) {
      // 認証完了 → 新規/既存で遷移分岐
      if (next.status == AuthStatus.authenticated &&
          prev?.status != AuthStatus.authenticated) {
        _onAuthenticated(isNewUser: next.justRegistered);
      }

      // 【FEAT-232】name sheet 経路は廃止。新規ソーシャルユーザーは
      // `_handleSocialResult` で直接 `authenticated` + `justRegistered=true` になり、
      // 上の `next.status == AuthStatus.authenticated` 分岐から
      // `_onAuthenticated(isNewUser: true)` 経由で OnboardingPage に遷移する。

      // FEAT-189: ゲスト + 既存ユーザー衝突 → 確認ダイアログを表示
      if (next.pendingPromoteMergeToken != null &&
          prev?.pendingPromoteMergeToken == null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _showPromoteConfirmDialog(next);
        });
      }

      // BUG-48: ソーシャルサインインキャンセル/失敗の SnackBar 通知
      if (next.socialSignInCancelled &&
          !(prev?.socialSignInCancelled ?? false)) {
        ref.read(authProvider.notifier).clearSocialCancelled();
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          ScaffoldMessenger.of(context)
            ..clearSnackBars()
            ..showSnackBar(
              SnackBar(
                content: Text(l10n.authPageSignInCancelledSnackbarSabi_message),
                behavior: SnackBarBehavior.floating,
                duration: const Duration(milliseconds: 2000),
              ),
            );
        });
      }

      // 【FEAT-232】`_nameSheetShown` フラグは削除済み、リセット処理も不要。
    });

    // 開発用スキップ中はローディングのみ（コールドスタート時のみ）
    if (kDebugMode && _kDevAuthSkipEnabled &&
        authState.status == AuthStatus.checking) {
      // 【FEAT-202】Render コールドスタート 30〜60 秒の沈黙を「サビが寄り添う温度」に保つ。
      // 旧実装の `CircularProgressIndicator` 単独は世界観をロードフェーズだけ放棄していた。
      return Scaffold(
        body: SabiWaitingPanel(
          message: l10n.authPageLoadingSabi_message,
        ),
      );
    }

    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 40),
              _buildHeader(l10n),
              const SizedBox(height: 40),
              if (authState.error != null) _buildErrorBanner(authState.error!),
              _buildLoginButtons(authState, l10n),
              const SizedBox(height: 40),
            ],
          ),
        ),
      ),
    );
  }

  // ── ウィジェット ──────────────────────────────────────────────────────────

  Widget _buildHeader(AppLocalizations l10n) {
    return Column(
      children: [
        // 【FEAT-243】Material 汎用アイコン (Icons.auto_stories) を Sabi のドット絵に置換。
        // 新規ユーザーの最初の対峙が「アプリのマスコットの顔そのもの」になる視覚的同一化。
        //
        // 【FEAT-320 (2026-05-27)】sabi_dot_6464.png → sabi_unified.png に統一。
        // FEAT-316 でアプリ全体のサビ画像を sabi_unified.png に集約済 (SabiEmotion
        // 10 種類 + sabi_loading_skeleton + app_router splash) のため、唯一残っていた
        // AuthPage も同画像に統一。sabi_dot_6464.png は launcher icon (Android/iOS
        // アプリアイコン) として引き続き必要なため pubspec / asset は維持。
        //
        // グラデーション背景は errorBuilder フォールバック時の保険 + sabi_unified.png
        // 背景透明部分のネイビー枠装飾として有効。BoxFit.contain でフクロウ本体が
        // 中央配置され、周りにグラデネイビー枠が見える設計に変更。
        Container(
          width: 80,
          height: 80,
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [AppTheme.primary, AppTheme.secondary],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(20),
          ),
          child: ClipRRect(
            // Container の borderRadius と一致させて画像の角を綺麗に丸める
            borderRadius: BorderRadius.circular(20),
            child: Image.asset(
              'assets/images/sabi/sabi_unified.webp',
              fit: BoxFit.contain,  // フクロウ本体を 80x80 内に中央配置 (gradient 枠を活かす)
              // ピクセルアートはバイリニア補間を無効化してドット感を保つ（FEAT-224 と同パターン）
              filterQuality: FilterQuality.none,
              // アセット読み込み失敗時のフォールバック（グラデ枠が見える状態）
              errorBuilder: (_, __, ___) =>
                  const Icon(Icons.auto_stories, size: 40, color: Colors.white),
            ),
          ),
        ),
        const SizedBox(height: 24),
        Text(
          l10n.appTitle,
          style: const TextStyle(
            fontSize: 32,
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          l10n.authPageTagline,
          style: TextStyle(
            fontSize: 14,
            color: Colors.white.withValues(alpha: 0.7),
          ),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  /// Google / Apple サインインボタン群 + ゲストリンク（FEAT-178）。
  Widget _buildLoginButtons(AuthState authState, AppLocalizations l10n) {
    final loading = authState.isLoading;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ── Google ─────────────────────────────────────────────────────
        SocialSignInButton(
          icon: const GoogleLogoIcon(),
          label: l10n.authPageGoogleButton,
          isLoading: loading,
          onPressed: _onGoogleSignIn,
        ),
        const SizedBox(height: 12),

        // ── Apple（iOS のみ）───────────────────────────────────────────
        if (defaultTargetPlatform == TargetPlatform.iOS) ...[
          SocialSignInButton(
            icon: const AppleLogoIcon(),
            label: l10n.authPageAppleButton,
            isLoading: loading,
            onPressed: _onAppleSignIn,
            backgroundColor: Colors.black,
          ),
          const SizedBox(height: 12),
        ],

        // ── Divider ─────────────────────────────────────────────────
        const SizedBox(height: 24),
        _buildDivider(l10n),
        const SizedBox(height: 16),

        // ── ゲストとして始める ───────────────────────────────────
        TextButton(
          onPressed: loading ? null : _onGuestStart,
          style: TextButton.styleFrom(
            foregroundColor: Colors.white.withValues(alpha: 0.45),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize:      MainAxisSize.min,
            children: [
              Text(
                l10n.authPageGuestButton,
                style: const TextStyle(fontSize: 13),
              ),
              const SizedBox(width: 4),
              const Icon(Icons.arrow_forward_ios, size: 12),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildDivider(AppLocalizations l10n) {
    return Row(
      children: [
        Expanded(child: Divider(color: Colors.white.withValues(alpha: 0.15))),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            l10n.authPageDividerOr,
            style: TextStyle(
              fontSize: 13,
              color: Colors.white.withValues(alpha: 0.4),
            ),
          ),
        ),
        Expanded(child: Divider(color: Colors.white.withValues(alpha: 0.15))),
      ],
    );
  }

  Widget _buildErrorBanner(String error) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.red.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.red.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline, color: Colors.red, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              error,
              style: const TextStyle(color: Colors.red, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  // ── アクション ────────────────────────────────────────────────────────────

  Future<void> _onGoogleSignIn() async {
    await ref.read(authProvider.notifier).googleSignIn();
  }

  Future<void> _onAppleSignIn() async {
    await ref.read(authProvider.notifier).appleSignIn();
  }

  Future<void> _onGuestStart() async {
    // FEAT-190: ゲスト起動失敗時に SnackBar で通知し、ホーム遷移をブロック。
    try {
      await ref.read(authProvider.notifier).startAsGuest();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context)!.authPageGuestStartErrorSnackbarSabi_message),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    // 【BUG (2026-07-02)】旧実装はここで `context.go(AppRoutes.onboarding)` を
    // 明示していたが、直前の startAsGuest() 内で state.status=authenticated が
    // set されると同フレームで ref.listen(authProvider) が発火し、
    // `_onAuthenticated(isNewUser: next.justRegistered)` が走る。
    // 旧 startAsGuest は justRegistered を設定していなかったため
    // (デフォルト false) `context.go(AppRoutes.home)` が発火し、直後の
    // `context.go(AppRoutes.onboarding)` と race して onboarding をスキップ
    // → 名前 = 'ゲスト' + キャラ画像 = zenon (fallback) のまま home 到達。
    // 新実装は startAsGuest 側で justRegistered=true をセットするため
    // ref.listen 経路が onboarding へ確実に飛ばす (Social 新規と同一経路)。
    // ここでの追加の go は二重処理になるため削除。
  }
}
