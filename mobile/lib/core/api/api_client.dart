import 'dart:async';  // 【BUG-147 Phase B-2】guest-init 直列化の Completer

import 'package:dio/dio.dart';
import 'package:dio_cache_interceptor/dio_cache_interceptor.dart';  // 【FEAT-476】
import 'package:dio_cache_interceptor_hive_store/dio_cache_interceptor_hive_store.dart';  // 【FEAT-476】
import 'package:flutter/foundation.dart';  // 【BUG-156】debugPrint
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';  // 【BUG-156】初回起動検知
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';  // 【FEAT-476】
import 'package:riverpod_annotation/riverpod_annotation.dart';
import '../../features/auth/providers/auth_provider.dart';
import '../analytics/sentry_breadcrumb_interceptor.dart';  // 【BUG-160】HTTP breadcrumb
import '../constants/preferences_keys.dart';  // 【FEAT-542】端末フラグの置き場所
import '../l10n/service_l10n.dart';  // 【FEAT-489 Phase 2E】Accept-Language 解決
import '../providers/connection_error_provider.dart';  // 【2026-07-09】5xx sentinel の発火先
import '../providers/rate_limit_provider.dart';  // 【BUG-158】429 の待ち時間を持つ state
import '../providers/account_suspension_provider.dart';
import '../providers/maintenance_provider.dart';  // 【FEAT-463】X-Maintenance header 検知
import '../services/toast_center.dart';  // 【BUG-147 Phase B-2】再作成の告知
import 'dio_error_helper.dart';  // 【BUG-147 Phase B-2】ApiError.fromResponse

part 'api_client.g.dart';

// 環境に応じてベースURLを切り替え
// 【FEAT-199】Render サービス名を Sabiowl ブランドに統一
//   旧: restack-backend.onrender.com
//   新: sabiowl-backend.onrender.com
// ignore: do_not_use_environment
/// 【BUG-159 (2026-09-12)】Sentry の `environment` 導出がここを読むので公開している。
/// ⚠️ main.dart で `String.fromEnvironment` を書き直すと、
/// **既定値が 2 箇所になって黙ってめる**。
const kApiBaseUrl = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: 'https://sabiowl-backend.onrender.com/api',
);

const _tokenKey            = 'hg_token';
const _guestTokenKey       = 'hg_guest_token';   // FEAT-188: ゲストセッショントークン

// ── 【FEAT-542 (2026-09-23)】secure storage に残っている旧キー ──────────────
//
// 🔴 **読むのは移行 (`_migrateDeviceFlagsToPrefs`) だけである。**
// 本体はすべて `SharedPreferences` へ移した（BUG-156 §3-4 を本 FEAT に統合）。
// どれも資格情報ではなく、secure storage に置いていたせいで
// **初回掃除に巻き込まれて消える**という事故を起こした（BUG-167）。
//
// ⚠️ `_legacyTutorialKey` は意味も変わった。詳細は
//    `core/constants/preferences_keys.dart` の FEAT-542 節。
const _legacyRegisteredKey       = 'is_registered';
const _legacyTutorialKey         = 'has_seen_tutorial';
const _legacyGuestModeKey        = 'guest_mode';
const _legacyTokenValidatedAtKey = 'token_validated_at';

/// 【BUG-167】ゲストトークンと**一緒のときだけ**、初回掃除で残すキー。
///
/// どちらも資格情報ではなく、**そのゲストに付いている状態**である。
/// ⚠️ ここに足すのは「ゲストトークンの持ち主に属するもの」だけ。
///    それ以外の新しいキーは、既定どおり掃除で消えること。
///
/// 🔴 【FEAT-542】**移設が済んでも消さない。** 指示書 §5.6 は
/// 「移行が掃除より後に走る」「移行が自分で delete する」の 2 条件を満たせば
/// 外してよいとしているが、**外すと v1.1.1 以前から直接更新する人の
/// 移行元が消える** —— 掃除は初回に 1 度だけ走り、そこで `deleteAll()` が
/// 旧キーを消したあとに移行が読むと、**既存ゲスト全員が「未設定」になる**。
/// 🔵 つまり保全は不要になったのではなく、**移行が読み通すための経路**に
/// 役目が変わった。移行が済んだ端末では、旧キー自体が存在しないので空振りする。
const _guestOwnedKeys = <String>[_legacyTutorialKey, _legacyGuestModeKey];

@riverpod
ApiClient apiClient(Ref ref) {
  return ApiClient(ref);
}

class ApiClient {
  late final Dio _dio;
  final _storage = const FlutterSecureStorage();

  // ── 【BUG-156 (2026-09-11)】再インストール時の secure storage 掃除 ──────
  //
  // ## なぜ必要か
  //
  // `FlutterSecureStorage` は iOS では **Keychain** で、
  // **アンインストールしても消えない**（Apple は iOS 10.3 beta で
  // 「削除時に Keychain も消す」に変更したが**製品版までに撤回**した）。
  //
  // 結果、再インストールしても `hg_token` / `token_validated_at` /
  // `is_registered` / `has_seen_tutorial` まで丸ごと復元され、
  // アプリは**削除前と完全に同一の状態**で起動する ——
  // 失効したトークンを掴んだまま詰んだユーザーが、
  // **再インストールでも復帰できない**（実際に報告が来た）。
  //
  // 🔴 **プラットフォームで挙動が違うことが、意図した設計でない証拠である**:
  //    iOS      … 元の状態のまま（ログイン画面が出ない）
  //    Android  … ログイン画面が出る（EncryptedSharedPreferences は一緒に消える）
  //
  // ## 仕組み
  //
  // **「消えるストレージ」と「消えないストレージ」を組み合わせて
  // 新規インストールを検出する。** `SharedPreferences` は
  // アンインストールで消えるので、そこにマーカーが無ければ入れ直した直後である。
  //
  // ⚠️ **`deleteAll()` を使う（キーを列挙して消さない）。**
  //    列挙すると**あとで追加されたキーが漏れる** ——
  //    このプロジェクトで 3 回続けて踏んだ形
  //    (BUG-152 → BUG-153 → FEAT-541)。掃除の網羅性をリストに委ねない。
  static const kSecureStorageInitializedKey = 'secure_storage_initialized';

  /// 掃除が済むまで secure storage を読ませないためのゲート。
  ///
  /// ⚠️ **すべての読み書きがこれを待つ**（`_readSecure` / `_writeSecure` /
  /// `_deleteSecure`）。トークンを読む前に必ず 1 回通ることが要件なので、
  /// 呼び出し側に `await` を配って回る形にはしない ——
  /// **配り忘れた 1 箇所が、掃除前のトークンで home へ行く経路になる。**
  late final Future<void> _storageReady = _prepareSecureStorage();

  /// 🔴 【FEAT-542】**この 3 つは順序が意味を持つ。**
  ///
  /// | # | 何を | なぜこの位置か |
  /// |:-:|---|---|
  /// | 1 | 掃除（BUG-156） | `deleteAll()` するので、旧キーを読む処理より**前**でなければ読めるものが変わる |
  /// | 2 | 移設（本 FEAT） | 掃除が残した旧キーを読んで `SharedPreferences` へ移す。🔴 **掃除より後**でなければ、既存ゲスト全員が「未設定」になる |
  /// | 3 | 修復（BUG-167） | 移設で書いた `guest_mode` を上書きしないよう**最後**。v1.1.2 で消えた分を戻す |
  ///
  /// ⚠️ 2 と 3 を入れ替えると、修復が立てた `guest_mode` を移設が
  /// 「旧キーが無い = false」で**上書きして消す**。
  Future<void> _prepareSecureStorage() async {
    await _cleanSecureStorageOnFirstLaunch();
    await _migrateDeviceFlagsToPrefs();
    await _repairGuestModeFlag();
  }

  /// 【FEAT-542 (2026-09-23)】秘密でない 4 キーを `SharedPreferences` へ移す。
  ///
  /// ## 🔴 `has_seen_tutorial` は意味も変わる
  ///
  /// 旧キーは「チュートリアルを見たか」と**「プロフィール設定が終わったか」**を
  /// 兼任しており、**分岐に使われていたのは後者だけ**である。
  /// したがって `true` は「設定済み」と読み替え、**いま持っている資格情報の
  /// 指紋**を持ち主として記録する（`preferences_keys.dart` の FEAT-542 節）。
  ///
  /// ⚠️ **トークンが 1 本も無いなら何も書かない。** 持ち主のいない
  /// 「設定済み」を残すと、**次に作られる身元がそれを引き継ぐ** ——
  /// BUG-167 で見つけた経路そのものである。
  ///
  /// 🔵 **旧キーは自分で消す**（掃除に頼らない）。掃除は初回の 1 度しか
  /// 走らないので、任せると消えないまま残る。
  Future<void> _migrateDeviceFlagsToPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(kPrefsDeviceFlagsMigrated) ?? false) return;

      final legacyTutorial = await _storage.read(key: _legacyTutorialKey);
      final legacyRegistered = await _storage.read(key: _legacyRegisteredKey);
      final legacyGuestMode = await _storage.read(key: _legacyGuestModeKey);
      final legacyValidatedAt =
          await _storage.read(key: _legacyTokenValidatedAtKey);

      if (legacyTutorial == 'true') {
        // ⚠️ `_readSecure` は使わない —— 本処理の完了を待つので自分を待って止まる。
        final user = await _storage.read(key: _tokenKey);
        final guest = await _storage.read(key: _guestTokenKey);
        final token = (user != null && user.isNotEmpty)
            ? user
            : ((guest != null && guest.isNotEmpty) ? guest : null);
        if (token != null) {
          await markProfileSetupCompletedFor(
            profileSetupIdentityOf(token),
            prefs: prefs,
          );
        }
      }
      if (legacyRegistered == 'true') {
        await prefs.setBool(kPrefsIsRegistered, true);
      }
      if (legacyGuestMode == 'true') {
        await prefs.setBool(kPrefsGuestMode, true);
      }
      if (legacyValidatedAt != null && legacyValidatedAt.isNotEmpty) {
        await prefs.setString(kPrefsTokenValidatedAt, legacyValidatedAt);
      }

      await _storage.delete(key: _legacyTutorialKey);
      await _storage.delete(key: _legacyRegisteredKey);
      await _storage.delete(key: _legacyGuestModeKey);
      await _storage.delete(key: _legacyTokenValidatedAtKey);
      await prefs.setBool(kPrefsDeviceFlagsMigrated, true);
    } catch (e) {
      // ⚠️ マーカーを立てないので、次回起動でやり直される。
      debugPrint('[ApiClient] 端末フラグの移設に失敗: $e');
    }
  }

  /// 【BUG-167 (2026-09-13)】v1.1.2 の掃除で消えた `guest_mode` を戻す。
  ///
  /// ## なぜ要るのか
  ///
  /// 掃除（[_cleanSecureStorageOnFirstLaunch]）の修正は**これから更新する人**
  /// しか守らない。掃除はマーカーで**一度しか走らない**ので、
  /// **v1.1.2 で既に消えた分は、v1.1.3 にしても戻らない。**
  ///
  /// `has_seen_tutorial` は自然に戻る（オンボーディングの完了で書き直される）。
  /// 🔴 **`guest_mode` は誰も書き直さない。** 既存ゲストは `startAsGuest` を
  /// 通らず case B でホームへ行くので、**連携できない状態がずっと続く**。
  ///
  /// ## 判定
  ///
  ///   ゲストトークンあり + ユーザートークン無し + guest_mode 無し
  ///     -> guest_mode を立てる
  ///
  /// 🔵 【FEAT-542】`guest_mode` は `SharedPreferences` へ移したが、
  /// **本修復は残す**。移設したのは「これから掃除に巻き込まれない」ためで、
  /// **v1.1.2 で既に消えた分は移設しても戻らない**（移行元が空なのだから）。
  ///
  /// 🔵 **ゲストトークンを持つのはゲストだけである。** 昇格はどの経路でも
  ///    `saveToken` -> `deleteGuestToken` -> `setGuestMode(false)` の順で進み
  ///    （`auth_provider` / `settings_service`）、
  ///    **ゲストトークンが消えるより前にユーザートークンが入る**。
  ///
  /// ⚠️ **「ユーザートークン無し」を外さないこと。** 昇格の途中で落ちると
  ///    両方のトークンが残る。そこで guest_mode を立てると、
  ///    **連携済みのユーザーをゲストとして扱う**（連携がゲスト用の昇格経路へ向かう）。
  ///
  /// 🔵 マーカーを持たず、起動のたびに走る。条件を満たさなければ書かないので冪等。
  ///    ⚠️ `_readSecure` を使わないこと。あれは本処理の完了を待つので、
  ///    ここから呼ぶと自分自身を待って止まる。
  Future<void> _repairGuestModeFlag() async {
    try {
      final guest = await _storage.read(key: _guestTokenKey);
      if (guest == null || guest.isEmpty) return;
      final user = await _storage.read(key: _tokenKey);
      if (user != null && user.isNotEmpty) return;
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(kPrefsGuestMode) ?? false) return;
      await prefs.setBool(kPrefsGuestMode, true);
    } catch (e) {
      debugPrint('[ApiClient] guest_mode の修復に失敗: $e');
    }
  }

  Future<void> _cleanSecureStorageOnFirstLaunch() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(kSecureStorageInitializedKey) ?? false) return;

      // 🔴 ゲストトークンだけは残す。
      //
      // **ゲストのデータはゲストトークンでしか辿れない。** サーバ側に
      // `PlayerProfile` はあるが `User` が無いので**ログインで取り戻せない**。
      // トークンを失うと**復旧経路がゼロ**になる ——
      // FEAT-193 はまさにこの事故の再発防止で入った修正である。
      //
      // ⚠️ 「Android では既に消えているので揃えるべき」という理屈で
      //    消してはならない。それは**より悪い挙動に、しかもデータを失う側に
      //    合わせる**ことになる。
      //
      // 🔵 本 BUG が解くのは「認証済みユーザーが 401 で詰む」であって、
      //    ゲストは `hg_token` を持たないので**そもそも対象外**である。
      final guest = await _storage.read(key: _guestTokenKey);
      final hasGuest = guest != null && guest.isNotEmpty;

      // 🔴 【BUG-167 (2026-09-13)】ゲストトークンと一緒のときだけ、
      //    **そのゲストに付いている 2 つのフラグ**も残す（`_guestOwnedKeys`）。
      //
      // ## 消していたときに起きていたこと
      //
      // 更新（再インストールではない）で本処理が走ると、既存ゲストは
      // **トークンだけ残ってフラグが消える**。
      //
      //   has_seen_tutorial が消える
      //     -> router の case B が「設定未完了」と読んでオンボーディングへ送り、
      //        `_complete()` が名前・性別・キャラを上書きする
      //   guest_mode が消える
      //     -> アプリがゲストを連携済みとして扱う。連携はユーザー用 API を
      //        叩いて 401 になり、ログアウトガードの fallback も止めなくなる
      //
      // ⚠️ 再インストールでは起きない。トークンとフラグが一緒に残るか
      //    一緒に消えるので、この組み合わせを作れない ——
      //    **実機確認をすり抜けたのはそのためである。**
      //
      // ## ⛔ 無条件に残してはいけない
      //
      // **これらのフラグは端末に付いていて、アカウントには付いていない。**
      // トークンが消えた後に新しいゲストが作られると、
      // **古い状態を新しいゲストが引き継ぐ**:
      //
      //   連携済みユーザーが更新 -> hg_token は消え、フラグは残る
      //   -> 「ゲストとして始める」-> 新しいゲスト -> オンボーディングの途中で kill
      //   -> 再起動で case B がフラグを見てホームへ
      //   -> 名前「ゲスト」+ キャラ未選択（2026-07-02 に直した症状）
      //
      // 🔵 **フラグの持ち主はゲストトークンの持ち主である。**
      //    持ち主が残るときだけ、持ち物も残す。
      //    それ以外の新しいキーは、変わらず既定で消える。
      final guestOwned = <String, String>{};
      if (hasGuest) {
        for (final key in _guestOwnedKeys) {
          final value = await _storage.read(key: key);
          if (value != null && value.isNotEmpty) guestOwned[key] = value;
        }
      }

      await _storage.deleteAll();
      if (hasGuest) {
        await _storage.write(key: _guestTokenKey, value: guest);
        for (final entry in guestOwned.entries) {
          await _storage.write(key: entry.key, value: entry.value);
        }
      }
      await prefs.setBool(kSecureStorageInitializedKey, true);
    } catch (e) {
      // 掃除に失敗してもアプリは起動させる。次回起動で再試行される
      // (マーカーが立たないため)。
      debugPrint('[ApiClient] secure storage の初回掃除に失敗: $e');
    }
  }

  Future<String?> _readSecure(String key) async {
    await _storageReady;
    return _storage.read(key: key);
  }

  Future<void> _writeSecure(String key, String value) async {
    await _storageReady;
    await _storage.write(key: key, value: value);
  }

  Future<void> _deleteSecure(String key) async {
    await _storageReady;
    await _storage.delete(key: key);
  }

  /// 🔴 【FEAT-542】`SharedPreferences` 側も**同じゲートを通す**。
  ///
  /// 移設（[_migrateDeviceFlagsToPrefs]）と修復（[_repairGuestModeFlag]）が
  /// **`SharedPreferences` に書く**ようになったので、待たずに読むと
  /// **移設前の空の状態を読む** —— 既存ゲスト全員が「未設定」に見え、
  /// オンボーディングへ送られて名前とキャラを上書きされる。
  ///
  /// ⚠️ 移設と修復の**中**からは呼ばないこと（自分を待って止まる）。
  ///    あちらは `SharedPreferences.getInstance()` を直接使う。
  Future<SharedPreferences> _prefs() async {
    await _storageReady;
    return SharedPreferences.getInstance();
  }
  final Ref _ref;

  // ── 【2026-07-07】5xx sentinel: in-flight degradation 検知 ────────
  // 30 秒スライディングウィンドウで 5xx を連続 3 回検知したら
  // ConnectionErrorOverlay を自動発火し、ユーザーに Backend 障害を通知する。
  //
  // 【2026-07-09 変更】旧: maintenanceStatusProvider.markEnabledFromHeader() 経由で
  //   MaintenanceOverlay を発火していたが、admin 意図の maintenance と mobile 側の
  //   推測 (通信/サーバエラー) を混同していた設計を再構築。
  //   新: connectionErrorProvider.mark() 経由で ConnectionErrorOverlay を発火する。
  //   admin 意図の maintenance は `X-Maintenance: 1` header と `/api/maintenance/`
  //   probe が独立して maintenanceStatusProvider に反映する。
  //
  // 発火経路: connectionErrorProvider.mark() → ConnectionErrorOverlay 表示
  // 復旧経路:
  //   1. 次の 2xx レスポンスで自動的に connectionErrorProvider.clear() 呼出
  //      (Backend が復旧した信号 = overlay 出し続ける必要なし)
  //   2. user が ConnectionErrorOverlay の「再試行」ボタンで `/api/health/` を叩く
  //
  // なぜ 3 回 threshold?
  //   - 1-2 回の 5xx は Render deploy 中の一時的な失敗の可能性が高い
  //   - 3 回連続 = 継続的な障害 = user に通知する価値がある
  //   - 30 秒 window = deploy の一時失敗 (通常 5-10 秒) は超えない
  static const Duration _kSentinelWindow = Duration(seconds: 30);
  static const int _kSentinelThreshold = 3;
  int _consecutive5xx = 0;
  DateTime? _first5xxAt;

  void _record5xx() {
    final now = DateTime.now();
    if (_first5xxAt == null ||
        now.difference(_first5xxAt!) > _kSentinelWindow) {
      // ウィンドウ超過 → カウンタリセット & 新しいウィンドウ開始
      _first5xxAt = now;
      _consecutive5xx = 1;
    } else {
      _consecutive5xx++;
    }
    if (_consecutive5xx >= _kSentinelThreshold) {
      // Threshold 到達: ConnectionErrorOverlay 発火 + カウンタリセット
      _ref.read(connectionErrorProvider.notifier).mark();
      _consecutive5xx = 0;
      _first5xxAt = null;
    }
  }

  void _reset5xxCounter() {
    if (_consecutive5xx > 0 || _first5xxAt != null) {
      _consecutive5xx = 0;
      _first5xxAt = null;
    }
    // 【2026-07-09】業務 API から 2xx を受信 = Backend 復旧の信号。
    // ConnectionErrorOverlay も自動 clear して user を通常 UI に戻す。
    // admin 設定 maintenance (maintenanceStatusProvider) は独立して管理される
    // (X-Maintenance header や /api/maintenance/ probe が真実値のため触らない)。
    _ref.read(connectionErrorProvider.notifier).clear();
    // 【BUG-158 (2026-09-12)】レート制限も下ろす。
    //
    // 🔵 **これが効くのが重要**。枯れるのは anon バケット (IP キー) と
    // user バケット (user.pk) の**別々**なので、起動プローブが 429 でも
    // 認証済みの業務 API は通っていることがある。その場合この 1 行で
    // overlay が自然に消え、動いているアプリを塞ぎ続けずに済む。
    _ref.read(rateLimitProvider.notifier).clear();
  }


  // ── 【BUG-147 Phase B-2】無効なゲストトークンからの回復 ──────────────
  //
  // ## 何を直しているのか
  //
  // 端末に**サーバがもう知らないゲストトークン**が残ると、全 API が 401 になり、
  // アプリに脱出経路が無かった。FEAT-193 が「一時的な 401 でゲストトークンを
  // 捨てない」と決めたのは正しい (捨てると端末初期化と同等のデータロスになる)。
  // 欠けていたのは **恒久的に無効なトークンの出口** だった。
  //
  // Phase B-1 で backend が `auth_guest_token_invalid` という機械可読な code を
  // 返すようになったので、「恒久的に無効」と「一時的な 401」を判別できる。
  //
  // 🔴 **`401` そのものをトリガにしてはならない。** 判別を外した瞬間、
  // FEAT-193 が防いだ事故に戻る。
  //
  // ## 必須ガード 3 点
  //
  //   1. リクエスト単位の再試行フラグ … 再送も 401 なら無限ループになる
  //   2. `guest-init` の直列化        … 起動時は 10 本以上が同時に 401 になる
  //   3. `guest-init` 失敗は握り潰す  … 失敗時に再帰させない (次回起動でやり直す)
  //
  // ガード 2 が無いと **1 回の起動で throttle (5/hour、IP 単位) を使い切る**。
  // 以後 1 時間、正規の新規ユーザーもゲスト開始できず、同一 IP 共有
  // (社内 Wi-Fi / NAT) では他端末も巻き添えになる。

  /// サーバが「そのゲストトークンは存在しない」と断定したときの code。
  /// **これ以外の 401 では絶対にゲストトークンを触らない** (FEAT-193 回帰防止)。
  static const String kGuestTokenInvalidCode = 'auth_guest_token_invalid';

  /// ガード 1: リクエスト単位の再試行フラグ (`RequestOptions.extra` のキー)。
  static const String kRetriedExtraKey = 'bug147_guest_reinit_retried';

  /// ガード 2: `guest-init` を 1 本に集約する mutex。
  /// 同時に 10 本が 401 になっても、POST は 1 回しか出ない。
  Completer<bool>? _guestReinitInFlight;

  /// 【BUG-162 (2026-09-12)】ガード 4: **意図的に消したセッションを
  /// 復活させない。**
  ///
  /// 🔴 アカウント削除の後片付け中は、古いゲストトークンを持ったリクエストが
  /// まだ飛んでいる。サーバはもうそのセッションを知らないので
  /// `auth_guest_token_invalid` を返し、**BUG-147 の再作成が善意で
  /// 新しいゲストセッションを作ってしまう**。
  ///
  /// ⚠️ そうなると「削除したのに、名前が『ゲスト』の新しいプロフィールで
  /// ホームに着く」——**名前もキャラも一度も選ばせずにゲームが始まる**。
  /// これは 2026-07-02 に一度直した症状と同じ形である。
  ///
  /// 🔵 解除は [saveGuestToken] だけが行う。**ユーザーが意図してゲストを
  /// 始めたときに自動的に戻る**ので、呼び出し側に解除を配る必要がない。
  ///
  /// 🔴 **`static` であることが要件である（2026-09-12 の実機確認で判明）。**
  ///
  /// `apiClientProvider` は **`AutoDisposeProvider`** である
  /// (`api_client.g.dart` の `AutoDisposeProvider<ApiClient>.internal`)。
  /// `account_page._executeDelete()` は `await` を挟んで `ref.read` を
  /// 3 回するので、**毎回同じインスタンスが返る保証がない**。
  ///
  /// ⚠️ インスタンス変数にすると「フラグを立てたインスタンス」と
  /// 「401 を処理するインスタンス」が**別物になりうる** ——
  /// 最初の実装はこれで、**実機では抑止が効かずトーストが出た**。
  /// 症状が消えていたのは [clearLocalStateForAccountDeletion] が
  /// **2 度目にトークンを消していた**からで、抑止は engage していなかった。
  ///
  /// 🔵 アプリには実質 1 系統しか無いので `static` で意味が変わらない。
  /// テストからは [debugResetGuestReinitSuppression] で戻す。
  static bool _guestReinitSuppressed = false;

  /// 【BUG-162】以後の自動ゲストセッション再作成を止める。
  ///
  /// 🔴 **アカウント削除を始める前に呼ぶ。** サーバ削除の応答を待ってからだと
  /// **その間に飛んでいたリクエストの 401 が先に着く**ことがあり、
  /// 再作成が走ってしまう（実機で実際に起きた）。
  /// 削除が失敗したときは [allowGuestSessionRecreation] で戻す。
  ///
  /// 🔵 プロセス内だけの状態なので、再起動すれば戻る
  /// (そのときトークンは無いので、復活させる対象もない)。
  static void suppressGuestSessionRecreation() {
    _guestReinitSuppressed = true;
  }

  /// 【BUG-162】抑止を戻す。**アカウント削除がサーバ側で失敗したとき**に呼ぶ。
  ///
  /// ⚠️ 削除できていないのに抑止を残すと、そのセッションが後で無効になっても
  /// **BUG-147 の出口が使えないまま詰む**。
  static void allowGuestSessionRecreation() {
    _guestReinitSuppressed = false;
  }

  /// テスト用: `static` な抑止状態を初期化する。
  ///
  /// ⚠️ `static` なのでテスト間で持ち越される。**抑止を触るテストは
  /// `setUp` でこれを呼ぶこと。**
  @visibleForTesting
  static void debugResetGuestReinitSuppression() {
    _guestReinitSuppressed = false;
  }

  /// テスト用: `guest-init` が実際に走った回数。
  /// 「同時 10 本の 401 → guest-init は 1 回」をテストから観測するための counter。
  int debugGuestReinitCount = 0;

  /// ゲストセッションを作り直す。**同時に何本呼ばれても POST は 1 回**。
  ///
  /// 戻り値は成功可否。失敗しても例外は投げない (ガード 3) ——
  /// 呼び出し側は元の 401 をそのまま上位へ伝播させ、次回起動でやり直す。
  ///
  /// 古いトークンは**成功したときだけ**上書きする。先に削除してしまうと、
  /// `guest-init` が失敗したときに「無効なトークン」が「トークン無し」に
  /// 変わるだけで何も得しない。`GuestInitView` は
  /// `authentication_classes = []` なので、古いヘッダが付いていても無視される。
  Future<bool> _reinitGuestSession() async {
    // ガード 4 (BUG-162): 意図的に消したセッションは復活させない。
    if (_guestReinitSuppressed) return false;
    final inFlight = _guestReinitInFlight;
    if (inFlight != null) return inFlight.future;  // ガード 2

    final completer = Completer<bool>();
    _guestReinitInFlight = completer;
    try {
      debugGuestReinitCount++;
      final res = await _dio.post(
        '/auth/guest-init/',
        // guest-init 自身が 401 になっても回復を試みない (無限ループ防止)
        options: Options(extra: {kRetriedExtraKey: true}),
      );
      final data = res.data;
      final token = data is Map ? data['token'] as String? : null;
      if (token != null && token.isNotEmpty) {
        // ⚠️ 【BUG-162】`saveGuestToken()` は通さない —— あちらは抑止フラグを
        //    解除するので、**自動再作成が自分で自分の抑止を解いてしまう**。
        await _writeSecure(_guestTokenKey, token);
        // 【UX 判断】黙って進めない。データは戻らない (guest-init は新しい空の
        // プロフィールを作る) ので、「同じ続きが見えない」ことに気付けないまま
        // 使い始めるほうが不親切だと判断した。サビ口調で 1 行だけ出す。
        ToastCenter.showSabi(
          ServiceL10n.current.coreGuestSessionRecreatedSabi_message,
        );
        completer.complete(true);
      } else {
        completer.complete(false);
      }
    } catch (_) {
      completer.complete(false);  // ガード 3: 握り潰す
    } finally {
      _guestReinitInFlight = null;
    }
    return completer.future;
  }


  /// 【BUG-147 Phase B-2】ゲスト 401 からの回復を試みる。
  ///
  /// 戻り値が `true` のときは **`handler.resolve()` 済み** なので、
  /// 呼び出し側はそのまま return すること (`handler` は 1 度しか呼べない)。
  ///
  /// 回復するのは次の条件がすべて揃ったときだけ:
  ///
  ///   * `code == auth_guest_token_invalid` (サーバが「知らない」と断定)
  ///   * このリクエストがまだ再試行していない (ガード 1)
  ///   * `guest-init` が成功した (ガード 3 = 失敗なら false を返して素通し)
  ///
  /// 再送も 401 になった場合は、再送リクエストに再試行フラグが立っているため
  /// 本メソッドは 2 度目の回復を試みない (ガード 1、Pre-mortem 3-c)。
  Future<bool> _tryRecoverGuestSession(
    DioException error,
    ErrorInterceptorHandler handler,
  ) async {
    final options = error.requestOptions;

    // ガード 1: 再試行済みなら何もしない (無限ループ防止)
    if (options.extra[kRetriedExtraKey] == true) return false;

    // code が一致するときだけ。**ここを外すと FEAT-193 の事故に戻る。**
    final apiError = ApiError.fromResponse(error.response?.data);
    if (apiError.code != kGuestTokenInvalidCode) return false;

    // ガード 2b: **すでに別のセッションに差し替わっていたら再作成しない。**
    //
    // mutex (ガード 2) は「同時に 401 になった分」しか束ねられない。`finally` で
    // `_guestReinitInFlight` を null に戻すため、**再作成が終わった後に 401 が
    // 返ってきたリクエスト**は mutex に捕まらず 2 回目の guest-init を起こす。
    //
    // 起動直後は全リクエストが同時に飛ぶわけではない。実機ログでは
    // `/api/challenges/` が他より 1 秒遅れて発火しており、古いトークンを載せた
    // まま飛んで再作成後に 401 で戻る、という条件が実際に成立していた。
    //
    // 害は 2 つ。**throttle (5/hour、IP 単位) を余計に消費する**ことと、
    // **孤児のゲストセッションが増える** (再作成のたびに空の PlayerProfile が
    // 1 つ作られる) こと。
    //
    // このリクエストが使ったトークンと、いま保存されているトークンが違うなら、
    // **別の誰かが既に作り直した後**である。再作成は要らず、再送だけでよい。
    final usedAuth = options.headers['Authorization'] as String?;
    final currentGuest = await getGuestToken();
    final alreadyReplaced = currentGuest != null &&
        currentGuest.isNotEmpty &&
        usedAuth != null &&
        usedAuth != 'GuestToken $currentGuest';

    if (!alreadyReplaced) {
      // ガード 2/3: 直列化された guest-init。失敗しても例外は出ない。
      final ok = await _reinitGuestSession();
      if (!ok) return false;
    }

    // 元のリクエストを **1 回だけ** 再送する。
    // `_dio.fetch` は interceptor を再走させるので、onRequest が新しい
    // ゲストトークンを Authorization に載せ直す。
    options.extra[kRetriedExtraKey] = true;
    try {
      final response = await _dio.fetch<dynamic>(options);
      handler.resolve(response);
      return true;
    } catch (_) {
      // 再送も失敗 → 元の 401 を上位へ (handler は呼ばずに false を返す)
      return false;
    }
  }

  ApiClient(this._ref) {
    _dio = Dio(
      BaseOptions(
        baseUrl: kApiBaseUrl,
        connectTimeout: const Duration(seconds: 60),
        receiveTimeout: const Duration(seconds: 60),
        // 【BUG-FIX (2026-05-31)】Content-Type を BaseOptions.headers に固定しない。
        // 旧: headers: {'Content-Type': 'application/json'} を全リクエストに静的設定。
        // 問題: FormData 送信時、Dio は内部で lowercase キー 'content-type' に
        //       'multipart/form-data; boundary=...' をセットするが、BaseOptions の
        //       'Content-Type' (大文字) は Dart Map のキー大小文字区別で別エントリとして
        //       残り、両方が HTTP ヘッダーに追加される。Django が受信すると DRF は
        //       最初の 'Content-Type: application/json' を優先して JSONParser を選択し
        //       request.FILES が空になる → お問い合わせ添付画像がメールに届かない。
        // 修正: BaseOptions.headers から Content-Type を除去し Dio の自動設定に委ねる。
        //   - Map/JSON データ: Dio の DefaultTransformer が 'application/json' を付与
        //   - FormData: Dio が 'multipart/form-data; boundary=...' を正しく付与
        // (JSON リクエストへの影響なし: Dio のデフォルト動作で同じ Content-Type が付与される)
      ),
    );

    // 【FEAT-476】DioCacheInterceptor を非同期で初期化してインデックス 0 に挿入。
    // Hive.initFlutter() は main() 冒頭で完了済み (Pre-mortem S4)。
    // ignore: discarded_futures
    _initCacheInterceptor();

    // 【BUG-160 (2026-09-12)】HTTP breadcrumb を Sentry に積む。
    //
    // 🔴 **BUG-158 の調査で実際に詰まった** —— 429 の Sentry イベントには
    // lifecycle / network / battery しか無く、「429 はこの 1 本だけか、
    // 全 API に出ているのか」が判別できなかった。他の 429 が breadcrumb に
    // 並んでいれば、グローバル throttle が枯れたことはその場で確定した。
    //
    // ⚠️ 積むのは **method / URL / status code / 所要時間だけ**。
    // body もヘッダーも入れない (`sentry_breadcrumb_interceptor.dart`)。
    // URL の伏せ字は `beforeBreadcrumb` 側で行う (`main.dart`)。
    //
    // ⚠️ `probeDio` には足さない。あちらは BUG-147 Phase C の都合で
    // **インターセプタを 1 つも持たない**ことが不変条件である。
    _dio.interceptors.add(SentryBreadcrumbInterceptor());

    _dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          // 【FEAT-489 Phase 2E】Accept-Language の付与。
          //
          // Backend の I18nMiddleware は
          //   ① Accept-Language → ② PlayerSettings.preferred_language → ③ ja
          // の順で locale を解決するが、Mobile はこれまで **どちらも送っていなかった**
          // ため、Phase 4 で追加した `_en` field 群 (migration 0191-0196) が
          // 100% 到達不能で常に日本語が返っていた。
          //
          // 【2026-08-02】当初 Backend は ①② が逆順だった。`preferred_language`
          // は `default='ja'` で「未設定」を表現できないため、認証済ユーザーは
          // 常に 1 段目で ja に確定し、**このヘッダが読まれることが無かった**。
          // 「US で新規インストール → 英語 UI → 設定画面を開かない」という
          // 最も普通の導線が 2 言語混在になっていたため、Backend 側の順序を
          // 入れ替えた (doc/design/backend_i18n.md §2.4)。
          //
          // 送る値は **アプリが実際に解決している locale** (`ServiceL10n.current`)。
          // 端末 locale (`Platform.localeName` 等) を送ってはいけない —— UI は
          // BUG-27 対策で `Locale('ja','JP')` 固定なので、端末 locale を送ると
          // 「UI は日本語なのにサビの台詞とお知らせだけ英語」という 1 画面 2 言語
          // 混在になる (Pre-mortem S5)。
          //
          // 現状の実効挙動は「`ja` を明示送信」= Backend の default と同値なので無風。
          // Phase 5 で言語切替 UI が入ると ServiceL10n が追従するため、ここは
          // 追加対応なしで正しい locale を送り始める。
          options.headers['Accept-Language'] = ServiceL10n.current.localeName;

          // FEAT-188: 認証ヘッダーの自動付与
          // 通常トークンが存在すれば `Token <token>`、
          // 無ければゲストトークンがあるか確認し `GuestToken <token>` を付与する。
          // 両方とも無ければ無認証リクエスト（/auth/guest-init/ 等）。
          final userToken = await _readSecure(_tokenKey);
          if (userToken != null && userToken.isNotEmpty) {
            options.headers['Authorization'] = 'Token $userToken';
          } else {
            final guestToken = await _readSecure(_guestTokenKey);
            if (guestToken != null && guestToken.isNotEmpty) {
              options.headers['Authorization'] = 'GuestToken $guestToken';
            }
          }
          handler.next(options);
        },
        onResponse: (response, handler) {
          // 【FEAT-463】X-Maintenance: 1 header 検知 → maintenance overlay 起動。
          // 【Pre-mortem S2】循環参照対策: ApiClient は @riverpod 経由で Ref を
          // 直接保持しており (既存 onError の authProvider 読み取りと同じ設計)、
          // ここでの `_ref.read()` はビルド時の watch チェーンを作らない単発の
          // 読み取りのため、ProviderContainer への WeakReference 等の追加機構は
          // 不要 (既存 authProvider 連携と同じ安全なパターンを踏襲)。
          if (response.headers.value('x-maintenance') == '1') {
            _ref.read(maintenanceStatusProvider.notifier).markEnabledFromHeader();
          }
          // 【2026-07-07】5xx sentinel: 2xx 応答時はカウンタリセット。
          // Backend が復旧したら sentinel が再計測を新規に始められるようにする。
          final code = response.statusCode ?? 0;
          if (code >= 200 && code < 300) {
            _reset5xxCounter();
          }
          handler.next(response);
        },
        onError: (error, handler) async {
          // 【2026-07-07】5xx sentinel: 5xx を連続 3 回検知したら maintenance
          // overlay を自動発火する。timeout (connectionTimeout/receiveTimeout)
          // は 5xx とは別扱い = ローカルネットワーク障害を Backend 障害と混同しない。
          final code = error.response?.statusCode ?? 0;
          if (code >= 500 && code < 600) {
            _record5xx();
          }
          // 【FEAT-541 (2026-09-06)】アカウント停止の検知。
          //
          // 🔴 **403 かつ code 一致のときだけ**発火する。
          //    通信エラー / タイムアウト / 500 では絶対に出さない ——
          //    無実のユーザーに停止画面を見せることになる。
          //    FEAT-483 / BootGate v1 が踏んだ「メンテしていないのにメンテ画面」
          //    と同じ罠なので、status だけをトリガにしない。
          //
          // ⚠️ ここでトークンは消さない。ログアウトはユーザーの操作に委ねる
          //    (overlay の「ログアウト」ボタン)。勝手に消すと、解除後の
          //    「再試行」で復帰する経路が無くなる。
          if (code == 403) {
            final data = error.response?.data;
            if (ApiError.fromResponse(data).code == kAccountSuspendedErrorCode) {
              _ref.read(accountSuspendedProvider.notifier).markSuspended();
            }
          }
          if (error.response?.statusCode == 401) {
            // FEAT-193: 401 ハンドリングを「通常ユーザーのセッション失効」だけに限定。
            //
            // 旧実装（FEAT-188）はゲスト時の 401 で deleteGuestToken() を呼んでいたが、
            // これは致命的バグだった:
            //   - ショップ等で一時的に 401 が返ると、それだけでゲストトークンを破棄
            //   - 結果ホームに戻った際に「習慣・ToDo・タイムラインが取得不能」状態に
            //   - 端末初期化と同等のデータロス（ゲストはサーバー連携前のため復旧不可）
            //
            // 新方針:
            //   - 通常ユーザートークンが付いていて 401: 期限切れとしてログアウト相当の処理
            //   - ゲストトークン or 無認証で 401: 個別 API のエラーとして上位に伝播するだけで、
            //     ローカルのゲストトークンは保持する。ゲストセッション全体の期限切れ判定は
            //     サーバー側のバッチ処理に任せ、フロントでは触らない。
            //
            // ゲストトークンを削除する経路は「明示的な操作」のときだけ:
            //   - 連携完了時の _verifyAndPromoteGuest()（FEAT-188 で実装済み）
            //   - 衝突確認後の confirmPromote()（FEAT-189 で実装済み）
            //   - 将来的なアカウント削除フロー
            final userToken = await _readSecure(_tokenKey);
            if (userToken != null && userToken.isNotEmpty) {
              await deleteToken();
              _ref.read(authProvider.notifier).markSessionExpired();
            } else {
              // 【BUG-147 Phase B-2】ゲスト経路。**code が
              // `auth_guest_token_invalid` のときだけ**セッションを作り直す。
              //
              // 素の 401 (code 無し = DRF 既定の `{'detail': ...}` → 'unknown') や
              // 別 code では**何もしない** —— FEAT-193 が防いだデータロス事故を
              // 再発させないための境界線がここ。
              final recovered = await _tryRecoverGuestSession(error, handler);
              if (recovered) return;  // handler.resolve 済み
            }
            // else: ゲスト or 無認証時はトークン保持。エラーは handler.next で伝播。
          }
          handler.next(error);
        },
      ),
    );
  }

  Dio get dio => _dio;

  // ── 【BUG-147 Phase C】疎通確認専用 Dio (インターセプタ無し) ──────────
  //
  // ## なぜ probe を分けるのか
  //
  // `_dio` の `onRequest` は **全リクエストに** 認証ヘッダを付ける。その結果、
  // 端末に古いトークンが残っていると `/health/` まで 401 になり、
  // **「認証が壊れているときにこそ使いたい endpoint が、認証に引きずられて
  // 使えなくなる」**という目的と正反対の状態になっていた (BUG-147 の症状)。
  //
  // backend 側 (Phase A / A-2) で `authentication_classes = []` を宣言したので
  // 今は 401 にならないが、それだけでは 2 つ穴が残る:
  //
  //   1. **backend の宣言漏れに無防備**。走査テストが漏れを防ぐのは backend を
  //      直せる場合の話で、**クライアントが probe に認証を混ぜている構造**は残る
  //   2. **`validateStatus: (_) => true` のため Phase B が効かない**。Dio が 401 を
  //      エラー扱いしないので `onError` を通らず、**probe と再試行ボタンだけ**
  //      Phase B の回復経路から外れる
  //
  // 2 が実質的な理由。**Phase B と C は片方だけでは穴が残る。**
  //
  // probe に認証は元々不要である (`/health/` `/maintenance/` はどちらも
  // `AllowAny` + `authentication_classes = []`)。付いていたのは
  // 「全リクエストに付ける」インターセプタの副作用でしかない。
  Dio? _probeDio;

  /// 疎通確認専用の Dio。**インターセプタを 1 つも持たない。**
  ///
  /// 用途は `BootGate._probeHealth` と `ConnectionErrorOverlay._onRetry` の 2 箇所。
  /// 業務 API には使わないこと (認証ヘッダも cache も 5xx sentinel も効かない)。
  Dio get probeDio {
    return _probeDio ??= Dio(
      BaseOptions(
        baseUrl: kApiBaseUrl,
        connectTimeout: const Duration(seconds: 60),
        receiveTimeout: const Duration(seconds: 60),
      ),
    );
  }

  /// 【FEAT-476】DioCacheInterceptor を非同期で初期化して Dio に登録する。
  ///
  /// 対象 endpoint の service 側が CacheOptions.toOptions() を付与した GET のみ
  /// キャッシュされる (CachePolicy.request = opt-in 設計)。
  /// Auth interceptor より手前 (index 0) に挿入して cache hit 時は auth read をスキップ。
  ///
  /// テスト環境 / path_provider 未初期化時は MissingPluginException が throw されるため
  /// try-catch で吸収する。cache なしでも全機能は動作する (graceful degrade)。
  /// 【FEAT-489 Phase 2G-a】言語切替時に破棄するためのハンドル。
  /// interceptor 初期化前 / テスト環境では null (clearResponseCache が no-op になる)。
  CacheStore? _cacheStore;

  /// 【FEAT-489 Phase 2G-a / Phase 2E S6 の回収】応答キャッシュを全破棄する。
  ///
  /// FEAT-476 の `DioCacheInterceptor` は ja で取得した応答を保持しているため、
  /// **言語を切り替えても破棄しないと「切り替えたのに日本語のまま」になる**。
  /// Backend は `Vary: Accept-Language` を返しているが、dio 側がこれを解釈する
  /// 保証がないので、切替時にこちらから明示的に捨てる。
  Future<void> clearResponseCache() async {
    try {
      await _cacheStore?.clean();
    } catch (_) {
      // 破棄失敗は致命ではない (最悪 maxStale 7 日で自然に切れる)
    }
  }

  Future<void> _initCacheInterceptor() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final store = HiveCacheStore(dir.path, hiveBoxName: 'sabiowl_api_cache');
      _cacheStore = store;
      final options = CacheOptions(
        store: store,
        policy: CachePolicy.request,
        hitCacheOnErrorExcept: [401, 403],
        maxStale: const Duration(days: 7),
        priority: CachePriority.normal,
        allowPostMethod: false,
      );
      _dio.interceptors.insert(0, DioCacheInterceptor(options: options));
    } catch (_) {
      // テスト / path_provider 未初期化環境: cache interceptor をスキップ
    }
  }

  // ── 通常ユーザートークン ─────────────────────────────────────

  Future<void> saveToken(String token) async {
    // 【BUG-156 (2026-09-11)】`token_saved_at` の書き込みを削除した。
    // **書かれるだけで読まれていない死んだキー**だった (読み出し 0 件)。
    await _writeSecure(_tokenKey, token);
  }

  Future<void> deleteToken() async {
    await _deleteSecure(_tokenKey);
    // 【FEAT-542】検証時刻は `SharedPreferences` へ移設済。
    final prefs = await _prefs();
    await prefs.remove(kPrefsTokenValidatedAt);
    // is_registered / profile_setup_completed_for / guest_mode は削除しない
    // guest_mode は正式登録完了時のみ setGuestMode(false) で削除する
    //
    // 🔵 【FEAT-542】`profile_setup_completed_for` を残してよいのは、
    //    **値が持ち主を持っている**からである。別の身元で戻ってきたら
    //    一致しないので「未設定」と読まれる ——
    //    **残っていても他人には効かない。**
  }

  Future<String?> getToken() async {
    return _readSecure(_tokenKey);
  }

  // ── ゲストトークン（FEAT-188）──────────────────────────────────

  /// ゲストトークンを保存する（guest-init 成功時に呼ぶ）。
  ///
  /// 🔵 【BUG-162 (2026-09-12)】**ここを通ると再作成の抑止が解ける。**
  /// 呼ぶのは「ユーザーが意図してゲストを始めた / 連携を解除した」経路だけで、
  /// BUG-147 の自動再作成は `_writeSecure` を直接使うので**ここを通らない**。
  ///
  /// ⚠️ 解除を `startAsGuest` 等の呼び出し側に配らないこと ——
  /// **配り忘れた 1 箇所が「再作成が永久に止まったまま」になる**。
  /// 書き込みの入口 1 つに寄せておけば、経路が増えても自動的に追従する。
  Future<void> saveGuestToken(String token) async {
    _guestReinitSuppressed = false;
    await _writeSecure(_guestTokenKey, token);
  }

  /// 保存されているゲストトークンを取得する。
  Future<String?> getGuestToken() async {
    return _readSecure(_guestTokenKey);
  }

  /// ゲストトークンを削除する（正式昇格成功時 / 失効検知時）。
  Future<void> deleteGuestToken() async {
    await _deleteSecure(_guestTokenKey);
  }

  /// 【BUG-162 (2026-09-12)】アカウント削除時に、secure storage 側の
  /// ローカル状態を**まとめて**消す。
  ///
  /// 🔴 `account_page._clearOnboardingLocalData()` は `has_seen_tutorial` と
  /// `guest_mode` を **`SharedPreferences` から**消していた。
  /// **このキーは secure storage にある**ので、**何も消えていなかった**。
  ///
  /// ⚠️ 同メソッドのコメントは「オンボーディング関連のローカル状態も全削除して
  /// **完全クリーンスタート**にする」と宣言している ——
  /// **宣言していることが起きていなかった。**
  ///
  /// 🔵 残っていた 2 つは**どちらも起動時の行き先を決めるキー**である
  /// (`app_router.dart` の `_performAuthCheck` の case B' と C)。
  /// 消え残ると、アカウントを消したのに「前の続き」として扱われる。
  ///
  /// ⚠️ **`deleteToken()` とは別物である。** あちらは「一時的に離れる」
  /// ログアウト用で、`is_registered` / `profile_setup_completed_for` /
  /// `guest_mode` を **意図的に残す**
  /// （再ログイン時にオンボーディングを再表示しないため）。
  /// アカウント削除は「完全にやり直したい」意思表示なので、全部消す。
  ///
  /// 🔵 【FEAT-542】4 キーは `SharedPreferences` へ移したので、
  /// ここも両方を消す。⚠️ 旧キーの `_deleteSecure` を**残している**のは、
  /// 移設前の版から更新してきた端末に取り残しがあり得るためである。
  Future<void> clearLocalStateForAccountDeletion() async {
    await _deleteSecure(_tokenKey);
    await _deleteSecure(_guestTokenKey);
    await _deleteSecure(_legacyTokenValidatedAtKey);
    await _deleteSecure(_legacyRegisteredKey);
    await _deleteSecure(_legacyTutorialKey);
    await _deleteSecure(_legacyGuestModeKey);
    final prefs = await _prefs();
    await prefs.remove(kPrefsTokenValidatedAt);
    await prefs.remove(kPrefsIsRegistered);
    await prefs.remove(kPrefsGuestMode);
    await prefs.remove(kPrefsProfileSetupCompletedFor);
  }

  /// 登録済みかどうかを確認する
  Future<bool> isRegistered() async {
    final prefs = await _prefs();
    return prefs.getBool(kPrefsIsRegistered) ?? false;
  }

  /// 登録済みフラグを保存する（初回認証成功時に呼ぶ）
  Future<void> markAsRegistered() async {
    final prefs = await _prefs();
    await prefs.setBool(kPrefsIsRegistered, true);
  }

  // ── 【FEAT-542】プロフィール設定の完了 ────────────────────────
  //
  // 🔴 **`has_seen_tutorial` の後継である。** 旧キーは
  // 「チュートリアルを見たか」と「プロフィール設定が終わったか」を
  // 兼任しており、**分岐に使われていたのは後者だけ**だった。

  /// いま持っている資格情報の指紋。**これが「現在の身元」である。**
  ///
  /// ⚠️ ユーザートークンを優先する。両方あるのは昇格の途中だけで、
  /// そのとき正しい身元はユーザー側である。
  /// 🔵 1 本も無ければ `null` —— 行き先は認証画面なので、答えは使われない。
  Future<String?> currentIdentity() async {
    final user = await _readSecure(_tokenKey);
    if (user != null && user.isNotEmpty) return profileSetupIdentityOf(user);
    final guest = await _readSecure(_guestTokenKey);
    if (guest != null && guest.isNotEmpty) return profileSetupIdentityOf(guest);
    return null;
  }

  /// いまの身元がプロフィール設定を終えているか。
  Future<bool> isProfileSetupCompleted() async => isProfileSetupCompletedFor(
        await currentIdentity(),
        prefs: await _prefs(),
      );

  /// いまの身元のプロフィール設定を「完了」として記録する。
  Future<void> markProfileSetupCompleted() async =>
      markProfileSetupCompletedFor(
        await currentIdentity(),
        prefs: await _prefs(),
      );

  // ── ゲストモード ─────────────────────────────────────────────

  /// ゲストモードかどうかを確認する
  Future<bool> isGuestMode() async {
    final prefs = await _prefs();
    return prefs.getBool(kPrefsGuestMode) ?? false;
  }

  /// ゲストモードフラグを設定する（false 時はキーを削除）
  Future<void> setGuestMode(bool value) async {
    final prefs = await _prefs();
    if (value) {
      await prefs.setBool(kPrefsGuestMode, true);
    } else {
      await prefs.remove(kPrefsGuestMode);
    }
  }

  // ── トークン検証キャッシュ ────────────────────────────────────

  /// トークン最終サーバー検証日時を取得する
  Future<DateTime?> getTokenValidatedAt() async {
    final prefs = await _prefs();
    final val = prefs.getString(kPrefsTokenValidatedAt);
    return val != null ? DateTime.tryParse(val) : null;
  }

  /// トークン最終サーバー検証日時を現在時刻で更新する
  Future<void> updateTokenValidatedAt() async {
    final prefs = await _prefs();
    await prefs.setString(
        kPrefsTokenValidatedAt, DateTime.now().toIso8601String());
  }
}
