import 'package:dio/dio.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';
import '../../../core/analytics/posthog_service.dart';  // FEAT-200
import '../../../core/api/api_client.dart';
import '../../../core/utils/apple_nonce.dart'; // H-04: Apple nonce
import '../../auth/services/auth_service.dart';        // FEAT-189: GuestPromoteConflictException
import '../../../core/l10n/service_l10n.dart';  // 【FEAT-489 Phase 2F-a】

class SettingsService {
  final ApiClient _apiClient;
  SettingsService(this._apiClient);

  /// プロフィール更新 (name / gender)
  Future<void> updateProfile({String? name, String? gender}) async {
    final data = <String, dynamic>{};
    if (name != null) data['name'] = name;
    if (gender != null) data['gender'] = gender;
    await _apiClient.dio.patch('/player/', data: data);
  }

  /// 【FEAT-396 (2026-05-31)】updatePrivacy 廃止 (プライバシー設定 UI 削除に伴う)。
  /// Backend `FriendProfileSerializer` で「習慣内容は常に非公開、継続日数は常に公開」
  /// 固定挙動に変更済のため、ユーザー設定経路自体が不要。
  /// Backend `PATCH /api/player/ {all_private: bool}` 経路は dead 化 (削除しない)。

  /// アカウント削除（理由フィードバック付き）
  Future<void> deleteAccount({
    required String reason,
    String reasonText = '',
    String appVersion = '',
  }) async {
    await _apiClient.dio.delete('/player/', data: {
      'reason':      reason,
      'reason_text': reasonText,
      'app_version': appVersion,
    });
  }

  /// 【BUG-129 (2026-06-14)】社会的アカウント連携を解除し、ゲストモードに戻す。
  /// 誤連携 (間違ったアカウントで連携してしまった) の救済経路。
  /// データは保持され、新しいゲストトークンが返る。
  /// レスポンス: {token, player_profile_id}
  Future<Map<String, dynamic>> unlinkSocialAccount() async {
    final res = await _apiClient.dio.post('/auth/social/unlink/');
    return res.data as Map<String, dynamic>;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 連携状態データクラス（FEAT-178: メール連携廃止）
// ─────────────────────────────────────────────────────────────────────────────

class LinkedAccountInfo {
  final bool isLinked;
  /// 連携プロバイダーから取得したメールアドレス。連絡先用途のみ。
  final String? email;

  const LinkedAccountInfo({required this.isLinked, required this.email});

  factory LinkedAccountInfo.fromJson(Map<String, dynamic> json) {
    return LinkedAccountInfo(
      isLinked: json['is_linked'] as bool? ?? false,
      email:    json['email']     as String?,
    );
  }

  static const empty = LinkedAccountInfo(isLinked: false, email: null);
}

class LinkedAccounts {
  final LinkedAccountInfo google;
  final LinkedAccountInfo apple;

  const LinkedAccounts({required this.google, required this.apple});

  bool get hasAnyLink => google.isLinked || apple.isLinked;

  factory LinkedAccounts.fromJson(Map<String, dynamic> json) {
    LinkedAccountInfo parseEntry(Object? v) {
      if (v is Map) {
        return LinkedAccountInfo.fromJson(v.cast<String, dynamic>());
      }
      return LinkedAccountInfo.empty;
    }

    return LinkedAccounts(
      google: parseEntry(json['google']),
      apple:  parseEntry(json['apple']),
    );
  }

  /// FEAT-183: ゲスト時の 401 を「未連携」として扱うためのフォールバック値。
  /// `linkedAccountsProvider` が DioException(401) を捕捉した際に返す。
  static const empty = LinkedAccounts(
    google: LinkedAccountInfo.empty,
    apple:  LinkedAccountInfo.empty,
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// 連携キャンセル/失敗の例外（FEAT-178）
// ─────────────────────────────────────────────────────────────────────────────

class SocialLinkCancelledException implements Exception {
  const SocialLinkCancelledException();
}

/// FEAT-178: 既に別プロバイダで連携済みのため新規プロバイダ連携を拒否された場合。
class AlreadyLinkedOtherProviderException implements Exception {
  /// 現在連携中のプロバイダ ('google' | 'apple')
  final String currentProvider;
  final String message;
  const AlreadyLinkedOtherProviderException({
    required this.currentProvider,
    required this.message,
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// アカウント連携メソッド（extension）
// FEAT-178: メール連携・連携解除・切り替えは廃止。Google/Apple のみ。
// ─────────────────────────────────────────────────────────────────────────────

extension AccountLinkService on SettingsService {

  /// 現在の連携状態を取得
  Future<LinkedAccounts> fetchLinkedAccounts() async {
    final response = await _apiClient.dio.get('/auth/social/accounts/');
    return LinkedAccounts.fromJson(response.data as Map<String, dynamic>);
  }

  /// Google アカウントを連携する。キャンセル時は [SocialLinkCancelledException] を throw。
  ///
  /// FEAT-183: ゲスト時は `/auth/social/verify/`（新規ユーザー作成 or 既存ログイン）
  /// を経由してゲスト→正式ユーザー化する。認証済みなら従来通り `/auth/social/link/`
  /// で追加連携する。
  Future<void> linkWithGoogle() async {
    // 既存セッションが残っているとアカウント選択が出ないため一旦サインアウト
    // FEAT-200: アカウント連携開始イベント
    await PosthogService.instance.capture('account_link_started', properties: {
      'provider': 'google',
    });
    try { await GoogleSignIn().signOut(); } catch (_) {}
    final googleUser = await GoogleSignIn().signIn();
    if (googleUser == null) throw const SocialLinkCancelledException();

    final googleAuth = await googleUser.authentication;
    final credential = GoogleAuthProvider.credential(
      accessToken: googleAuth.accessToken,
      idToken:     googleAuth.idToken,
    );
    final userCredential =
        await FirebaseAuth.instance.signInWithCredential(credential);
    final idToken = await userCredential.user?.getIdToken();
    if (idToken == null) throw Exception('Firebase ID トークンの取得に失敗しました');

    final isGuest = await _apiClient.isGuestMode();
    if (isGuest) {
      await _verifyAndPromoteGuest(idToken, 'google');
    } else {
      await _callLinkEndpoint(idToken, 'google');
    }
    // FEAT-200: 連携完了（衝突なし、または通常リンク経路）
    await PosthogService.instance.capture('account_link_completed', properties: {
      'provider':     'google',
      'via_conflict': false,
    });
  }

  /// Apple アカウントを連携する（iOS のみ呼び出すこと）。キャンセル時は [SocialLinkCancelledException] を throw。
  ///
  /// FEAT-183: ゲスト時は Google と同様に `/auth/social/verify/` 経由でユーザー昇格する。
  /// H-04: identityToken のリプレイ攻撃を防ぐため nonce 二段検証を実施。
  Future<void> linkWithApple() async {
    // FEAT-200: アカウント連携開始イベント
    await PosthogService.instance.capture('account_link_started', properties: {
      'provider': 'apple',
    });
    // H-04: nonce ペアを生成（auth_service.signInWithApple と同方式）
    final noncePair = AppleNoncePair.generate();

    // 【FEAT-290】Apple サインインのキャンセル例外を Google 経路と同じ
    // SocialLinkCancelledException に正規化する。Apple は null 返却ではなく
    // `SignInWithAppleAuthorizationException(canceled)` を throw する仕様のため、
    // 何もしないと generic catch に落ちて「SignInWithAppleAuthorizationException
    // (AuthorizationErrorCode.canceled, ...)」というユーザーに無意味なエラー文が
    // SnackBar に露出する（iOS 実機でユーザー報告あり）。
    final AuthorizationCredentialAppleID appleCredential;
    try {
      appleCredential = await SignInWithApple.getAppleIDCredential(
        scopes: [AppleIDAuthorizationScopes.email],
        nonce: noncePair.hashed, // ← ハッシュ済みを Apple へ
      );
    } on SignInWithAppleAuthorizationException catch (e) {
      if (e.code == AuthorizationErrorCode.canceled) {
        throw const SocialLinkCancelledException();
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
    if (idToken == null) throw Exception('Firebase ID トークンの取得に失敗しました');

    final isGuest = await _apiClient.isGuestMode();
    if (isGuest) {
      await _verifyAndPromoteGuest(idToken, 'apple');
    } else {
      await _callLinkEndpoint(idToken, 'apple');
    }
    // FEAT-200: 連携完了（衝突なし、または通常リンク経路）
    await PosthogService.instance.capture('account_link_completed', properties: {
      'provider':     'apple',
      'via_conflict': false,
    });
  }

  /// FEAT-188/189: ゲストモード中のユーザーを正式ユーザーへ昇格させる。
  ///
  /// フロー:
  ///   1. `/auth/social/verify/` にゲストトークンと一緒に id_token を送信
  ///   2. 200 OK → ゲスト PlayerProfile に user 紐付け済み。DRF トークン受領 →
  ///      ApiClient へ保存 + ゲストトークン削除 + guest_mode フラグ解除
  ///   3. 409 conflict_existing_user → [GuestPromoteConflictException] を投げる。
  ///      上位（UI）で確認ダイアログを出し、確定したら `confirmPromote` を呼ぶ。
  ///
  /// ローカルへのゲストデータシード／移行 API はサーバー基盤化により廃止。
  Future<void> _verifyAndPromoteGuest(String idToken, String provider) async {
    final guestToken = await _apiClient.getGuestToken();

    final body = <String, dynamic>{
      'id_token': idToken,
      'provider': provider,
    };
    if (guestToken != null && guestToken.isNotEmpty) {
      body['guest_token'] = guestToken;
    }

    final Response<dynamic> response;
    try {
      response = await _apiClient.dio.post(
        '/auth/social/verify/',
        data: body,
      );
    } on DioException catch (e) {
      // FEAT-189: ゲスト + 既存ユーザー衝突 → UI に確認ダイアログを出させる
      if (e.response?.statusCode == 409) {
        final data = e.response?.data;
        if (data is Map && data['status'] == 'conflict_existing_user') {
          final mergeToken = data['merge_token']?.toString();
          if (mergeToken != null && mergeToken.isNotEmpty) {
            throw GuestPromoteConflictException(
              mergeToken:       mergeToken,
              existingProvider: (data['existing_provider']?.toString() ?? provider),
              existingUserName: data['existing_user_name']?.toString(),
            );
          }
        }
      }
      final body2 = e.response?.data;
      final msg = (body2 is Map) ? body2['error']?.toString() : null;
      throw Exception(msg ?? e.message ?? 'サーバー認証に失敗しました');
    }

    final data = response.data;
    if (data is! Map) {
      throw Exception('サーバー応答の形式が不正です');
    }
    final token = (data['token'] as String?)?.trim();
    if (token == null || token.isEmpty) {
      throw Exception('サーバーからトークンを取得できませんでした');
    }

    // ── トークン保存 + ゲストトークン破棄 + ゲストモード解除 ──
    await _apiClient.saveToken(token);
    await _apiClient.deleteGuestToken();
    await _apiClient.setGuestMode(false);
  }

  /// FEAT-189: 衝突確認後にゲスト→既存ユーザー切替を確定する。
  /// `/api/auth/social/promote-confirm/` を呼んでトークン取得 → ApiClient 保存。
  Future<void> confirmPromote(String mergeToken) async {
    final Response<dynamic> response;
    try {
      response = await _apiClient.dio.post(
        '/auth/social/promote-confirm/',
        data: {'merge_token': mergeToken},
      );
    } on DioException catch (e) {
      final body = e.response?.data;
      final msg = (body is Map) ? body['error']?.toString() : null;
      throw Exception(msg ?? e.message ?? 'プロモート確定に失敗しました');
    }
    final data = response.data;
    if (data is! Map) throw Exception('サーバー応答の形式が不正です');
    final token = (data['token'] as String?)?.trim();
    if (token == null || token.isEmpty) {
      throw Exception('サーバーからトークンを取得できませんでした');
    }
    await _apiClient.saveToken(token);
    await _apiClient.deleteGuestToken();
    await _apiClient.setGuestMode(false);
  }

  /// ソーシャルリンクエンドポイント共通呼び出し
  Future<void> _callLinkEndpoint(String idToken, String provider) async {
    try {
      final response = await _apiClient.dio.post(
        '/auth/social/link/',
        data: {'id_token': idToken, 'provider': provider},
      );
      final resStatus = response.data['status'] as String? ?? '';
      if (resStatus == 'already_linked') return; // 同一ユーザーに連携済みは正常扱い
      if (resStatus != 'linked') {
        throw Exception(response.data['error'] ?? '連携に失敗しました');
      }
    } on DioException catch (e) {
      // FEAT-178: 1 ユーザー 1 プロバイダ制約違反 (409)
      if (e.response?.statusCode == 409) {
        final body = e.response?.data;
        if (body is Map && body['code'] == 'already_linked_other_provider') {
          final current = body['current_provider']?.toString() ?? 'google';
          final msg = body['error']?.toString() ??
              ServiceL10n.current.settingsErrorAlreadyLinkedOtherProvider;
          throw AlreadyLinkedOtherProviderException(
            currentProvider: current,
            message: msg,
          );
        }
      }
      final body = e.response?.data;
      String? backendMessage;
      if (body is Map) {
        backendMessage = body['error']?.toString() ?? body['status']?.toString();
      }
      throw Exception(backendMessage ?? e.message ?? '不明なエラー');
    }
  }
}
