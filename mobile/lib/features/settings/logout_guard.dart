import 'package:flutter/foundation.dart';

import 'services/settings_service.dart' show LinkedAccounts;

/// 【BUG-154 (2026-09-11)】サーバに聞けないときのログアウト可否判定。
///
/// ## 何が起きていたか
///
/// `_confirmLogout` は `/auth/social/accounts/` の取得に失敗すると
/// **SnackBar を出して return** していた —— **確認ダイアログすら開かない**。
/// つまり**通信できないとログアウトできない**。
///
/// ログアウト処理そのものは通信を捨てる前提で書かれている
/// (`auth_service.dart` が `/auth/logout/` の失敗を握ってローカル削除を続行する)。
/// **能力はあるのに、入口の事前チェックだけが閉じていた。**
///
/// 🔴 結果として**アプリが壊れて逃げ出したいユーザーほど逃げられない**という、
/// ガードの目的と真逆の状態を作っていた。BUG-155 (30 日で失効) と
/// BUG-156 (ホームに留まる) と重なると、**ユーザー側に残された手が無くなる。**
///
/// ## 🔵 事前チェック自体は消してはならない
///
/// 未連携ユーザーがログアウトすると**データが戻らない**。
/// これは残すべきガードで、「失敗したら通す」にしてはいけない。
/// **直すのは「判定できないなら拒否する」(fail closed) という実装のほう**で、
/// 判定材料をローカルに切り替えるのが本修正である。
///
/// ## 判定の向きは安全側に倒れている
///
///   サーバに聞けた   → `hasAnyLink` で判定 (従来どおり)
///   聞けなかった     → ローカルの `guest_mode` フラグで判定
///                       true  → 未連携 → **止める**
///                       false → 連携済み → **通す**
///
/// ⚠️ **前提**: `guest_mode` は正式登録の完了時に `setGuestMode(false)` で
/// 削除される。FEAT-178 で Magic Link が撤去された結果、
/// **非ゲストになる経路はソーシャル連携だけ**である
/// (実装時に全 `setGuestMode(false)` 呼び出しを確認済 ——
/// `auth_provider` の 3 箇所と `settings_service` の 2 箇所は
/// すべてソーシャルサインイン / 連携の完了地点)。
///
/// 🔴 **この前提が将来崩れると、未連携ユーザーがデータを失う経路になる。**
/// `test/settings/logout_guard_test.dart` が参照を固定している。

/// サーバ問い合わせを諦める時間。
///
/// ⚠️ Dio の既定は `connectTimeout` / `receiveTimeout` ともに **60 秒**
/// (Render のコールドスタート対応で意図的に長い)。サーバが遅いだけの場合、
/// **押しても 1 分間なにも起きない** —— ユーザーには「反応しない」としか
/// 見えず、実質ログアウト不能と同じである。
///
/// 🔵 この呼び出しの結果は「連携済みか」の **1 bit しか使わない**ので、
/// 5 秒で諦めてローカル判定に落ちても失うものが無い。
const kLogoutLinkCheckTimeout = Duration(seconds: 5);

/// 未連携としてログアウトを止めるべきなら true。
Future<bool> shouldBlockLogoutAsUnlinked({
  required Future<LinkedAccounts> Function() fetchLinkedAccounts,
  required Future<bool> Function() isGuestMode,
  Duration timeout = kLogoutLinkCheckTimeout,
}) async {
  LinkedAccounts? accounts;
  try {
    accounts = await fetchLinkedAccounts().timeout(timeout);
  } catch (e) {
    // 🔴 ここで return してはいけない (それが本 BUG だった)。
    //    「判定できない」を「拒否」にせず、ローカルの情報で判定し直す。
    debugPrint('[logout] 連携状態をサーバに聞けなかった → ローカル判定に落とす: $e');
    accounts = null;
  }

  if (accounts != null) return !accounts.hasAnyLink;

  // ⚠️ fallback。迷ったら「止める」側に落ちるので、
  //    データを失う方向には転ばない。
  return isGuestMode();
}
