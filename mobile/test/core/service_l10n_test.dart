// 【FEAT-489 Phase 2D】service 層 l10n (ServiceL10n) の契約テスト。
//
// Phase 2D では BuildContext を持たない層 (notification / maintenance / API error
// fallback / IAP Exception / mailto テンプレ) を `ServiceL10n.current` 経由に
// 切り替えた。ここが壊れると **英語端末で日本語の通知 / エラーが出る** という、
// 実機 QA でしか気付けない degrade になるため CI で締める。
//
// シナリオ:
//   A: default locale は ja (runApp 前 = NotificationService.initialize 時点の前提)
//   B: locale を en に切り替えると service 層の文字列が英語になる
//   C: MaterialApp.builder からの syncFrom() が locale を反映する
//   D: SabiWaitingPanel(message: null) が arb default に fallback する

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sabiowl/core/api/dio_error_helper.dart';
import 'package:sabiowl/core/api/error_formatter.dart';
import 'package:sabiowl/core/constants/app_urls.dart';
import 'package:sabiowl/core/l10n/service_l10n.dart';
import 'package:sabiowl/core/services/maintenance_service.dart';
import 'package:sabiowl/l10n/app_localizations.dart';
import 'package:sabiowl/shared/widgets/sabi_loading_skeleton.dart';

/// 日本語 (ひらがな / カタカナ / 漢字) が含まれるか。
/// locale 切替の検査は **文言の一致ではなく言語の切り替わり**で行う。
final _kJapanese = RegExp(r'[぀-ヿ一-龯]');

void main() {
  // 【重要】static holder のためテスト間で状態が漏れる。必ず ja に戻す。
  tearDown(() => ServiceL10n.debugSetLocale(const Locale('ja')));

  group('FEAT-489 Phase 2D — ServiceL10n', () {
    test('A: default locale は ja (runApp 前の service 初期化で日本語が出る)', () {
      expect(ServiceL10n.current, isA<AppLocalizations>());
      expect(ServiceL10n.current.localeName, 'ja');
      expect(formatApiError(Exception('boom')), contains('🪶'));
      // 【2026-08-06】完成文の一致をやめ「日本語が出ていること」で判定する。
      // 本 group が守りたいのは **locale の切り替わり**であって文言ではない。
      // 文言を固定すると FEAT-489 の英文/和文レビューのたびに落ちる。
      expect(MaintenanceStatus.placeholderOn.title, matches(_kJapanese));
    });

    test('B: locale を en にすると service 層の文字列が英語になる', () {
      ServiceL10n.debugSetLocale(const Locale('en'));

      // API エラー fallback (formatApiError / ApiError.fromResponse の両経路)
      // 【2026-08-06】完成文ではなく「日本語が消えていること」で判定する。
      expect(formatApiError(Exception('boom')), isNot(matches(_kJapanese)));
      expect(formatApiError(Exception('boom')), contains('🪶'));
      expect(ApiError.fromResponse(null).message, isNot(matches(_kJapanese)));

      // maintenance placeholder (旧 static const → getter 化した経路)
      expect(MaintenanceStatus.placeholderOn.title, isNotEmpty);
      expect(MaintenanceStatus.placeholderOn.title, isNot(matches(_kJapanese)));
      expect(MaintenanceStatus.placeholderOn.isEnabled, isTrue);

      // mailto テンプレ (Uri の query に英語 subject が載る)
      final mailto = buildSabiowlMaintenanceContactMailto();
      expect(mailto.scheme, 'mailto');
      expect(
        Uri.decodeQueryComponent(
          RegExp(r'subject=([^&]*)').firstMatch(mailto.query)!.group(1)!,
        ),
        '[Maintenance inquiry] Sabiowl',
      );
    });

    test('B-2: API が message を返す場合は locale に関わらずサーバー文言を優先', () {
      ServiceL10n.debugSetLocale(const Locale('en'));
      expect(
        ApiError.fromResponse({
          'error': {'code': 'shop_buy_not_enough_diamonds', 'message': 'server says'}
        }).message,
        'server says',
      );
    });

    testWidgets('C: MaterialApp.builder 経由の syncFrom() が locale を反映する',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          builder: (context, child) {
            ServiceL10n.syncFrom(context);
            return child ?? const SizedBox.shrink();
          },
          home: const SizedBox.shrink(),
        ),
      );

      expect(ServiceL10n.current.localeName, 'en');
    });
  });

  group('FEAT-489 Phase 2D — SabiWaitingPanel default message', () {
    Widget wrap(Widget child, Locale locale) => MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: locale,
          home: Scaffold(body: child),
        );

    testWidgets('D-1: message 省略時は arb default (ja) に fallback する',
        (tester) async {
      await tester.pumpWidget(
        wrap(const SabiWaitingPanel(), const Locale('ja')),
      );
      expect(find.text('少しお待ちください 🪶'), findsOneWidget);
    });

    testWidgets('D-2: message 省略時は arb default (en) に fallback する',
        (tester) async {
      await tester.pumpWidget(
        wrap(const SabiWaitingPanel(), const Locale('en')),
      );
      expect(find.text('Please wait a moment. 🪶'), findsOneWidget);
    });

    testWidgets('D-3: message 明示時は呼び出し側の文言を優先する', (tester) async {
      await tester.pumpWidget(
        wrap(const SabiWaitingPanel(message: '品揃えを整えています 🪶'),
            const Locale('ja')),
      );
      expect(find.text('品揃えを整えています 🪶'), findsOneWidget);
      expect(find.text('少しお待ちください 🪶'), findsNothing);
    });
  });
}
