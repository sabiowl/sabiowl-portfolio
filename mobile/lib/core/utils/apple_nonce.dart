import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// H-04: Apple Sign-in のリプレイ攻撃対策に使う nonce 生成ヘルパー。
///
/// Apple のドキュメント・Firebase Auth の Apple OAuth プロバイダ仕様に従い、
/// 「**生 nonce を SHA-256 でハッシュした値**を `getAppleIDCredential(nonce:)` に渡し、
/// 同じ**生 nonce** を `OAuthProvider('apple.com').credential(rawNonce:)` に渡す」
/// 二段構成で、Apple が返す identityToken の `nonce` クレームを Firebase が検証する。
///
/// 参考:
///   - https://firebase.google.com/docs/auth/flutter/federated-auth#apple
///   - https://developer.apple.com/documentation/authenticationservices/asauthorizationappleidrequest/3175423-nonce
///
/// 使い方:
/// ```dart
/// final pair = AppleNoncePair.generate();
/// final cred = await SignInWithApple.getAppleIDCredential(
///   scopes: [...],
///   nonce: pair.hashed,        // ← ハッシュ済み（base16）
/// );
/// final oauth = OAuthProvider('apple.com').credential(
///   idToken:  cred.identityToken,
///   rawNonce: pair.raw,        // ← 生 nonce
///   accessToken: cred.authorizationCode,
/// );
/// ```
class AppleNoncePair {
  /// Apple へ送る生 nonce（Firebase の `rawNonce` にも同じ値を渡す）。
  final String raw;

  /// 生 nonce を SHA-256 でハッシュした 16 進文字列（`getAppleIDCredential(nonce:)` 用）。
  final String hashed;

  const AppleNoncePair({required this.raw, required this.hashed});

  /// 暗号論的に安全な乱数で nonce ペアを生成する。
  /// [length] は生 nonce の文字数（Apple の推奨は 32 文字以上の英数字 + 記号）。
  factory AppleNoncePair.generate({int length = 32}) {
    final raw = _generateRawNonce(length);
    final hashed = _sha256Hex(raw);
    return AppleNoncePair(raw: raw, hashed: hashed);
  }

  /// URL セーフ + 大小英数 + 記号の混合文字種で乱数を生成。
  /// `Random.secure()` を使用しているため暗号論的に安全。
  static String _generateRawNonce(int length) {
    const charset =
        '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._';
    final random = Random.secure();
    return List.generate(
      length,
      (_) => charset[random.nextInt(charset.length)],
    ).join();
  }

  /// 文字列を UTF-8 でエンコードし SHA-256 → 16 進文字列に変換。
  static String _sha256Hex(String input) {
    final bytes = utf8.encode(input);
    final digest = sha256.convert(bytes);
    return digest.toString();
  }
}
