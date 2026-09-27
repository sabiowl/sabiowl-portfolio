import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 【BUG-158 (2026-09-12)】レート制限 (HTTP 429) の状態。
///
/// ## なぜ `connectionErrorProvider` と分けるのか
///
/// 🔴 **429 は通信が生きている証拠である。** サーバが「今は多すぎる、
/// N 秒待て」と**明示的に答えている**のだから、「通信できませんでした」と
/// 出すのは事実と逆である。
///
/// 実際、本 BUG の起点になった Sentry breadcrumb は
/// `network_type: wifi` / `signal_strength: -51` / `download_bandwidth: 53661`
/// —— **通信は良好だった**。それでも ConnectionErrorOverlay が出ていた。
///
/// ⚠️ さらに悪いのは、あの画面の「再試行」が `/health/` を叩くことである。
/// **脱出のためのボタンが、脱出を妨げているもの (使い切った枠) を
/// 増やしていた。** BUG-147 Phase C が 401 で直したのと同型の再発である。
///
/// ## 復帰経路は 3 つある
///
/// 1. `Retry-After` の秒数が経過し、ユーザーが「再試行」を押す
/// 2. 業務 API が 2xx を返す (`ApiClient` の interceptor が [clear] を呼ぶ)
///    —— 🔵 **これが効くのが重要**。anon バケットが枯れていても
///    認証済みユーザーのバケットは別なので、**アプリ自体は動いていることがある**。
///    その場合この overlay は最初の成功応答で自然に消える
/// 3. アプリ再起動 (state は永続化しない)
///
/// ⚠️ **端末に永続化しないこと。** BootGate v1 の「メンテしていないのに
/// メンテ画面」と同型の罠になる。
class RateLimitStatus {
  final bool isLimited;

  /// この時刻を過ぎたら再試行してよい。[isLimited] が true なら非 null。
  final DateTime? retryAt;

  const RateLimitStatus({required this.isLimited, this.retryAt});

  static const off = RateLimitStatus(isLimited: false);

  /// [now] 時点での残り待ち時間。過ぎていれば [Duration.zero]。
  Duration remaining(DateTime now) {
    final at = retryAt;
    if (!isLimited || at == null) return Duration.zero;
    final left = at.difference(now);
    return left.isNegative ? Duration.zero : left;
  }
}

/// `Retry-After` ヘッダが無い / 読めないときに使う待ち時間。
///
/// 🔵 DRF は 429 に必ず秒数で `Retry-After` を付ける
/// (`rest_framework.views.exception_handler`) ので通常は使われない。
/// 逆に言うと**ここに落ちたら DRF 以外が 429 を返している** (Render 等)。
const kDefaultRetryAfter = Duration(seconds: 60);

/// 待ち時間の上限。
///
/// ⚠️ DRF の `anon` / `user` は 1 時間窓なので `Retry-After` は最大 3600 に
/// なりうる。**1 時間のカウントダウンを見せても意味がない**ので、
/// 画面に出す待ち時間はここで頭打ちにする。
/// 待ちが実際にはもっと長い場合、再試行が再び 429 を返して
/// カウントダウンが引き直されるだけで、壊れはしない。
const kMaxRetryAfter = Duration(minutes: 5);

/// `Retry-After` ヘッダ値を [Duration] に変換する。
///
/// ⚠️ RFC 的には HTTP-date も許されるが、DRF は**常に秒数**を送る。
/// 日付形式は読まずに [kDefaultRetryAfter] へ落とす —— 読めない値のために
/// パーサを増やすより、**必ず有限の待ち時間になること**を優先する。
Duration parseRetryAfter(String? headerValue) {
  final seconds = int.tryParse((headerValue ?? '').trim());
  if (seconds == null || seconds <= 0) return kDefaultRetryAfter;
  final parsed = Duration(seconds: seconds);
  return parsed > kMaxRetryAfter ? kMaxRetryAfter : parsed;
}

final rateLimitProvider =
    StateNotifierProvider<RateLimitNotifier, RateLimitStatus>((ref) {
  return RateLimitNotifier();
});

class RateLimitNotifier extends StateNotifier<RateLimitStatus> {
  RateLimitNotifier() : super(RateLimitStatus.off);

  /// 429 を受け取った。[retryAfter] 後まで待つ。
  ///
  /// ⚠️ 既に待機中で、新しい期限のほうが**早い**場合は延長しない
  /// (待ち時間が短くなる方向にだけ上書きしない、という意味ではなく
  /// **長い方を採る**)。連続した 429 でカウントダウンが行ったり来たり
  /// するのを防ぐ。
  void mark(Duration retryAfter, {DateTime? now}) {
    final at = (now ?? DateTime.now()).add(retryAfter);
    final current = state.retryAt;
    if (state.isLimited && current != null && !at.isAfter(current)) return;
    state = RateLimitStatus(isLimited: true, retryAt: at);
  }

  /// 制限を解除する。
  ///
  /// 業務 API が 2xx を返したとき / 再試行が成功したとき /
  /// カウントダウンが尽きてユーザーが再試行したときに呼ばれる。
  void clear() {
    if (state.isLimited) state = RateLimitStatus.off;
  }
}
