// 【BUG-156 (2026-09-11)】401 のあとユーザーが自力で復帰できること。
//
// ## 何が起きていたか
//
// | # | 箇所 | 何が起きるか |
// |---|---|---|
// | ① | router の redirect | `sessionExpired` だけを見ており、それは**ワンショット**（AuthPage が即クリア）。クリア後にホームへ戻ると誰も止めない |
// | ② | 起動時のトークン検証 | 24 時間キャッシュがあり、サーバに一度も聞かずに home へ行く |
// | ③ | `FlutterSecureStorage` | iOS では **Keychain**。**アンインストールで消えない**ので ①② が再インストールで復活する |
//
// 🔴 **③ が「再インストールしても直らない」の答えである。**
//
// ## このファイルが守るもの
//
// | § | 縛り |
// |---|---|
// | 1 | 初回起動（マーカー無し）で secure storage が掃除される |
// | 1 | 🔴 **ゲストトークンだけは残る**（FEAT-193 の再発防止） |
// | 1 | 2 回目以降は掃除しない |
// | 1 | 🔴 掃除がキー列挙ではなく `deleteAll()` である（新しいキーも消える） |
// | 1 | 🔴 【BUG-167】ゲストトークンと一緒のときだけ `has_seen_tutorial` / `guest_mode` も残る（更新経路） |
// | 1 | 🔴 【BUG-167】ゲストトークンが無ければ両フラグは消える（別のゲストに引き継がせない） |
// | 1 | 🔴 【BUG-167 修復】v1.1.2 で消えた `guest_mode` を、ゲスト本人のときだけ戻す |
// | 1 | 🔴 【FEAT-542】移設が**掃除より後**に走る（順序を違えると既存ゲスト全員が「未設定」になる） |
// | 1 | 🔴 【FEAT-542】移設は旧キーを**自分で消し**、1 度しか走らない |
// | 2 | `unauthenticated` で login へ redirect / `checking` では動かない |
// | 3 | 🔴 **`AppRoutes` の全定数が 2 つの箱のどちらかに分類済み**（本体） |

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:sabiowl/core/api/api_client.dart';
import 'package:sabiowl/core/constants/preferences_keys.dart';
import 'package:sabiowl/core/router/app_router.dart';

const _kTokenKey = 'hg_token';
const _kGuestTokenKey = 'hg_guest_token';
const _kValidatedAtKey = 'token_validated_at';
const _kRegisteredKey = 'is_registered';
const _kTutorialKey = 'has_seen_tutorial';
const _kGuestModeKey = 'guest_mode';

// 🔵 【FEAT-542】移設後の置き場所。`kPrefs*` は `preferences_keys.dart` が真実値。

// ── secure storage の in-memory mock ─────────────────────────────────────
class _FakeSecureStorage {
  final Map<String, String> values = {};

  void install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async {
        final args = (call.arguments as Map?) ?? {};
        final key = args['key'] as String?;
        switch (call.method) {
          case 'read':
            return key == null ? null : values[key];
          case 'write':
            if (key != null) values[key] = args['value'] as String? ?? '';
            return null;
          case 'delete':
            if (key != null) values.remove(key);
            return null;
          case 'readAll':
            return Map<String, String>.from(values);
          case 'deleteAll':
            values.clear();
            return null;
          case 'containsKey':
            return key != null && values.containsKey(key);
          default:
            return null;
        }
      },
    );
  }

  void uninstall() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      null,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeSecureStorage storage;

  ApiClient buildClient() {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    return container.read(apiClientProvider);
  }

  setUp(() {
    storage = _FakeSecureStorage();
    storage.install();
  });

  tearDown(() => storage.uninstall());

  // ── §1 初回起動検知 ───────────────────────────────────────────────
  group('§1 再インストール検知で secure storage を掃除する', () {
    test('マーカー無し + トークンあり → トークンが消え、マーカーが立つ', () async {
      SharedPreferences.setMockInitialValues({});
      storage.values[_kTokenKey] = 'stale-token';
      storage.values[_kValidatedAtKey] = DateTime.now().toIso8601String();

      final token = await buildClient().getToken();

      expect(token, isNull, reason: '再インストール直後は掴んでいたトークンを手放す');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(ApiClient.kSecureStorageInitializedKey), isTrue);
    });

    test('マーカーあり + トークンあり → トークンは消えない', () async {
      SharedPreferences.setMockInitialValues({
        ApiClient.kSecureStorageInitializedKey: true,
      });
      storage.values[_kTokenKey] = 'live-token';

      expect(await buildClient().getToken(), 'live-token');
    });

    test('🔴 マーカー無し + ゲストトークンあり → ゲストトークンは残る', () async {
      // **ゲストのデータはゲストトークンでしか辿れない。**
      // サーバ側に PlayerProfile はあるが User が無いので
      // **ログインで取り戻せない** —— 失うと復旧経路がゼロになる。
      // FEAT-193 はまさにこの事故の再発防止で入った修正である。
      SharedPreferences.setMockInitialValues({});
      storage.values[_kGuestTokenKey] = 'guest-token';
      storage.values[_kTokenKey] = 'stale-token';

      final client = buildClient();
      expect(
        await client.getGuestToken(), 'guest-token',
        reason: 'ゲストトークンを消すとゲストのデータが永久に失われる',
      );
      expect(await client.getToken(), isNull, reason: 'ユーザートークンは消す');
    });

    test('🔴 BUG-167: 更新経路 —— ゲストトークンと一緒なら 2 つのフラグも残る', () async {
      // 更新では SharedPreferences が残るが、マーカーは v1.1.2 で新設されたので
      // 一度も書かれていない。つまり掃除が走る。
      //
      // 旧実装はここで tutorial を消していた。router の case B が
      // 「トークンあり + 設定未完了」と読み、既存ゲストをオンボーディングへ送って
      // **名前・性別・キャラを上書きしていた**。
      SharedPreferences.setMockInitialValues({});
      storage.values[_kGuestTokenKey] = 'guest-token';
      storage.values[_kTutorialKey] = 'true';
      storage.values[_kGuestModeKey] = 'true';
      storage.values[_kTokenKey] = 'stale-token';

      final client = buildClient();

      // 🔴 空振り検出: 掃除が実際に走ったこと。
      //    走っていなければ tutorial は「残った」のではなく「触られていない」。
      expect(await client.getToken(), isNull,
          reason: '掃除が走っていない。このテストは何も確かめていない');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(ApiClient.kSecureStorageInitializedKey), isTrue);

      expect(await client.getGuestToken(), 'guest-token');
      // 🔴 【FEAT-542】旧 `has_seen_tutorial` は移設され、
      //    「そのゲストがプロフィール設定を終えた」という意味になった。
      expect(
        await client.isProfileSetupCompleted(), isTrue,
        reason: '更新した既存ゲストの設定済みフラグが消えている。'
            'オンボーディングへ戻され、名前とキャラを上書きされる',
      );
      expect(
        await client.isGuestMode(), isTrue,
        reason: '更新した既存ゲストが連携済みとして扱われる。'
            '連携はユーザー用 API を叩いて 401 になり、'
            'ログアウトガードの fallback も止めなくなる',
      );
    });

    test('🔴 BUG-167: ゲストトークンが無ければ 2 つのフラグも消える', () async {
      // ⛔ 無条件に残すと、**古い「設定済み」を新しいゲストが引き継ぐ**。
      //    連携済みユーザーが更新 → 認証画面で「ゲストとして始める」
      //    → オンボーディングの途中で kill → 再起動で case B がホームへ送り、
      //    名前「ゲスト」+ キャラ未選択になる（2026-07-02 に直した症状）。
      SharedPreferences.setMockInitialValues({});
      storage.values[_kTokenKey] = 'stale-token';
      storage.values[_kTutorialKey] = 'true';
      storage.values[_kGuestModeKey] = 'true';

      final client = buildClient();

      expect(await client.getToken(), isNull,
          reason: '掃除が走っていない。このテストは何も確かめていない');
      expect(
        await client.isProfileSetupCompleted(), isFalse,
        reason: 'トークンを失ったのにフラグだけ残っている。'
            '次に作られるゲストが「設定済み」を引き継ぐ',
      );
      expect(await client.isGuestMode(), isFalse,
          reason: '持ち主のいない guest_mode が残っている');
    });

    test('🔴 BUG-167 修復: v1.1.2 で消えた guest_mode を戻す', () async {
      // 掃除はマーカーで一度しか走らないので、v1.1.2 で消えた分は
      // 掃除の修正だけでは戻らない。既存ゲストは startAsGuest を通らず
      // case B でホームへ行くので、**誰も guest_mode を書き直さない**。
      SharedPreferences.setMockInitialValues({
        ApiClient.kSecureStorageInitializedKey: true,
      });
      storage.values[_kGuestTokenKey] = 'guest-token';

      final client = buildClient();

      // 前提: 掃除は走っていない（マーカーあり）ので、トークンは触られていない。
      expect(await client.getGuestToken(), 'guest-token');
      expect(
        await client.isGuestMode(), isTrue,
        reason: 'v1.1.2 に更新済みのゲストが、連携済みとして扱われ続ける。'
            '連携がユーザー用 API に向かって 401 になる',
      );
    });

    test('🔴 BUG-167 修復: 昇格の途中（両トークンあり）では guest_mode を立てない', () async {
      // 昇格は saveToken -> deleteGuestToken -> setGuestMode(false) の順。
      // 途中で落ちると両方のトークンが残る。ここで立てると、
      // **連携済みのユーザーをゲストとして扱う**。
      SharedPreferences.setMockInitialValues({
        ApiClient.kSecureStorageInitializedKey: true,
      });
      storage.values[_kGuestTokenKey] = 'guest-token';
      storage.values[_kTokenKey] = 'user-token';

      final client = buildClient();

      expect(await client.getToken(), 'user-token',
          reason: '前提が崩れている。このテストは何も確かめていない');
      expect(await client.isGuestMode(), isFalse,
          reason: 'ユーザートークンがあるのに guest_mode を立てた');
    });

    test('BUG-167 修復: ゲストトークンが無ければ何も書かない', () async {
      SharedPreferences.setMockInitialValues({
        ApiClient.kSecureStorageInitializedKey: true,
      });

      final client = buildClient();

      expect(await client.isGuestMode(), isFalse);
      expect(storage.values.containsKey(_kGuestModeKey), isFalse,
          reason: '持ち主のいない guest_mode を書いた');
    });

    test('🔴 掃除は列挙ではなく deleteAll —— 未知のキーも消える', () async {
      // ⚠️ キーを列挙して消すと**あとで追加されたキーが漏れる**。
      //    このプロジェクトで 3 回続けて踏んだ形
      //    (BUG-152 → BUG-153 → FEAT-541)。
      SharedPreferences.setMockInitialValues({});
      storage.values[_kTokenKey] = 'stale-token';
      storage.values['some_future_key_nobody_listed'] = 'x';
      storage.values[_kRegisteredKey] = 'true';

      await buildClient().getToken();

      expect(
        storage.values.keys, isEmpty,
        reason: '列挙で消していると、リストに無いキーが残る',
      );
    });

    test('掃除に失敗してもアプリは起動する（マーカーは立たない）', () async {
      SharedPreferences.setMockInitialValues({});
      // 例外は握って debugPrint するだけ。次回起動で再試行される。
      final client = buildClient();
      await client.getToken();
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(ApiClient.kSecureStorageInitializedKey), isTrue);
    });

    test('token_saved_at は書かれない（死んだキーを削除した）', () async {
      SharedPreferences.setMockInitialValues({
        ApiClient.kSecureStorageInitializedKey: true,
      });
      await buildClient().saveToken('t');
      expect(storage.values.containsKey('token_saved_at'), isFalse);
    });
  });

  // ── §1.5 【FEAT-542】端末フラグの移設 ──────────────────────────────
  //
  // 🔴 **順序が本体である。** 掃除 (`deleteAll`) より先に移設が走ると、
  // 読む前に消えている。指示書 §4.1「移行は掃除より**後**に走らせること」。
  group('§1.5 【FEAT-542】secure storage から SharedPreferences への移設', () {
    test('🔴 移設は掃除の**後**に走る —— 既存ゲストが「未設定」に落ちない',
        () async {
      // 🔴 **これが本 FEAT で一番こわい事故である。**
      //
      // 掃除はマーカー無しのとき `deleteAll()` する。移設が先に走ると
      // 読むものが残っていて一見動くが、**掃除が後から消す**ので
      // 2 度目の起動でも整合しない。逆に掃除が先なら、保全された
      // `has_seen_tutorial` を移設が読める —— **保全が移行の経路である。**
      SharedPreferences.setMockInitialValues({});
      storage.values[_kGuestTokenKey] = 'guest-token';
      storage.values[_kTutorialKey] = 'true';
      storage.values[_kGuestModeKey] = 'true';

      final client = buildClient();

      // 空振り検出: 掃除が実際に走ったこと。
      // ⚠️ ゲートは遅延起動なので、**先に 1 回読んでから**マーカーを見る。
      await client.getToken();
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(ApiClient.kSecureStorageInitializedKey), isTrue,
          reason: '掃除が走っていない。このテストは何も確かめていない');

      expect(
        await client.isProfileSetupCompleted(), isTrue,
        reason: '移設が掃除より先に走っている。'
            '既存ゲスト全員がオンボーディングへ戻され、名前とキャラを上書きされる',
      );
      expect(await client.isGuestMode(), isTrue);
    });

    test('🔴 移設された「設定済み」には**持ち主**が入っている', () async {
      // ⛔ 真偽値で移すと、**トークンが変わっても一致してしまう**。
      SharedPreferences.setMockInitialValues({
        ApiClient.kSecureStorageInitializedKey: true,
      });
      storage.values[_kGuestTokenKey] = 'guest-token';
      storage.values[_kTutorialKey] = 'true';

      final client = buildClient();
      expect(await client.isProfileSetupCompleted(), isTrue);

      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString(kPrefsProfileSetupCompletedFor),
        profileSetupIdentityOf('guest-token'),
        reason: '持ち主が入っていない。真偽値のままでは別の身元に引き継がれる',
      );
      // 🔵 秘密を書いていないこと。
      expect(
        prefs.getString(kPrefsProfileSetupCompletedFor),
        isNot(contains('guest-token')),
        reason: 'トークンそのものを SharedPreferences に書いている',
      );
    });

    test('🔴 トークンが 1 本も無ければ「設定済み」を移さない', () async {
      // ⛔ 持ち主のいない「設定済み」を残すと、
      //    **次に作られる身元がそれを引き継ぐ**（BUG-167 で見つけた経路）。
      SharedPreferences.setMockInitialValues({
        ApiClient.kSecureStorageInitializedKey: true,
      });
      storage.values[_kTutorialKey] = 'true';

      final client = buildClient();
      await client.getToken();  // 移設を走らせる

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(kPrefsProfileSetupCompletedFor), isNull,
          reason: '持ち主のいない「設定済み」を書いた');
      expect(await client.isProfileSetupCompleted(), isFalse);
    });

    test('🔴 移設は旧キーを**自分で消す**（掃除に頼らない）', () async {
      // 掃除は初回に 1 度しか走らない。任せると旧キーが残り続け、
      // **次の誰かが分岐に使って二重意味が戻ってくる**。
      SharedPreferences.setMockInitialValues({
        ApiClient.kSecureStorageInitializedKey: true,
      });
      storage.values[_kGuestTokenKey] = 'guest-token';
      storage.values[_kTutorialKey] = 'true';
      storage.values[_kRegisteredKey] = 'true';
      storage.values[_kGuestModeKey] = 'true';
      storage.values[_kValidatedAtKey] = '2026-09-20T00:00:00.000';

      await buildClient().getToken();

      for (final key in [
        _kTutorialKey,
        _kRegisteredKey,
        _kGuestModeKey,
        _kValidatedAtKey,
      ]) {
        expect(storage.values.containsKey(key), isFalse,
            reason: '旧キー $key が secure storage に残っている');
      }
      // 🔵 資格情報は残ること（移設対象ではない）。
      expect(storage.values[_kGuestTokenKey], 'guest-token');
    });

    test('🔴 移設は 1 度しか走らない —— 2 度目が「未設定」に落とさない', () async {
      // 🔴 2 度目が走ると、既に消した旧キーを「無い = 未設定」と読んで
      //    **全員を未設定に落とす**。
      SharedPreferences.setMockInitialValues({
        ApiClient.kSecureStorageInitializedKey: true,
      });
      storage.values[_kGuestTokenKey] = 'guest-token';
      storage.values[_kTutorialKey] = 'true';

      expect(await buildClient().isProfileSetupCompleted(), isTrue);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(kPrefsDeviceFlagsMigrated), isTrue);

      // 2 回目の起動（旧キーはもう無い）。
      expect(
        await buildClient().isProfileSetupCompleted(), isTrue,
        reason: '移設が 2 度走り、既存ゲストを未設定に落とした',
      );
    });

    test('🔴 移設の**後**に修復が走る（guest_mode を上書きしない）', () async {
      // 移設が後だと「旧キーが無い = false」で修復の結果を消す。
      SharedPreferences.setMockInitialValues({
        ApiClient.kSecureStorageInitializedKey: true,
      });
      storage.values[_kGuestTokenKey] = 'guest-token';
      // v1.1.2 の掃除で guest_mode は既に消えている = 移行元が空。

      expect(
        await buildClient().isGuestMode(), isTrue,
        reason: '移設が修復のあとに走り、guest_mode を false で上書きした',
      );
    });

    test('移設後は 3 キーが SharedPreferences にある', () async {
      SharedPreferences.setMockInitialValues({
        ApiClient.kSecureStorageInitializedKey: true,
      });
      storage.values[_kRegisteredKey] = 'true';
      storage.values[_kValidatedAtKey] = '2026-09-20T00:00:00.000';

      final client = buildClient();
      expect(await client.isRegistered(), isTrue);
      expect(await client.getTokenValidatedAt(),
          DateTime.parse('2026-09-20T00:00:00.000'));

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(kPrefsIsRegistered), isTrue);
      expect(prefs.getString(kPrefsTokenValidatedAt),
          '2026-09-20T00:00:00.000');
    });
  });

  // ── §3 🔴 publicPrefixes の網羅性（本体）────────────────────────────
  group('§3 ルートの分類', () {
    // `AppRoutes` の定数をソースから拾う。Dart にはリフレクションが無いので
    // 走査で代替する（このプロジェクトの他の走査テストと同じ手口）。
    List<String> declaredRoutes() {
      final source =
          File('lib/core/router/app_router.dart').readAsStringSync();
      final start = source.indexOf('class AppRoutes');
      expect(start, greaterThan(0), reason: 'class AppRoutes が見つからない');
      final end = source.indexOf('\n}', start);
      final body = source.substring(start, end);
      return RegExp(r"static const \w+\s*=\s*'([^']+)'")
          .allMatches(body)
          .map((m) => m.group(1)!)
          .toList();
    }

    test('🔴 全ルートが public / 認証必須のどちらかに分類済み', () {
      final unclassified = declaredRoutes()
          .where((r) => !kPublicRoutePrefixes.contains(r))
          .where((r) => !kAuthRequiredRoutes.contains(r))
          .toList();
      expect(
        unclassified, isEmpty,
        reason: [
          'どちらの箱にも入っていないルートがあります: $unclassified',
          '  kPublicRoutePrefixes に足す → 未認証でも到達してよい',
          '  kAuthRequiredRoutes に足す   → 認証が要る',
          '⚠️ public なのに前者へ足し忘れると、そのルートは'
              '**未認証ユーザーから到達不能**になります'
              '（登録画面が漏れれば新規ユーザーが登録できません）。',
        ].join('\n'),
      );
    });

    test('🔴 走査が空振りしていない（下限）', () {
      // 走査が 0 件しか見つけなくても上のテストは緑になる。
      expect(
        declaredRoutes().length, greaterThanOrEqualTo(30),
        reason: 'AppRoutes の走査が壊れている',
      );
    });

    test('🔴 publicPrefixes の各要素が実在する（綴り間違いの検出）', () {
      final declared = declaredRoutes().toSet();
      for (final p in kPublicRoutePrefixes) {
        expect(
          declared.contains(p), isTrue,
          reason: '$p は AppRoutes に存在しません。'
              '綴り間違いだと redirect の除外が黙って効かなくなります',
        );
      }
    });

    test('登録経路が public に入っている（新規ユーザーの生命線）', () {
      for (final p in ['/auth', '/auth/register', '/auth/login']) {
        expect(kPublicRoutePrefixes, contains(p));
      }
    });

    test('🔵 【FEAT-542】/onboarding は認証必須側へ移った', () {
      // BUG-156 は「未認証なら /login」を規則にしたが、成立させるために
      // `/onboarding` を public 例外として登録する必要があった ——
      // **オンボーディングが認証より先に来ていた**からである。
      //
      // 🔴 本 FEAT で順序が逆になり、あの画面に着く時点で必ずトークンがある。
      //    **規則の例外が 1 つ消えた。**
      expect(kAuthRequiredRoutes, contains('/onboarding'));
      expect(
        kPublicRoutePrefixes, isNot(contains('/onboarding')),
        reason: '未認証で /onboarding に入れる。'
            'あそこはもうトークンを作らないので、'
            '認証ヘッダー無しで PATCH /player/ を叩いて 401 になる',
      );
    });

    test('ホームは認証必須側にある', () {
      expect(kAuthRequiredRoutes, contains('/home'));
      expect(kPublicRoutePrefixes, isNot(contains('/home')));
    });
  });

  // ── §2 redirect の条件（走査で縛る）──────────────────────────────
  group('§2 redirect の条件', () {
    String redirectBody() {
      final source =
          File('lib/core/router/app_router.dart').readAsStringSync();
      final at = source.indexOf('redirect: (context, state) {');
      expect(at, greaterThan(0));
      return source.substring(at, source.indexOf('\n    },', at));
    }

    test('🔴 checking を先に除外している（ちらつき防止）', () {
      final body = redirectBody();
      final checkingAt = body.indexOf('AuthStatus.checking');
      final unauthAt = body.indexOf('AuthStatus.unauthenticated');
      expect(checkingAt, greaterThan(0),
          reason: 'checking を除外しないと起動ごとにログイン画面がちらつく');
      expect(unauthAt, greaterThan(0),
          reason: 'unauthenticated で redirect しないと 401 後もホームに留まれる');
      expect(checkingAt, lessThan(unauthAt), reason: 'checking の除外が先');
    });

    test('🔴 refreshListenable が status の変化も拾う', () {
      final source =
          File('lib/core/router/app_router.dart').readAsStringSync();
      final at = source.indexOf('class _SessionExpiredNotifier');
      final body = source.substring(at, source.indexOf('\n}', at));
      expect(body.contains('next.status'), isTrue,
          reason: 'status を見張らないと redirect が走らない');
      // ⚠️ 広げすぎない。`isLoading` 等の頻繁な変化まで拾うと
      //    redirect が暴走する (コメントでの言及は許す、参照だけを禁じる)。
      expect(body.contains('next.isLoading'), isFalse);
      expect(body.contains('prev?.isLoading'), isFalse);
    });
  });
}
