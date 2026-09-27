/// 【BUG-159 (2026-09-12)】Sentry に「識別子でない属性」を載せる。
///
/// ## 何が起きていたか
///
/// `SentryFlutter.init` は `dsn` / `tracesSampleRate` / `beforeSend` の
/// **3 つしか設定していなかった**。つまり:
///
/// | # | 欠陥 | 影響 |
/// |:-:|---|---|
/// | 1 | **タグが 1 つも無い** | どの層で起きているかが分からない |
/// | 2 | **`environment` が未設定** | dev を叩く release ビルドが `production` として記録される |
///
/// 🔴 **2026-09-11 の 429 調査で実際に詰まった。** 欲しかったのは
/// 「何人に影響したか」ではなく **「ゲストか連携済みか」** だった ——
/// `anon: 60/hour` と `user: 300/hour` の**どちらが枯れたかで修正の
/// 当て先が変わる**。結局ユーザーに聞いて判明した。
///
/// 🔵 **タグ 1 つで、個人を特定する情報を一切含まずに分かる。**
///
/// ## 🔴 `user` は送らない（案 B / C を採らない）
///
/// `doc/legal/privacy_policy_en_draft.md` は **「PlayerProfile ID」
/// 「端末固有の識別子」を削除する**と名指しで約束し、
/// 「端末ごとではなく発生件数で見る」と現状の制約を仕様として説明している。
/// App Store の nutrition label も Diagnostics を **Not Linked** で申告済
/// （WEB-01）。
///
/// 識別子を送る案は ①ja 版 Web ポリシー（別リポジトリ）②en 草稿
/// ③nutrition label の **3 点が連動**する。⚠️ v1.1.2 の提出直前に
/// やる作業ではない。
///
/// 🔴 **「測れないのは不便だ」という動機は正しいが、
/// 文書と実装が食い違うほうが重い。**
library;

import 'package:sentry_flutter/sentry_flutter.dart';

/// タグ名。テストから参照するので定数にしてある。
const kSentryIsGuestTag = 'is_guest';
const kSentryLocaleTag = 'locale';

/// `API_BASE_URL` から Sentry の `environment` を導出する。
///
/// 🔵 Sentry Flutter は未設定時に `kDebugMode ? 'debug' : 'production'` を
/// 入れるので、debug と release は区別できていた。
/// ⚠️ **しかし Android の `dev` flavor でビルドした release APK は
/// `production` として記録される** —— 叩いている先が dev なのに、
/// prod の事象として数えられる。
///
/// 🔵 Backend は FEAT-536 (`1af91bf5`) で環境を分けている。
/// **Mobile だけ取り残されていた。**
///
/// ⚠️ **知らないホストを `prod` に寄せないこと。** それは本 BUG が
/// 直そうとしている状態そのものである。判別できないものは `unknown` にする。
String resolveSentryEnvironment(String apiBaseUrl) {
  final host = (Uri.tryParse(apiBaseUrl)?.host ?? '').toLowerCase();
  if (host.isEmpty) return 'local';
  if (host.contains('sabiowl-backend-dev')) return 'dev';
  if (host == 'sabiowl-backend.onrender.com') return 'prod';
  if (host == 'localhost' ||
      host == '127.0.0.1' ||
      // Android エミュレータからホストを指す既定のアドレス
      host == '10.0.2.2') {
    return 'local';
  }
  return 'unknown';
}

/// scope のタグを更新する **唯一の入口**。
///
/// 🔴 **呼び出し箇所を増やさないこと。** `AuthStatus.authenticated` を
/// 設定している箇所は `auth_provider.dart` に **5 箇所**あり、そこに
/// `setTag` を配るのは**このプロジェクトで 4 回続けて失敗したのと同じ形**
/// である（BUG-152 → BUG-153 → FEAT-541 → BUG-156）。
///
/// 🔵 更新者が 1 つなら、**新しい遷移が増えても自動的に追従する**。
/// 不変条件は `test/core/sentry_scope_tags_test.dart` が
/// `Sentry.configureScope` の出現数で縛っている。
///
/// ⛔ ここに user id / email / name / 端末固有 ID / IP を足さないこと。
Future<void> applySentryScopeTags({
  required bool isGuest,
  required String languageCode,
}) async {
  await Sentry.configureScope((scope) {
    scope.setTag(kSentryIsGuestTag, isGuest.toString());
    scope.setTag(kSentryLocaleTag, languageCode);
  });
}

/// ゲスト判定を読み直してからタグを更新する。
///
/// ⚠️ **`SentryFlutter.init` の時点では確定できない。** ゲスト判定は
/// secure storage (`guest_mode`) の非同期読み出しであり、**しかも実行中に
/// 変わる** (ゲスト → ソーシャル連携で `false` になる)。
/// だから認証状態が動くたびにここを通す。
///
/// 🔵 **読めなかったときは前の値を保つ。** 「判定できない」を `false` に
/// 丸めると、**ゲストのイベントが連携済みとして記録される** ——
/// それは切り分けを助けるどころか、間違った方向へ誘導する。
Future<void> syncSentryScopeTags({
  required Future<bool> Function() isGuestMode,
  required String languageCode,
}) async {
  final bool isGuest;
  try {
    isGuest = await isGuestMode();
  } catch (_) {
    return;
  }
  await applySentryScopeTags(isGuest: isGuest, languageCode: languageCode);
}
