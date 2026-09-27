/// 【FEAT-543 (2026-09-23)】バージョンアップ告知。
///
/// ## 🔴 判定はアプリの中で行う
///
/// **サーバは各ユーザーがどの版を使っているかを知らない。**
/// `api_client.dart` が送るのは `Accept-Language` と `Authorization` だけである。
/// サーバが返すのは**しきい値 2 本と推奨更新の文面**だけで、比較はここがする。
///
/// ⚠️ だから「v1.1.4 の人だけに出す」のような絞り込みは**土台が無い**。
/// 必要になったら先に `X-App-Version` ヘッダーを足すこと（別 FEAT）。
///
/// ## 🔴 この機能は「入った版から先」にしか効かない
///
/// 本 FEAT を含まない版に留まっている人へは**永久に届かない**。
/// 告知を出すコードがそもそも入っていないからである。
/// **「全ユーザーに今すぐ告知できる機能」だと誤解しないこと。**
library;

import 'package:dio/dio.dart';

/// 告知の種別。
enum AppUpdateKind {
  /// 出さない。
  none,

  /// 推奨更新。「後で」で閉じられる。文面は admin の入力値。
  recommended,

  /// 🔴 必須更新。閉じられない。文面は ARB の固定文。
  mandatory,
}

/// `GET /api/app-update/` の応答。
class AppUpdateStatus {
  final bool isEnabled;
  final String latestVersion;
  final String minSupportedVersion;

  /// 推奨更新の見出し（admin の入力値）。
  ///
  /// ⚠️ **必須更新では使わない。** あちらは ARB の固定文である。
  final String title;

  /// 推奨更新の本文（admin の入力値）。
  final String body;

  /// 【FEAT-544 (2026-09-23)】必須更新の見出し（admin の入力値）。
  ///
  /// 🔴 **空のことがある。** Backend が未デプロイ / 通信できない /
  /// admin が誤って空にした、の 3 通り。
  /// そのときは **ARB の固定文**へ落とす —— 必須更新は**閉じられない画面**
  /// なので、文面が無いとユーザーは何をすればよいか分からない。
  final String mandatoryTitle;

  /// 【FEAT-544】必須更新の本文（admin の入力値）。空なら ARB の固定文。
  final String mandatoryBody;

  const AppUpdateStatus({
    required this.isEnabled,
    this.latestVersion = '',
    this.minSupportedVersion = '',
    this.title = '',
    this.body = '',
    this.mandatoryTitle = '',
    this.mandatoryBody = '',
  });

  static const off = AppUpdateStatus(isEnabled: false);

  factory AppUpdateStatus.fromJson(Map<String, dynamic> json) {
    return AppUpdateStatus(
      isEnabled: json['is_enabled'] as bool? ?? false,
      latestVersion: json['latest_version'] as String? ?? '',
      minSupportedVersion: json['min_supported_version'] as String? ?? '',
      title: json['title'] as String? ?? '',
      body: json['body'] as String? ?? '',
      // ⚠️ 【FEAT-544】Backend が未デプロイならキーが無い。
      //    空文字にしておけば、画面側が ARB の固定文へ落とす。
      mandatoryTitle: json['mandatory_title'] as String? ?? '',
      mandatoryBody: json['mandatory_body'] as String? ?? '',
    );
  }
}

/// `GET /api/app-update/` を叩く。
class AppUpdateService {
  final Dio _dio;
  AppUpdateService(this._dio);

  /// 🔴 **通信失敗 / 不正な応答は「告知なし」に倒す（fail open）。**
  ///
  /// 出さない側に倒すのは、BootGate v1 の「メンテしていないのにメンテ画面」と
  /// 同じ教訓である。**必須更新は閉じられない**ので、誤発火の代償が特に大きい。
  Future<AppUpdateStatus> fetchStatus() async {
    try {
      final res = await _dio.get('/app-update/');
      final data = res.data;
      if (data is! Map<String, dynamic>) return AppUpdateStatus.off;
      return AppUpdateStatus.fromJson(data);
    } catch (_) {
      return AppUpdateStatus.off;
    }
  }
}

// ── バージョン比較 ───────────────────────────────────────────────────────────

/// `x.y.z` を 3 要素の数値に分解する。できなければ null。
///
/// 🔴 **接尾辞を落としてから見る（BUG 修正 2026-09-23）。**
/// 旧実装は「`PackageInfo.version` は `pubspec.yaml` 由来なので常に 3 要素」と
/// 仮定していたが、**Android の dev flavor は `versionNameSuffix = "-dev"` を
/// 付ける**ので実際は `1.1.3-dev` が来る。3 要素ちょうどを要求していたため
/// 解析に失敗し、「判定できない = 告知しない」に倒れて
/// **dev ビルドでは告知が永久に出なかった**（dev 実機確認で判明）。
///
/// 🔵 **落とすのは `-` 以降だけにする。** 実在するのは flavor が付ける
/// `-dev` と、ベータ配布の `-beta` 程度である。
/// ⚠️ **`v1.1.4` や `1.1.3+9` は引き続き null にする。** あれは admin の
/// 入力誤りであって、**受け入れると誤った数値で告知することになる**。
/// `1.1` / 空文字 / `latest` / `1.1.x` も同じく判定不能として
/// **告知しない側に倒す**。
List<int>? _parseVersion(String raw) {
  var normalized = raw.trim();
  // `-dev` / `-beta` を落とす。比較に使うのは `x.y.z` だけである。
  final cut = normalized.indexOf('-');
  if (cut >= 0) normalized = normalized.substring(0, cut);

  final parts = normalized.split('.');
  if (parts.length != 3) return null;
  final out = <int>[];
  for (final part in parts) {
    // ⚠️ `int.tryParse` は ` 1` や `-1` を通してしまうので桁を直接見る。
    if (part.isEmpty ||
        !part.codeUnits.every((c) => c >= 0x30 && c <= 0x39)) {
      return null;
    }
    final n = int.tryParse(part);
    if (n == null) return null;
    out.add(n);
  }
  return out;
}

/// [current] が [other] より**古い**なら true。
///
/// 🔴 **文字列比較にしないこと。** `'1.1.10' < '1.1.9'` は true になる。
/// 二桁に入った瞬間に告知が止まる（あるいは逆転する）。
///
/// ⚠️ **判定できないときは false（= 告知しない）に倒す。**
/// 空文字 / `1.1` / `v1.1.4` / `1.1.4-beta` が入りうる。
/// 🔵 出さない側に倒すのは、BootGate v1 の「メンテしていないのに
/// メンテ画面」と同じ教訓である。
bool isOlderVersion(String current, String other) {
  final a = _parseVersion(current);
  final b = _parseVersion(other);
  if (a == null || b == null) return false;
  for (var i = 0; i < 3; i++) {
    if (a[i] != b[i]) return a[i] < b[i];
  }
  return false;
}

/// 端末の版としきい値から、出すべき告知を決める。
///
/// 🔴 **必須を先に見ること。** 順序を入れ替えると、
/// **使わせてはいけない版のユーザーに「後で」を出す**ことになる。
AppUpdateKind resolveAppUpdateKind({
  required AppUpdateStatus config,
  required String currentVersion,
}) {
  if (!config.isEnabled) return AppUpdateKind.none;
  if (isOlderVersion(currentVersion, config.minSupportedVersion)) {
    return AppUpdateKind.mandatory;
  }
  if (isOlderVersion(currentVersion, config.latestVersion)) {
    return AppUpdateKind.recommended;
  }
  return AppUpdateKind.none;
}
