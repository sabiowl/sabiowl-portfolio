import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sabiowl/core/analytics/sentry_scope_tags.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

/// 【BUG-159 (2026-09-12)】識別子を送らずに切り分けられるようにする。
///
/// ## 🔴 1 と 2 は対で書く
///
/// 「`is_guest` タグが入っている」だけを書くと、**`user` を丸ごと送る**
/// 実装でも緑になる。プライバシーポリシーが名指しで削除を約束している
/// ものが送られる方向の退行を、それでは検出できない。
///
/// ⚠️ **3 は 2 と役割が違う。** 2 は挙動、3 は実装の形 ——
/// **方針が黙って外れること**を防ぐ側の縛りである。
///
/// ## 🔴 6 を必ず書く
///
/// `Sentry.configureScope` が 2 箇所に増えると、
/// **片方だけ更新されて嘘のタグになる。**

/// 送信しない transport。
///
/// ⚠️ **`dsn` を空にすると hub 自体が無効になり、`configureScope` の
/// コールバックがそもそも呼ばれない**（最初にこれで詰まった）。
/// 形式の正しい DSN で有効にし、**送信だけを捨てる**。
class _NoopTransport implements Transport {
  @override
  Future<SentryId?> send(SentryEnvelope envelope) async => SentryId.empty();
}

/// scope に積まれたタグを覗くための最小 hub。
Future<void> _initSentry() => Sentry.init((options) {
      options.dsn = 'https://public@o0.ingest.example/0';
      options.transport = _NoopTransport();
      options.beforeSend = (event, hint) => event.copyWith(user: null);
    });

Future<Scope> _currentScope() async {
  late Scope captured;
  await Sentry.configureScope((scope) => captured = scope);
  return captured;
}

Future<Scope> _scopeAfterApply({
  required bool isGuest,
  required String languageCode,
}) async {
  await _initSentry();
  await applySentryScopeTags(isGuest: isGuest, languageCode: languageCode);
  return _currentScope();
}

void main() {
  group('BUG-159 §4-1/2 タグは入り、user は入らない', () {
    tearDown(() async => Sentry.close());

    test('🔴 1: is_guest / locale タグが入る', () async {
      final scope = await _scopeAfterApply(isGuest: true, languageCode: 'ja');
      expect(scope.tags[kSentryIsGuestTag], 'true',
          reason: '429 の調査で本当に欲しかった情報。'
              'anon と user のどちらが枯れたかで修正の当て先が変わる');
      expect(scope.tags[kSentryLocaleTag], 'ja');
    });

    test('🔴 2: user は一切載らない', () async {
      // 🔴 1 と対。1 だけだと「user を丸ごと送る」実装で緑になる。
      final scope = await _scopeAfterApply(isGuest: false, languageCode: 'en');
      expect(scope.user, isNull,
          reason: 'プライバシーポリシーが PlayerProfile ID と端末固有の識別子の'
              '削除を名指しで約束している');
      final dump = scope.tags.toString();
      for (final forbidden in ['@', 'player_id', 'user_id', 'device_id']) {
        expect(dump, isNot(contains(forbidden)),
            reason: 'タグに識別子らしきものが混ざっている: $forbidden');
      }
    });

    test('is_guest は false も文字列で載る', () async {
      final scope = await _scopeAfterApply(isGuest: false, languageCode: 'ja');
      expect(scope.tags[kSentryIsGuestTag], 'false');
    });

    test('🔴 5: is_guest が認証状態の変化に追従する', () async {
      await _initSentry();
      // ゲストとして起動 → ソーシャル連携で非ゲストになる、という遷移。
      var guest = true;
      await syncSentryScopeTags(
          isGuestMode: () async => guest, languageCode: 'ja');
      expect((await _currentScope()).tags[kSentryIsGuestTag], 'true');

      guest = false;
      await syncSentryScopeTags(
          isGuestMode: () async => guest, languageCode: 'ja');
      expect((await _currentScope()).tags[kSentryIsGuestTag], 'false',
          reason: 'ゲスト → 連携済みの遷移に追従していない。'
              '実行中に変わる値なので init の時点では確定できない');
    });

    test('⚠️ ゲスト判定が読めなかったら前の値を保つ', () async {
      await _initSentry();
      await syncSentryScopeTags(
          isGuestMode: () async => true, languageCode: 'ja');
      await syncSentryScopeTags(
        isGuestMode: () async => throw StateError('storage unavailable'),
        languageCode: 'ja',
      );
      expect((await _currentScope()).tags[kSentryIsGuestTag], 'true',
          reason: '「判定できない」を false に丸めると、'
              'ゲストのイベントが連携済みとして記録される。'
              '切り分けを助けるどころか間違った方向へ誘導する');
    });
  });

  group('BUG-159 §4-4 environment が API_BASE_URL に追従する', () {
    test('prod / dev / local', () {
      expect(
        resolveSentryEnvironment('https://sabiowl-backend.onrender.com/api'),
        'prod',
      );
      expect(
        resolveSentryEnvironment('https://sabiowl-backend-dev.onrender.com/api'),
        'dev',
      );
      expect(resolveSentryEnvironment('http://localhost:8000/api'), 'local');
      expect(resolveSentryEnvironment('http://10.0.2.2:8000/api'), 'local');
    });

    test('🔴 dev を prod と取り違えない', () {
      // ⚠️ 実害はこれ —— Android の dev flavor でビルドした release APK が
      //    production として記録され、dev の事象が prod に混ざる。
      expect(
        resolveSentryEnvironment('https://sabiowl-backend-dev.onrender.com/api'),
        isNot('prod'),
      );
    });

    test('⚠️ 知らないホストを prod に寄せない', () {
      // prod に寄せる fallback は、本 BUG が直そうとしている状態そのもの。
      expect(resolveSentryEnvironment('https://example.com/api'), 'unknown');
      expect(resolveSentryEnvironment('not a url at all'), 'local');
    });
  });

  group('BUG-159 §4-3/6 方針と更新者を走査で縛る', () {
    test('🔴 3: beforeSend の user: null が維持されている', () {
      final source = _readSource('lib/main.dart');
      expect(source, contains('options.beforeSend'),
          reason: '走査が壊れている (beforeSend が見つからない)');
      expect(source, contains('user: null'),
          reason: 'A′ が B / C に化けている。'
              '識別子を送る案はポリシー 2 本 + nutrition label の 3 点連動で、'
              'v1.1.2 の提出直前にやる作業ではない');
    });

    test('🔴 6: Sentry.configureScope の呼び出しは 1 箇所だけ', () {
      final hits = <String>[];
      for (final file in _dartFilesUnder('lib')) {
        final source = File(file).readAsStringSync();
        if (source.contains('Sentry.configureScope')) hits.add(file);
      }
      // 空振り検出: 走査が壊れて 0 件だと、以下の assert は無意味になる。
      expect(hits, isNotEmpty, reason: '走査が configureScope を 1 件も見つけていない');
      expect(hits, hasLength(1),
          reason: '更新者が 2 つ以上ある。'
              '片方だけ更新されて嘘のタグになる: $hits');
      expect(hits.single, endsWith('sentry_scope_tags.dart'),
          reason: '更新者が想定の場所にない');
    });

    test('🔴 is_guest の更新は auth_provider の 5 つの遷移に配られていない', () {
      // 🔴 AuthStatus.authenticated を設定している箇所は 5 つある。
      //    そこに setTag を配るのは、BUG-152 → BUG-153 → FEAT-541 →
      //    BUG-156 で 4 回続けて失敗したのと同じ形である。
      final source = _readSource('lib/features/auth/providers/auth_provider.dart');
      expect(source, contains('AuthStatus.authenticated'),
          reason: '走査が壊れている');
      expect(source, isNot(contains('applySentryScopeTags')),
          reason: '遷移ごとに配ると、新しい遷移が増えたとき必ず 1 つ漏れる');
      expect(source.toLowerCase(), isNot(contains('sentry')));
    });

    test('⚠️ 更新のきっかけは main.dart の 1 箇所に置かれている', () {
      final source = _readSource('lib/main.dart');
      expect(source, contains('syncSentryScopeTags'),
          reason: 'タグを更新する経路が無い = 起動後ずっと未設定のまま');
      expect(source, contains('options.environment'),
          reason: 'environment を設定していない。'
              'dev を叩く release ビルドが production として記録される');
      // ⚠️ overlay や画面に置くと mount / dispose のたびに動いて嘘のタグになる。
      for (final file in _dartFilesUnder('lib')) {
        if (file.endsWith('main.dart') ||
            file.endsWith('sentry_scope_tags.dart')) {
          continue;
        }
        final other = File(file).readAsStringSync();
        expect(other, isNot(contains('SentryScopeTags')),
            reason: 'アプリ全体で 1 度だけ mount される層の外から呼んでいる: $file');
      }
    });
  });
}

/// 走査対象を読む。テストの作業ディレクトリは `mobile/`。
String _readSource(String relativePath) {
  final f = File(relativePath);
  if (!f.existsSync()) {
    throw StateError('走査対象が見つからない: $relativePath');
  }
  return f.readAsStringSync();
}

Iterable<String> _dartFilesUnder(String dir) sync* {
  for (final entity in Directory(dir).listSync(recursive: true)) {
    if (entity is File && entity.path.endsWith('.dart')) {
      // 生成物 (`.g.dart` / app_localizations) は対象外。
      if (entity.path.endsWith('.g.dart')) continue;
      if (entity.path.contains('app_localizations')) continue;
      yield entity.path;
    }
  }
}
