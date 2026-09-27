import 'dart:convert';

import 'package:crypto/crypto.dart';  // 【FEAT-542】持ち主の指紋
import 'package:shared_preferences/shared_preferences.dart';

/// SharedPreferences キー定数集。
///
/// アプリ全体で使用する SharedPreferences のキー文字列をここに一元管理する。
/// 散在によるキー名の誤りと重複を防ぐ。

// ── 【FEAT-399 (2026-05-31)】BackupPromptSheet マイルストーン抑制 ─────────────────

/// BackupPromptSheet を最後に表示したプレイヤーレベルを保存するキー。
///
/// 同一レベルで 2 回目以降の表示を抑制するために使用する
/// (例: Lv 5 で一度表示後、同 Lv でのリトライ起動では表示しない)。
/// 値がない (初回) は 0 として扱う。
const String kPrefsLastBackupSheetShownLevel = 'last_backup_sheet_shown_level';

/// BackupPromptSheet を発火するマイルストーン Lv セット。
///
/// このレベルに到達したとき、ゲストユーザーにバックアップを促す
/// BackupPromptSheet が表示される。毎レベルアップでは表示しない (FEAT-399 抑制)。
const Set<int> kBackupSheetMilestoneLevels = {5, 10, 20, 30};

/// BackupPromptSheet を表示すべきか判定する。
///
/// [level] が [kPrefsLastBackupSheetShownLevel] に保存された値より大きい場合のみ `true`。
/// [prefs] は省略すると `SharedPreferences.getInstance()` を呼ぶ (テスト時に渡してモック化可能)。
Future<bool> shouldShowBackupPromptSheet(int level, {SharedPreferences? prefs}) async {
  final p = prefs ?? await SharedPreferences.getInstance();
  final lastLevel = p.getInt(kPrefsLastBackupSheetShownLevel) ?? 0;
  return level > lastLevel;
}

/// BackupPromptSheet を表示済みとして [kPrefsLastBackupSheetShownLevel] に [level] を保存する。
///
/// 表示 **前** に呼ぶことで同一レベルでの二重表示を防ぐ。
/// [prefs] は省略すると `SharedPreferences.getInstance()` を呼ぶ (テスト時に渡してモック化可能)。
Future<void> markBackupPromptSheetShown(int level, {SharedPreferences? prefs}) async {
  final p = prefs ?? await SharedPreferences.getInstance();
  await p.setInt(kPrefsLastBackupSheetShownLevel, level);
}

// ── 【FEAT-462 (2026-06-22)】バトル戻るボタン初回ヒント ─────────────────────────

/// バトル戻るボタンの初回ヒント (「戻ってもバトルは続きますよ」) を
/// 表示済みかどうかを保存するキー。
///
/// 初回バトル時に 1 度だけ吹き出しを表示し、以降は表示しない。
/// 値がない (初回) は false として扱う。
const String kPrefsBattleBackHintShown = 'battle_back_hint_shown';

/// バトル戻るボタンの初回ヒントを表示すべきか判定する。
///
/// [prefs] は省略すると `SharedPreferences.getInstance()` を呼ぶ
/// (テスト時に渡してモック化可能)。
Future<bool> shouldShowBattleBackHint({SharedPreferences? prefs}) async {
  final p = prefs ?? await SharedPreferences.getInstance();
  return !(p.getBool(kPrefsBattleBackHintShown) ?? false);
}

/// バトル戻るボタンの初回ヒントを表示済みとしてマークする。
///
/// 表示 **前** に呼ぶことで二重表示を防ぐ (Pre-mortem #1)。
/// [prefs] は省略すると `SharedPreferences.getInstance()` を呼ぶ。
Future<void> markBattleBackHintShown({SharedPreferences? prefs}) async {
  final p = prefs ?? await SharedPreferences.getInstance();
  await p.setBool(kPrefsBattleBackHintShown, true);
}

// ── 【FEAT-543 (2026-09-23)】バージョンアップ告知の 24 時間抑制 ──────────────

/// 推奨更新の告知で「後で」を押した時刻を保存するキーの接頭辞。
///
/// 🔴 **キーに版を含める。** 「どの版に対して後でと言ったか」を持たないと、
/// **版が上がっても 24 時間は再告知できない**。新しい版が出たら
/// 別のキーになるので、そのときは即座にもう一度出る。
///
/// 🔴 **secure storage に置かないこと。** 秘密ではないし、
/// BUG-167 で痛い目を見ている。
const String kPrefsAppUpdateDismissedAtPrefix = 'app_update_dismissed_at_';

/// 推奨更新の告知を抑制する時間。
///
/// ⚠️ 必須更新には**適用しない**。あちらは毎回出す。
const Duration kAppUpdateSuppressDuration = Duration(hours: 24);

String _appUpdateDismissKey(String version) =>
    '$kPrefsAppUpdateDismissedAtPrefix$version';

/// [version] への推奨更新の告知が、いま抑制されているか。
///
/// [now] はテストから固定するためのもの。
Future<bool> isAppUpdateNoticeSuppressed(
  String version, {
  SharedPreferences? prefs,
  DateTime? now,
}) async {
  if (version.isEmpty) return false;
  final p = prefs ?? await SharedPreferences.getInstance();
  final at = p.getInt(_appUpdateDismissKey(version));
  if (at == null) return false;
  final dismissedAt = DateTime.fromMillisecondsSinceEpoch(at);
  final elapsed = (now ?? DateTime.now()).difference(dismissedAt);
  // ⚠️ 端末の時計が巻き戻ると elapsed が負になる。そのときは抑制を続ける
  //    （出しすぎるより、24 時間の約束を守るほうを選ぶ）。
  return elapsed < kAppUpdateSuppressDuration;
}

/// [version] への推奨更新の告知を「後で」として記録する。
Future<void> markAppUpdateNoticeDismissed(
  String version, {
  SharedPreferences? prefs,
  DateTime? now,
}) async {
  if (version.isEmpty) return;
  final p = prefs ?? await SharedPreferences.getInstance();
  await p.setInt(
    _appUpdateDismissKey(version),
    (now ?? DateTime.now()).millisecondsSinceEpoch,
  );
}

// ── 【FEAT-542 (2026-09-23)】プロフィール設定の完了フラグ ────────────────────
//
// ## 🔴 `has_seen_tutorial` を捨ててここへ来た
//
// 旧キーは**意味を 2 つ兼任**していた ——「チュートリアルを見たか」と
// 「プロフィール設定が終わったか」である。後者だけが分岐に使われており、
// **名前とキャラが未設定のままホームへ行くのを止めている**唯一の砦だった。
//
// 🔵 チュートリアル（世界観スライド）は `/onboarding` に据え置いたまま、
// **「見たかどうか」を記録するのをやめた**。プロフィール設定は身元ごとに
// 1 回しか通らないので、スライドも 1 回しか出ない ——**記録は要らない**。
// ⚠️ 「一応残しておく」を選ばないこと。読み手のいないフラグは、
// 次の誰かが分岐に使い、**同じ二重意味が戻ってくる**。
//
// ## 🔴 フラグは端末に付き、身元には付かない —— だから持ち主を書く
//
// 置き場所を `SharedPreferences` に変えても、**フラグが端末に付いている**
// 限り次の経路が残る（BUG-167 の検討中に見つかった）:
//
//   連携済みユーザーのトークンが消える（更新 / ログアウト / 401）
//     -> 「ゲストとして始める」-> 新しいゲスト -> 設定の途中で kill
//     -> 再起動で「トークンあり + 設定済み」-> ホーム
//     -> 名前「ゲスト」+ キャラ未選択（2026-07-02 に直した症状）
//
// 🔵 そこで**持ち主を値に持たせる**。読み手は
// **現在の身元と一致するときだけ**「設定済み」とみなす。
// **読み手が 1 箇所なので、書き手が何箇所あっても壊れない。**
//
// ## ⚠️ 持ち主の識別は player id ではなく「資格情報の指紋」
//
// 指示書 §4.1 は `<player id>` を想定していたが、**それだと
// 「現在の player id」を端末に別途持つ必要がある**（起動直後にサーバへ
// 聞けないので）。そのキーは**身元を作るすべての地点で書く**ことになり、
// **書き忘れた 1 箇所がそのまま穴**になる —— 指示書が案 A を退けた理由
// そのものである（`startAsGuest` と BUG-147 の自動再作成の 2 箇所がある）。
//
// 🔵 **トークンは書き忘れようがない。** 書かなければアプリが動かないからで、
// **沈黙して壊れることがない**。だから身元側の書き手は**ゼロ**にできる。
// トークンは身元と 1 対 1 である ——
//   * ゲストトークン … ゲストの `PlayerProfile` に 1 本
//   * ユーザートークン … `Token.objects.get_or_create(user)` で**利用者ごとに不変**
// 新しい身元が作られれば**必ず**新しいトークンになるので、指紋は必ず変わる。
//
// 🔵 **秘密は保存していない。** 40 文字のランダム文字列の SHA-256 を
// 先頭 16 桁だけ持つ。元に戻せないし、資格情報として使えない。
// ⚠️ だからといって**トークンそのものを書かないこと**。

/// プロフィール設定を完了した**持ち主**を記録するキー。
///
/// 🔴 **真偽値のキーを別に作らないこと。** 2 本になると
/// 「どちらが真実値か」という問いが戻ってきて、
/// **持ち主を見ない側が分岐に使われる**（= 指示書の案 A に逆戻り）。
/// `test/onboarding_lands_on_home_test.dart` が走査で縛っている。
const String kPrefsProfileSetupCompletedFor = 'profile_setup_completed_for';

/// 【BUG-156 §3-4】secure storage から移設した「秘密でない」3 キー。
///
/// ⚠️ どれも資格情報ではない。secure storage に置いていたせいで
/// **初回掃除（BUG-156）に巻き込まれて消える**という事故を起こした（BUG-167）。
const String kPrefsIsRegistered    = 'is_registered';
const String kPrefsGuestMode       = 'guest_mode';
const String kPrefsTokenValidatedAt = 'token_validated_at';

/// 移設と意味の付け替えが済んだことを示すマーカー。
///
/// 🔴 **1 回だけ走らせる。** 2 回目が走ると、既に消した旧キーを
/// 「無い = 未設定」と読んで**全員を未設定に落とす**。
const String kPrefsDeviceFlagsMigrated = 'device_flags_migrated_to_prefs';

/// トークンから持ち主の指紋を作る。
///
/// ⚠️ **トークンそのものを返さないこと。** `SharedPreferences` は
/// 秘密の置き場所ではない。
String profileSetupIdentityOf(String token) =>
    sha256.convert(utf8.encode(token)).toString().substring(0, 16);

/// [identity] の持ち主がプロフィール設定を終えているか。
///
/// ⛔ **[identity] が取れないときに `true` を返さないこと。**
/// 「取れないので設定済みとみなす」は、**名前もキャラも無いまま
/// ホームに着く**という 2026-07-02 の症状そのものである。
/// 🔵 身元が取れないのはトークンが 1 本も無いときで、そのときの
/// 行き先は認証画面である —— 本関数の答えは使われない。
Future<bool> isProfileSetupCompletedFor(
  String? identity, {
  SharedPreferences? prefs,
}) async {
  if (identity == null || identity.isEmpty) return false;
  final p = prefs ?? await SharedPreferences.getInstance();
  final owner = p.getString(kPrefsProfileSetupCompletedFor);
  // 🔴 「null なら未設定」だけでは足りない。**別の持ち主なら未設定**である。
  return owner != null && owner == identity;
}

/// [identity] の持ち主のプロフィール設定を「完了」として記録する。
Future<void> markProfileSetupCompletedFor(
  String? identity, {
  SharedPreferences? prefs,
}) async {
  if (identity == null || identity.isEmpty) return;
  final p = prefs ?? await SharedPreferences.getInstance();
  await p.setString(kPrefsProfileSetupCompletedFor, identity);
}
