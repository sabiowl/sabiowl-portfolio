/// 【BUG-160 (2026-09-12)】Sentry の HTTP breadcrumb から識別子を伏せる。
///
/// ## なぜ breadcrumb が要るのか
///
/// 🔴 **BUG-158 の調査で実際に詰まった。** 429 の Sentry イベントには
/// lifecycle / network / battery の breadcrumb しか無く、
/// **「429 はこの 1 本だけか、全 API に出ているのか」が判別できなかった**。
///
/// グローバル throttle が枯れているなら全エンドポイントが 429 になるはずで、
/// breadcrumb に他の 429 が並んでいれば**その場で確定した**。実際には
/// ユーザーに「テスターは連携済みか」を聞いて初めて `user: 300/hour` だと
/// 分かった。
///
/// ## 🔴 素のまま有効化すると方針違反になる
///
/// `api/urls.py` には URL パスに `PlayerProfile.id` が入る経路がある
/// (`friends/<int:player_id>/profile/` 等)。`social_service.dart` は
/// `friend_id` をクエリで送る。
///
/// `doc/legal/privacy_policy_en_draft.md` は **「PlayerProfile ID」
/// 「端末固有の識別子」を削除する**と名指しで約束しているので、
/// **有効化ではなく「安全に有効化」が本 BUG の主題**である。
///
/// ⚠️ `friend_id` は「ユーザーが自分で共有する公開コード」だが、
/// **per-user の識別子であることは変わらない**。公開コードだから安全、
/// という理屈で通さないこと。
///
/// ## 伏せ方の方針
///
/// | 対象 | 扱い |
/// |---|---|
/// | パスの数値セグメント | **一律** `{id}` |
/// | クエリの値 | **許可した名前以外を一律** `{redacted}` |
/// | request / response body | **そもそも記録しない** (`SentryBreadcrumbInterceptor`) |
/// | ヘッダー | 同上。`Authorization` が入るので絶対に送らない |
///
/// 🔵 **どちらも「危険なものを列挙する」形にしていない。**
/// 列挙は BUG-152 → BUG-153 → FEAT-541 → BUG-156 → BUG-159 と
/// **5 回続けて漏れた形**である。
///
/// 🔴 **一律に伏せて失うものは無い。** 調査で必要なのは
/// **「どのエンドポイントか」**であって「どの行か」ではない。
/// `/api/friends/{id}/profile/` で十分に用は足りる。
library;

import 'package:sentry_flutter/sentry_flutter.dart';

/// 値をそのまま残してよいクエリパラメータ名。
///
/// 🔵 実測で洗い出した、**per-user の識別子を含まない**ものだけを並べる
/// (`mobile/lib` の `queryParameters` 全箇所)。
///
/// 🔴 **許可制にしている理由**: 拒否リストにすると、
/// **あとで追加されたパラメータが既定で漏れる**。許可制なら既定で伏せる。
/// 「危険なものを列挙する」形で 5 回続けて失敗しているので、
/// **失敗したときに安全側へ倒れる向き**を選ぶ。
///
/// ⚠️ ここに名前を足すときは、その値が **per-user の識別子でないこと**を
/// 確かめること。`friend_id` は公開コードだが識別子なので**入れない**。
const kBreadcrumbSafeQueryKeys = <String>{
  'date',
  'limit',
  'month',
  'pending_google_push',
  'tier',
  'time_segment',
  'type',
  'year',
};

/// 伏せ字。
const kRedactedPathSegment = '{id}';
const kRedactedQueryValue = '{redacted}';

/// URL からパスの数値セグメントと、許可していないクエリ値を伏せる。
///
/// ```
/// /api/friends/42/profile/   ->  /api/friends/{id}/profile/
/// /api/habits/17/count/      ->  /api/habits/{id}/count/
/// ?friend_id=ABC123          ->  ?friend_id={redacted}
/// ```
///
/// ⚠️ **`friend_id` は数値ではない**ので、パスの数値規則では捕まらない。
/// **規則を 1 本書いて満足すると、必ずここが漏れる。**
String scrubBreadcrumbUrl(String rawUrl) {
  final uri = Uri.tryParse(rawUrl);
  if (uri == null) return rawUrl;

  final segments = uri.pathSegments
      .map((s) => _isAllDigits(s) ? kRedactedPathSegment : s)
      .toList();

  final query = <String, String>{
    for (final entry in uri.queryParameters.entries)
      entry.key: kBreadcrumbSafeQueryKeys.contains(entry.key)
          ? entry.value
          : kRedactedQueryValue,
  };

  // ⚠️ 末尾スラッシュは `Uri.pathSegments` が末尾の空文字として保持するので、
  // 置換後もそのまま復元される。API のパスは末尾スラッシュ付きなので、
  // ここが崩れると「どのエンドポイントか」が読みにくくなる。
  //
  // ⚠️ `queryParameters` に null を渡すと**元の query が残る**ので、
  // 空のときは `pathSegments` だけ差し替える。
  final scrubbed = query.isEmpty
      ? uri.replace(pathSegments: segments)
      : uri.replace(pathSegments: segments, queryParameters: query);

  // ⚠️ `Uri` は `{` `}` を percent-encode するので、そのままだと
  // `/friends/%7Bid%7D/profile/` になって**読めない**。
  // 伏せること自体は達成できているが、§3-3「伏せてもエンドポイントは
  // 識別できる」を満たさなくなる ——**伏せる目的は行を隠すことであって、
  // エンドポイントを隠すことではない。**
  //
  // 🔵 戻すのは**自分が置いた伏せ字と完全一致する文字列だけ**なので、
  // 元の URL の中身が復元されることはない。
  return scrubbed
      .toString()
      .replaceAll(Uri.encodeComponent(kRedactedPathSegment),
          kRedactedPathSegment)
      .replaceAll(Uri.encodeComponent(kRedactedQueryValue),
          kRedactedQueryValue);
}

bool _isAllDigits(String s) =>
    s.isNotEmpty && s.codeUnits.every((c) => c >= 0x30 && c <= 0x39);

/// `SentryOptions.beforeBreadcrumb` に渡すフック。
///
/// 🔴 **`beforeSend` 側で breadcrumb を書き換えないこと。** イベント確定時に
/// まとめて触る形にすると、**breadcrumb の種類が増えるたびに漏れる**。
/// 1 件ずつ通るここで処理する。
///
/// 🔵 `beforeSend` の `user: null` とは**役割が別**で、あちらは触らない
/// (BUG-159 の方針)。
Breadcrumb? scrubHttpBreadcrumb(Breadcrumb? breadcrumb, Hint hint) {
  if (breadcrumb == null) return null;
  final data = breadcrumb.data;
  if (data == null) return breadcrumb;

  final url = data['url'];
  if (url is! String) return breadcrumb;

  final next = Map<String, dynamic>.of(data);
  next['url'] = scrubBreadcrumbUrl(url);
  // `Breadcrumb.http` は query / fragment を別キーにも入れる。
  // ⚠️ url だけ伏せて満足すると、ここから同じ値が出ていく。
  final httpQuery = next['http.query'];
  if (httpQuery is String) {
    next['http.query'] = _scrubQueryString(httpQuery);
  }
  next.remove('http.fragment');

  return breadcrumb.copyWith(data: next);
}

String _scrubQueryString(String query) {
  if (query.isEmpty) return query;
  final parsed = Uri.splitQueryString(query);
  return parsed.entries
      .map((e) =>
          '${e.key}=${kBreadcrumbSafeQueryKeys.contains(e.key) ? e.value : kRedactedQueryValue}')
      .join('&');
}
