// 【FEAT-489 Phase 2G-a】locale 固定の regression ガード (BUG-27 対策)。
//
// ## なぜこのテストが要るか
//
// BUG-27 (漢字が中国語グリフで描画される) は **日本語フォントを同梱して解決した
// のではない**。`pubspec.yaml` の `fonts:` はコメントアウトのまま、
// `app_theme.dart` の `fontFamily: 'NotoSansJP'` も無効で、
// **`MaterialApp.locale` に明示値を渡すことだけが唯一の防御**である。
//
// Phase 2G-a で `supportedLocales` に en を足したことで、今後
// 「端末の言語に合わせるのが自然」と考えて `locale: null` に戻す変更が
// 入りやすくなった。それをやると:
//
//   - 日本語圏の端末では **誰も気付かない**
//   - 中文端末でだけ漢字が中国語グリフになる
//
// 目視 QA で捕まえるのが極めて難しい種類の退行なので、CI で構造的に止める。
//
// 実行方法:
// ```powershell
// cd mobile
// flutter test test/i18n_locale_guard_test.dart
// ```

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sabiowl/core/l10n/app_locale.dart';
import 'package:sabiowl/core/l10n/service_l10n.dart';
import 'package:sabiowl/l10n/app_localizations.dart';

void main() {
  // ServiceL10n は static なのでテスト間で漏れる (Phase 2D の申し送り)。
  tearDown(() => ServiceL10n.debugSetLocale(const Locale('ja')));

  // ───────────────────────────────────────────────────────────────────────────
  // A: 対応 locale は ja / en の 2 つだけ
  // ───────────────────────────────────────────────────────────────────────────
  group('A: supportedLocales', () {
    test('ja_JP と en の 2 つに限定されている', () {
      expect(kSupportedLocales, [const Locale('ja', 'JP'), const Locale('en')]);
    });

    test('3 つ目を足すときは BUG-27 の再検証が要る (件数を固定して気付かせる)', () {
      expect(
        kSupportedLocales.length,
        2,
        reason: 'locale を増やす場合、その言語のグリフが端末フォントで解決できるか / '
            '日本語グリフに干渉しないかを BUG-27 の観点で再検証してから、\n'
            'このテストを更新してください。',
      );
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // B: locale 解決は必ず ja / en のどちらかに丸める (§2.1 の最重要制約)
  // ───────────────────────────────────────────────────────────────────────────
  group('B: locale 解決', () {
    test('保存済みユーザー設定が最優先', () {
      expect(
        resolveInitialLocale(
            savedLanguageCode: 'en', deviceLocale: const Locale('ja')),
        kEnLocale,
      );
      expect(
        resolveInitialLocale(
            savedLanguageCode: 'ja', deviceLocale: const Locale('en')),
        kJaLocale,
      );
    });

    test('未選択なら端末 locale を見る (en → en)', () {
      expect(
        resolveInitialLocale(deviceLocale: const Locale('en', 'US')),
        kEnLocale,
      );
    });

    test('zh / ko / 未知の端末は ja に丸める (BUG-27 防御の本体)', () {
      for (final code in const [
        'zh', 'zh_Hans', 'zh_Hant', 'ko', 'fr', 'de', 'es', 'pt', 'ru', 'xx',
      ]) {
        expect(
          resolveInitialLocale(deviceLocale: Locale(code)),
          kJaLocale,
          reason: '端末 locale "$code" は ja に丸められるべき。'
              'en に落とすと UI が英語になり、ユーザーが日本語に戻した瞬間に '
              'BUG-27 の条件に入る',
        );
      }
    });

    test('端末 locale が取れない場合も ja', () {
      expect(resolveInitialLocale(), kJaLocale);
      expect(resolveInitialLocale(savedLanguageCode: ''), kJaLocale);
    });

    test('保存値が壊れていても ja に丸まる (null にはならない)', () {
      for (final saved in const ['zh', 'ko', 'garbage', 'EN-US-nonsense']) {
        final resolved = resolveInitialLocale(savedLanguageCode: saved);
        expect(kSupportedLocales.contains(resolved), isTrue,
            reason: '保存値 "$saved" が未対応 locale を素通ししている');
      }
    });

    test('normalizeLanguageCode は en 系のみ en、他はすべて ja', () {
      expect(normalizeLanguageCode('en'), 'en');
      expect(normalizeLanguageCode('en_US'), 'en');
      expect(normalizeLanguageCode('EN-GB'), 'en');
      expect(normalizeLanguageCode('ja'), 'ja');
      expect(normalizeLanguageCode('zh'), 'ja');
      expect(normalizeLanguageCode(null), 'ja');
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // C: main.dart の source ガード — `locale: null` に戻されたら落ちる
  // ───────────────────────────────────────────────────────────────────────────
  group('C: main.dart の locale 指定', () {
    late String src;

    setUpAll(() {
      final f = File('lib/main.dart');
      expect(f.existsSync(), isTrue,
          reason: 'プロジェクトルート (mobile/) から実行してください');
      // 禁止語は「使うな」と書く注意書き側にも出るのでコメントを落とす。
      src = f
          .readAsStringSync()
          .split('\n')
          .where((l) => !l.trimLeft().startsWith('//'))
          .map(_stripLineComment)
          .join('\n');
    });

    test('locale: null になっていない (BUG-27 の直接の再発条件)', () {
      expect(
        RegExp(r'locale:\s*null').hasMatch(src),
        isFalse,
        reason: '【BUG-27】MaterialApp.locale を null にすると、端末 locale に委ねられ、\n'
            '中文端末で漢字が中国語グリフにフォールバックします。\n'
            '日本語フォントを同梱していないためアプリ側に他の防御がありません。\n'
            '端末 locale に従いたい場合も、必ず ja/en に丸めた明示値を渡してください\n'
            '(core/l10n/app_locale.dart の resolveInitialLocale)。',
      );
    });

    test('locale に appLocaleProvider 由来の値を渡している', () {
      expect(RegExp(r'locale:\s*appLocale').hasMatch(src), isTrue,
          reason: 'MaterialApp.locale は ref.watch(appLocaleProvider) の値を渡すこと');
      expect(src.contains('ref.watch(appLocaleProvider)'), isTrue,
          reason: '言語切替で rebuild されるよう watch すること (read では追従しない)');
    });

    test('supportedLocales は kSupportedLocales を使う (直書きしない)', () {
      expect(src.contains('supportedLocales: kSupportedLocales'), isTrue,
          reason: '対応 locale の真実値を core/l10n/app_locale.dart に一本化すること');
    });

    test('起動時 locale を runApp 前に解決している', () {
      expect(src.contains('resolveInitialLocale('), isTrue);
      expect(src.contains('initialLocaleProvider.overrideWithValue'), isTrue,
          reason: 'main() で解決した locale を ProviderScope に注入すること');
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // D: ServiceL10n が MaterialApp の locale に追従する (§2.2 の固定)
  // ───────────────────────────────────────────────────────────────────────────
  group('D: ServiceL10n の追従', () {
    Widget appWith(Locale locale) => MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: kSupportedLocales,
          locale: locale,
          builder: (context, child) {
            ServiceL10n.syncFrom(context);
            return child ?? const SizedBox.shrink();
          },
          home: const SizedBox.shrink(),
        );

    testWidgets('locale を en にすると ServiceL10n.current も en になる',
        (tester) async {
      await tester.pumpWidget(appWith(kJaLocale));
      expect(ServiceL10n.current.localeName, 'ja');

      // 言語切替 = MaterialApp.locale の差し替え
      await tester.pumpWidget(appWith(kEnLocale));
      expect(
        ServiceL10n.current.localeName,
        'en',
        reason: 'ServiceL10n が追従しないと、Accept-Language ヘッダ (Phase 2E) と '
            'BuildContext を持たない層 (通知本文 / API エラー) が旧 locale のまま残り、'
            '1 画面に 2 言語が混在します',
      );
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // E': 切替は副作用の成否に依存しない (Pre-mortem S4)
  // ───────────────────────────────────────────────────────────────────────────
  group("E': AppLocaleController.setLanguage", () {
    ProviderContainer containerWith(_FakeSideEffects fake, Locale initial) =>
        ProviderContainer(overrides: [
          initialLocaleProvider.overrideWithValue(initial),
          localeSideEffectsProvider.overrideWithValue(fake),
        ]);

    test('en に切り替えると state が en になり、副作用が呼ばれる', () async {
      final fake = _FakeSideEffects();
      final c = containerWith(fake, kJaLocale);
      addTearDown(c.dispose);

      await c.read(appLocaleProvider.notifier).setLanguage('en');

      expect(c.read(appLocaleProvider), kEnLocale);
      expect(fake.applied, [kEnLocale],
          reason: '永続化 / キャッシュ破棄 / Backend 同期が走っていない');
    });

    test('副作用が全部失敗しても UI 切替は成立する (S4)', () async {
      final fake = _FakeSideEffects(shouldThrow: true);
      final c = containerWith(fake, kJaLocale);
      addTearDown(c.dispose);

      await c.read(appLocaleProvider.notifier).setLanguage('en');

      expect(
        c.read(appLocaleProvider),
        kEnLocale,
        reason: 'preferred_language の PATCH が失敗しても切替自体は成立すること。'
            'Accept-Language (Phase 2E) が fallback として効くので、'
            'Backend 由来テキストも次回リクエストから英語で返る',
      );
    });

    test('同じ言語を選び直しても副作用を走らせない', () async {
      final fake = _FakeSideEffects();
      final c = containerWith(fake, kJaLocale);
      addTearDown(c.dispose);

      await c.read(appLocaleProvider.notifier).setLanguage('ja');

      expect(fake.applied, isEmpty, reason: '不要な PATCH / キャッシュ破棄が走っている');
    });

    test('未対応 locale を渡しても ja に丸まる (state が未対応値にならない)', () async {
      final fake = _FakeSideEffects();
      final c = containerWith(fake, kEnLocale);
      addTearDown(c.dispose);

      await c.read(appLocaleProvider.notifier).setLanguage('zh');

      expect(c.read(appLocaleProvider), kJaLocale);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // E: 切替 API は未対応 locale を受け付けない
  // ───────────────────────────────────────────────────────────────────────────
  group('E: localeForLanguageCode', () {
    test('どんな入力でも kSupportedLocales の範囲に収まる', () {
      for (final code in const ['ja', 'en', 'zh', 'ko', '', 'EN', 'ja-JP']) {
        expect(kSupportedLocales.contains(localeForLanguageCode(code)), isTrue,
            reason: '"$code" が未対応 locale を返した');
      }
    });
  });
}

/// 副作用 (永続化 / キャッシュ破棄 / Backend PATCH) の fake。
///
/// 実物を呼ぶと **テストが本番 API を PATCH してしまう** ため、必ず差し替える。
class _FakeSideEffects implements LocaleSideEffects {
  _FakeSideEffects({this.shouldThrow = false});

  final bool shouldThrow;
  final List<Locale> applied = [];

  @override
  Future<void> apply(Locale next) async {
    applied.add(next);
    if (shouldThrow) throw Exception('offline');
  }
}

/// 文字列リテラルの外側にある `//` 以降を落とす。
String _stripLineComment(String line) {
  String? inString;
  for (var i = 0; i < line.length; i++) {
    final c = line[i];
    if (inString != null) {
      if (c == r'\') {
        i++;
        continue;
      }
      if (c == inString) inString = null;
    } else if (c == "'" || c == '"') {
      inString = c;
    } else if (c == '/' && i + 1 < line.length && line[i + 1] == '/') {
      return line.substring(0, i);
    }
  }
  return line;
}
