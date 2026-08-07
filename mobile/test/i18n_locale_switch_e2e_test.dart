// 【FEAT-489 Phase 2G-b §2.3】言語切替の E2E 契約。
//
// ## 2G-a のガードとの違い
//
// `i18n_locale_guard_test.dart` は **locale 解決とソースの静的検査**が中心で、
// 「切り替えたら実際に表示が変わる」ところを通していない。本テストがそこを埋める。
//
//   A: 切替で MaterialApp 配下の **実テキスト**が英語になる (2 言語混在しない)
//   B: 副作用の順序 — キャッシュ破棄が PATCH より先に走る (Phase 2E S6)
//
// ## なぜ実物の ApiClient を通さないか
//
// 当初は `apiClientProvider` の実物に fake HttpClientAdapter を挿して
// PATCH の body まで検証しようとしたが、`ApiClient` の onRequest interceptor が
// `flutter_secure_storage` の MethodChannel を待つため **テストが 30s timeout で
// 停止**した。mock channel を張っても binding が不安定になり、ファイル全体が
// "did not complete" になる。
//
// 実物を通す価値より、**fake adapter を張り損ねたときに本番 API へ PATCH が飛ぶ
// リスク**の方が大きいと判断し、以下の分担にした:
//
//   - 表示の切替 → 本テスト (A)
//   - 副作用の順序 → source レベル (B、`i18n_coverage_test` check D と同じ作法)
//   - 実 HTTP を含む経路 → **実機 QA** (§3.3「機内モードで切替」)
//
// 実行方法:
// ```powershell
// cd mobile
// flutter test test/i18n_locale_switch_e2e_test.dart
// ```

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sabiowl/core/l10n/app_locale.dart';
import 'package:sabiowl/core/l10n/service_l10n.dart';
import 'package:sabiowl/l10n/app_localizations.dart';

void main() {
  // ServiceL10n は static。テスト間で漏れる (Phase 2D の申し送り)。
  tearDown(() => ServiceL10n.debugSetLocale(const Locale('ja')));

  // ───────────────────────────────────────────────────────────────────────────
  // A: 切替で表示が英語になる
  // ───────────────────────────────────────────────────────────────────────────
  group('A: 切替で表示が変わる', () {
    /// 副作用 (prefs / キャッシュ破棄 / PATCH) は本 group の関心外なので no-op に差し替える。
    /// 実物を通すと platform channel 待ちで停止する (ファイル冒頭の説明参照)。
    ProviderContainer containerWith(Locale initial) =>
        ProviderContainer(overrides: [
          initialLocaleProvider.overrideWithValue(initial),
          localeSideEffectsProvider.overrideWithValue(const _NoopSideEffects()),
        ]);

    testWidgets('setLanguage("en") で MaterialApp 配下のテキストが英語になる',
        (tester) async {
      final container = containerWith(kJaLocale);
      addTearDown(container.dispose);

      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: const _Probe(),
      ));

      expect(find.text('やめる'), findsOneWidget);
      expect(find.text('Cancel'), findsNothing);

      await container.read(appLocaleProvider.notifier).setLanguage('en');
      await tester.pumpAndSettle();

      expect(
        find.text('Cancel'),
        findsOneWidget,
        reason: '切替後に MaterialApp 配下が rebuild されていません。'
            'Localizations は InheritedWidget なので、'
            'AppLocalizations.of(context) を使う widget は自動追従するはず',
      );
      expect(find.text('やめる'), findsNothing,
          reason: '1 画面に 2 言語が混在しています (Phase 2G-a S2)');
    });

    testWidgets('ja に戻すと日本語に戻る', (tester) async {
      final container = containerWith(kEnLocale);
      addTearDown(container.dispose);

      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: const _Probe(),
      ));
      expect(find.text('Cancel'), findsOneWidget);

      await container.read(appLocaleProvider.notifier).setLanguage('ja');
      await tester.pumpAndSettle();

      expect(find.text('やめる'), findsOneWidget);
    });

    testWidgets('切替に伴い ServiceL10n も追従する (Accept-Language の供給元)',
        (tester) async {
      final container = containerWith(kJaLocale);
      addTearDown(container.dispose);

      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: const _Probe(),
      ));
      expect(ServiceL10n.current.localeName, 'ja');

      await container.read(appLocaleProvider.notifier).setLanguage('en');
      await tester.pumpAndSettle();

      expect(
        ServiceL10n.current.localeName,
        'en',
        reason: 'ServiceL10n が追従しないと Accept-Language ヘッダ (Phase 2E) と '
            'BuildContext を持たない層 (通知本文 / API エラー) が旧 locale のまま残ります',
      );
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // B: キャッシュ破棄が PATCH より先 (Phase 2E S6 の回収)
  // ───────────────────────────────────────────────────────────────────────────
  group('B: 副作用の順序', () {
    late String src;

    setUpAll(() {
      final f = File('lib/core/l10n/app_locale.dart');
      expect(f.existsSync(), isTrue,
          reason: 'プロジェクトルート (mobile/) から実行してください');
      src = f
          .readAsStringSync()
          .split('\n')
          .where((l) => !l.trimLeft().startsWith('//'))
          .join('\n');
    });

    test('切替時に応答キャッシュを破棄している', () {
      expect(
        src.contains('clearResponseCache()'),
        isTrue,
        reason: '【Phase 2E S6】FEAT-476 の DioCacheInterceptor は ja で取得した応答を'
            '保持しているため、破棄しないと「切り替えたのにサビの台詞だけ日本語」に'
            'なります。Backend は Vary: Accept-Language を返していますが、'
            'dio 側がこれを解釈する保証はありません。',
      );
    });

    test('preferred_language を PATCH している', () {
      expect(src.contains('.patch<void>('), isTrue);
      expect(src.contains(r"'/player/'"), isTrue);
    });

    test('キャッシュ破棄は PATCH より先に実行する', () {
      final clearAt = src.indexOf('clearResponseCache()');
      final patchAt = src.indexOf('.patch<void>(');

      expect(
        clearAt,
        lessThan(patchAt),
        reason: 'キャッシュ破棄を PATCH より後にすると、PATCH の応答経路で'
            '古い locale の内容を拾い直す余地が残ります。',
      );
    });

    test('PATCH の失敗を握りつぶしている (S4: 切替を I/O に依存させない)', () {
      // setLanguage 側でも囲っているが、apply() 内でも catch していることを固定する。
      final patchAt = src.indexOf('.patch<void>(');
      final after = src.substring(patchAt);
      // PATCH 呼び出しの直後 (同じ try ブロック内) に catch があること。
      // 400 字は try/catch 1 段分の余裕。
      expect(
        after.substring(0, after.length < 400 ? after.length : 400)
            .contains('catch'),
        isTrue,
        reason: 'PATCH を try/catch で囲ってください。オフラインや 401 で失敗しても、'
            'Accept-Language (Phase 2E) が次回リクエストから正しい言語を引くので'
            '切替自体は成立させます (Phase 2G-a S4)。',
      );
    });
  });
}

/// 切替が実表示に届くかを見るための最小 widget。
///
/// `settingsLanguageDialogCancelButton` は ja「やめる」/ en「Cancel」で、
/// 両言語で明確に異なるので判定に使いやすい。
class _Probe extends StatelessWidget {
  const _Probe();

  @override
  Widget build(BuildContext context) {
    return Consumer(
      builder: (context, ref, _) => MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: kSupportedLocales,
        locale: ref.watch(appLocaleProvider),
        builder: (context, child) {
          ServiceL10n.syncFrom(context);
          return child ?? const SizedBox.shrink();
        },
        home: Builder(
          builder: (context) => Text(
            AppLocalizations.of(context)!.settingsLanguageDialogCancelButton,
          ),
        ),
      ),
    );
  }
}

/// 副作用を一切起こさない [LocaleSideEffects]。
///
/// **実物を使うと本番 API に PATCH が飛び得る**ので、表示を見るテストでは必ず差し替える。
class _NoopSideEffects implements LocaleSideEffects {
  const _NoopSideEffects();

  @override
  Future<void> apply(Locale next) async {}
}
