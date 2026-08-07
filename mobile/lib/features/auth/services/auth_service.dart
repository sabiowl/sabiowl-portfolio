import 'package:dio/dio.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart'; // BUG-136: debugPrint
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';
import '../../../core/analytics/posthog_service.dart';  // FEAT-200
import '../../../core/api/api_client.dart';
import '../../../core/utils/apple_nonce.dart'; // H-04: Apple nonce

// ─────────────────────────────────────────────────────────────────────────────
// ソーシャル認証関連
// ─────────────────────────────────────────────────────────────────────────────

class SocialSignInCancelledException implements Exception {
  const SocialSignInCancelledException();
}

/// FEAT-189: ゲスト + 既存ユーザー衝突時のサーバー応答（HTTP 409）。
///
/// Flutter 側で「ゲストデータを破棄して既存アカウントに切り替えますか?」の
/// 確認ダイアログを出し、OK が押されたら `/api/auth/social/promote-confirm/`
/// に [mergeToken] を送って実際の切り替えを完了させる。
class GuestPromoteConflictException implements Exception {
  /// `/api/auth/social/promote-confirm/` に渡すマージトークン（10 分有効）。
  final String mergeToken;

  /// 既存ユーザーのプレイヤー名（ダイアログ表示用）。
  final String? existingUserName;

  /// 衝突したプロバイダ（'google' | 'apple'）。
  final String existingProvider;

  const GuestPromoteConflictException({
    required this.mergeToken,
    required this.existingProvider,
    this.existingUserName,
  });
}

class SocialAuthResult {
  /// DRF トークン（ログイン完了時に設定）
  final String token;

  /// 新規ユーザーで名前入力が必要
  final bool needsPlayerName;

  const SocialAuthResult({
    required this.token,
    this.needsPlayerName = false,
  });
}

/// FEAT-187: ゲストセッション初期化レスポンス。
class GuestInitResult {
  final String token;
  final int playerProfileId;
  final String playerName;

  const GuestInitResult({
    required this.token,
    required this.playerProfileId,
    required this.playerName,
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// AuthService
//
// FEAT-178: Magic Link / メール連携 / マージ確認のメソッドはすべて廃止。
// Google / Apple サインインのみを扱う。
// FEAT-187/188: ゲスト基盤がサーバー側に移行。GuestDataService 経由のローカル
// 移行 (`migrateGuestData`) は廃止し、`guestInit` + 社会的検証時の
// `guest_token` 同送で完結する。
// ─────────────────────────────────────────────────────────────────────────────

class AuthService {
  final ApiClient _apiClient;

  AuthService(this._apiClient);

  // ── ゲストセッション初期化（FEAT-187）─────────────────────────────────────

  /// POST /api/auth/guest-init/ を呼び、サーバー側のゲスト PlayerProfile +
  /// 既定習慣/タイムライン/ガチャチケット を生成。返ってきた token を
  /// `GuestToken <token>` 形式で以降の API 呼び出しに使う。
  Future<GuestInitResult> guestInit() async {
    final response = await _apiClient.dio.post('/auth/guest-init/');
    final data    = response.data as Map<String, dynamic>;
    final token   = data['token'] as String?;
    final profile = data['player_profile'] as Map<String, dynamic>? ?? {};
    if (token == null || token.isEmpty) {
      throw Exception('ゲストトークンの取得に失敗しました');
    }
    return GuestInitResult(
      token:           token,
      playerProfileId: (profile['id'] as int?) ?? 0,
      playerName:      (profile['name'] as String?) ?? 'ゲスト',
    );
  }

  // ── ソーシャル認証 ─────────────────────────────────────────────────────────

  /// Google サインイン → Firebase ID Token → Django 検証
  Future<SocialAuthResult> signInWithGoogle({String? playerName}) async {
    final googleUser = await GoogleSignIn().signIn();
    if (googleUser == null) throw const SocialSignInCancelledException();

    final googleAuth = await googleUser.authentication;
    final credential = GoogleAuthProvider.credential(
      accessToken: googleAuth.accessToken,
      idToken: googleAuth.idToken,
    );

    final userCredential =
        await FirebaseAuth.instance.signInWithCredential(credential);
    final idToken = await userCredential.user?.getIdToken();
    if (idToken == null) {
      throw Exception('Firebase ID トークンの取得に失敗しました');
    }

    return _verifySocialToken(idToken, 'google', playerName: playerName);
  }

  /// Apple サインイン → Firebase ID Token → Django 検証
  ///
  /// H-04: identityToken のリプレイ攻撃を防ぐため nonce 二段検証を実施。
  /// 生 nonce を SHA-256 ハッシュして Apple へ渡し、Firebase の OAuthProvider に
  /// 生 nonce を渡すことで identityToken の nonce クレームを検証する。
  Future<SocialAuthResult> signInWithApple({String? playerName}) async {
    // H-04: nonce ペアを生成（生 + ハッシュ済み）
    final noncePair = AppleNoncePair.generate();

    // 【FEAT-290】Apple サインインのキャンセル例外を Google 経路と同じ
    // SocialSignInCancelledException に正規化する。Apple は null 返却ではなく
    // `SignInWithAppleAuthorizationException(canceled)` を throw する仕様のため、
    // 何もしないと generic catch に落ちて「SignInWithAppleAuthorizationException
    // (AuthorizationErrorCode.canceled, ...)」というユーザーに無意味なエラーが
    // 露出する。生 e.toString() を SnackBar 表示する経路を遮断するための正規化。
    final AuthorizationCredentialAppleID appleCredential;
    try {
      appleCredential = await SignInWithApple.getAppleIDCredential(
        scopes: [
          AppleIDAuthorizationScopes.email,
          AppleIDAuthorizationScopes.fullName,
        ],
        nonce: noncePair.hashed, // ← ハッシュ済みを Apple へ
      );
    } on SignInWithAppleAuthorizationException catch (e) {
      if (e.code == AuthorizationErrorCode.canceled) {
        throw const SocialSignInCancelledException();
      }
      rethrow;
    }

    final oauthCredential = OAuthProvider('apple.com').credential(
      idToken:     appleCredential.identityToken,
      rawNonce:    noncePair.raw, // ← 生 nonce を Firebase へ
      accessToken: appleCredential.authorizationCode,
    );

    final userCredential =
        await FirebaseAuth.instance.signInWithCredential(oauthCredential);
    final idToken = await userCredential.user?.getIdToken();
    if (idToken == null) {
      throw Exception('Firebase ID トークンの取得に失敗しました');
    }

    return _verifySocialToken(idToken, 'apple', playerName: playerName);
  }

  /// Firebase ID トークンをバックエンドで検証して SocialAuthResult を返す。
  ///
  /// FEAT-188/189: ローカルにゲストトークンがあれば `guest_token` も同送する。
  ///   - 衝突なし（新規 or ゲスト昇格成功）→ 200 OK + token
  ///   - 既存ユーザー衝突 → 409 + merge_token を [GuestPromoteConflictException] で投げる
  Future<SocialAuthResult> _verifySocialToken(
    String idToken,
    String provider, {
    String? playerName,
  }) async {
    final guestToken = await _apiClient.getGuestToken();

    final body = <String, dynamic>{
      'id_token': idToken,
      'provider': provider,
    };
    if (guestToken != null && guestToken.isNotEmpty) {
      body['guest_token'] = guestToken;
    }
    if (playerName != null && playerName.isNotEmpty) {
      body['player_name'] = playerName;
    }

    final Response<dynamic> response;
    try {
      response = await _apiClient.dio.post('/auth/social/verify/', data: body);
    } on DioException catch (e) {
      // FEAT-189: 409 conflict_existing_user
      if (e.response?.statusCode == 409) {
        final data = e.response?.data;
        if (data is Map && data['status'] == 'conflict_existing_user') {
          final mergeToken = data['merge_token']?.toString();
          if (mergeToken == null || mergeToken.isEmpty) {
            throw Exception('マージトークンが返されませんでした');
          }
          throw GuestPromoteConflictException(
            mergeToken:       mergeToken,
            existingProvider: (data['existing_provider']?.toString() ?? provider),
            existingUserName: data['existing_user_name']?.toString(),
          );
        }
      }
      rethrow;
    }

    final responseStatus = response.data['status'] as String? ?? '';
    final token = response.data['token'] as String?;
    if (token == null) {
      throw Exception('予期しないレスポンス: $responseStatus');
    }
    switch (responseStatus) {
      case 'ok':
        return SocialAuthResult(token: token);
      case 'new_user':
        return SocialAuthResult(token: token, needsPlayerName: true);
      default:
        // FEAT-178: merge_required は完全廃止のため返らない。
        throw Exception('予期しないレスポンス: $responseStatus');
    }
  }

  /// FEAT-189: 衝突確認後にゲスト→既存ユーザー切替を確定する。
  /// `/api/auth/social/promote-confirm/` に merge_token を送ってトークンを取得。
  Future<String> confirmPromote(String mergeToken) async {
    final response = await _apiClient.dio.post(
      '/auth/social/promote-confirm/',
      data: {'merge_token': mergeToken},
    );
    final token = response.data['token'] as String?;
    if (token == null || token.isEmpty) {
      throw Exception('プロモート確定でトークンを取得できませんでした');
    }
    return token;
  }

  // ── その他 ────────────────────────────────────────────────────────────────

  /// ログアウト
  ///
  /// FEAT-195: Google Sign-In のネイティブキャッシュも明示的にクリアする。
  /// `FirebaseAuth.instance.signOut()` だけでは iOS Keychain / Android アカウント
  /// 情報に前回ユーザーのセッションが残り、再ログイン時に「アカウント選択画面が
  /// 出ずに前回ユーザーで自動復元される」現象が発生する。アカウント削除直後に
  /// この経路で「削除済みユーザー」として復元され、サーバー側 SocialAccount は
  /// 既に消えているため `/auth/social/verify/` が新規ユーザー作成フローに分岐し、
  /// UI 応答停止に至る致命的バグの原因だった。
  Future<void> logout() async {
    // ── 1. サーバー側にログアウト通知（失敗してもクライアント側は続行） ──
    try {
      await _apiClient.dio.post('/auth/logout/');
    } on DioException catch (_) {
      // サーバーエラーでもローカルのトークンは削除する
    }

    // ── 2. DRF トークン削除 ──
    await _apiClient.deleteToken();

    // ── 2.5. 【FEAT-200】PostHog 識別子クリア ──
    // 次回ログイン時に identify されるまで匿名状態。reset() は SDK 未初期化時は no-op。
    await PosthogService.instance.reset();

    // ── 3. Firebase サインアウト ──
    try {
      await FirebaseAuth.instance.signOut();
    } catch (_) {
      // 既にサインアウト済み等は無視
    }

    // ── 4. 【FEAT-195】Google Sign-In のネイティブキャッシュをクリア ──
    // signOut() でセッションをクリア、disconnect() で OAuth 認可も解除する。
    // 失敗（未サインイン状態など）は無視。
    try {
      final googleSignIn = GoogleSignIn();
      await googleSignIn.signOut();
      await googleSignIn.disconnect();
    } catch (_) {
      // 既にサインアウト済み / disconnect 不要な状態は無視
    }

    // ── 5. Apple Sign-In ──
    // sign_in_with_apple パッケージは明示的な signOut API を提供していない。
    // Firebase Auth の signOut で十分なため、ここでは追加処理なし。
    // 将来 SDK が拡張された場合のフックポイントとしてこのコメントを残す。
  }

  /// 【BUG-129 (2026-06-14)】社会的アカウント連携を解除し、新ゲストトークンを取得する。
  /// 誤連携 (間違ったアカウントで連携してしまった) の救済経路。
  ///
  /// フロー:
  ///   1. Backend `POST /api/auth/social/unlink/` → 新ゲストトークン取得
  ///      (Backend で User CASCADE 削除 + PlayerProfile detach + GuestSession 発行 +
  ///       Firebase Auth user 削除 best-effort)
  ///   2. PostHog identity reset
  ///   3. Firebase Auth signOut (ネイティブセッションクリア、Backend で user 削除済)
  ///   4. Google Sign-In signOut + disconnect (next sign-in で再選択強制)
  ///
  /// データ (Habit/Timeline/Gacha 等) は Backend で保持される。caller (auth_provider)
  /// は受け取った guest token を保存 + ユーザートークン削除 + provider 一斉 invalidate
  /// を実行する。
  ///
  /// Returns: 新ゲストトークン (Backend が発行)
  Future<String> unlinkSocialAccount() async {
    // 1. Backend で連携解除
    final response = await _apiClient.dio.post('/auth/social/unlink/');
    final guestToken = response.data['token'] as String?;
    if (guestToken == null || guestToken.isEmpty) {
      throw Exception('Backend returned empty guest token');
    }

    // 2. PostHog identity reset
    // 【BUG-136 (2026-06-17)】try/catch でラップ。Backend 解除完了後の best-effort
    // 操作で例外を投げると、ユーザーには「失敗」と誤認されるため吸収する。
    // 旧バグ: PostHog SDK の初期化未完了 / ネットワーク不調で例外 →
    // auth_provider catch → SnackBar「うまくいきませんでした」誤表示 +
    // Sheet が閉じない、という症状になっていた。
    try {
      await PosthogService.instance.reset();
    } catch (e) {
      debugPrint('[Auth.unlinkSocialAccount] PostHog reset failed: $e');
    }

    // 3. Firebase Auth signOut (Backend で user 削除済、ネイティブセッションクリア)
    try {
      await FirebaseAuth.instance.signOut();
    } catch (_) {/* 既にサインアウト済み等は無視 */}

    // 4. Google Sign-In signOut + disconnect (next sign-in で再選択強制)
    try {
      final googleSignIn = GoogleSignIn();
      await googleSignIn.signOut();
      await googleSignIn.disconnect();
    } catch (_) {/* 未サインイン状態等は無視 */}

    return guestToken;
  }

  /// 開発用：ワンタップログイン（DEBUG ビルド専用）
  Future<String> devLogin() async {
    final response = await _apiClient.dio.post('/auth/dev-login/');
    final authToken = response.data['token'] as String?;
    if (authToken == null) throw Exception('開発用トークンの取得に失敗しました');
    return authToken;
  }

  /// 保存済みトークンがあるか確認
  Future<bool> hasToken() async {
    final token = await _apiClient.getToken();
    return token != null && token.isNotEmpty;
  }

  /// 登録済みかどうかを確認する
  Future<bool> isRegistered() async {
    return _apiClient.isRegistered();
  }

  /// 登録済みフラグを保存する
  Future<void> markAsRegistered() async {
    await _apiClient.markAsRegistered();
  }
}
