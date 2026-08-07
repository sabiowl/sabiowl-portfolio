// 【FEAT-515 Phase 2 (2026-08-04)】API エラー code → locale 別文言の契約テスト。
//
// ## 何を守るか
//
// Phase 1 で `formatApiError` が `data['error'] as String` になっていて、
// 新形式では cast 例外 → `catch (_)` に飲まれ **77 endpoint すべてで汎用文言に
// 落ちていた**ことが分かった。例外は握り潰され、型エラーとしても表面化しない。
//
// Phase 2 で足した「code から ARB を引く」層も同じ壊れ方をしうる:
//
//   - switch に case を書き忘れる → default に落ちて **日本語のまま**
//   - ARB key を消す / 改名する    → コンパイルエラーになるので安全
//   - 未知 code のフォールバックを壊す → 文言が空になる
//
// 1 つ目と 3 つ目は **例外を出さない**ので、テストでしか捕まらない。
//
// Backend 側との同期 (code の実在 / ja 文言の一致) は
// `backend/api/tests/test_error_code_l10n_sync.py` が縛る。本テストは
// **Flutter 内部で閉じる契約**だけを見る。
//
// 実行方法:
// ```powershell
// cd mobile
// flutter test test/core/api_error_l10n_test.dart
// ```

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabiowl/core/api/api_error_messages.dart';
import 'package:sabiowl/core/api/dio_error_helper.dart';
import 'package:sabiowl/core/api/error_formatter.dart';
import 'package:sabiowl/core/l10n/service_l10n.dart';
import 'package:sabiowl/l10n/app_localizations.dart';

void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  final ja = lookupAppLocalizations(const Locale('ja'));

  // ───────────────────────────────────────────────────────────────────────────
  // A: 対象 code が全 locale で解決される
  // ───────────────────────────────────────────────────────────────────────────
  group('A: code の解決', () {
    test('全 code が en / ja の両方で非 null かつ非空に解決される', () {
      final unresolved = <String>[];
      for (final code in kLocalizedApiErrorCodes) {
        for (final entry in {'en': en, 'ja': ja}.entries) {
          final text = localizedApiError(entry.value, code, const {});
          if (text == null || text.isEmpty) {
            unresolved.add('[${entry.key}] $code');
          }
        }
      }

      expect(
        unresolved,
        isEmpty,
        reason: 'kLocalizedApiErrorCodes に列挙したのに switch の case が無いと、'
            'default に落ちて **英語 UI でも日本語のまま**になります。\n'
            '例外は出ないので、ここで落とさないと気付けません。\n'
            '${unresolved.join('\n')}',
      );
    });

    test('en と ja で異なる文言が返る (訳し忘れ / コピペの検出)', () {
      final identical = <String>[];
      for (final code in kLocalizedApiErrorCodes) {
        final e = localizedApiError(en, code, const {'ticket_type': 'daily'});
        final j = localizedApiError(ja, code, const {'ticket_type': 'daily'});
        if (e == j) identical.add('$code: $e');
      }

      expect(
        identical,
        isEmpty,
        reason: 'en と ja が同一文字列です。app_en.arb に key を足し忘れると '
            'gen-l10n が **ja の値をそのまま en にフォールバック**させるため、\n'
            'コンパイルは通るのに英語 UI で日本語が出ます。\n'
            '${identical.join('\n')}',
      );
    });

    test('未知の code は null を返す (フォールバック経路が生きている)', () {
      expect(localizedApiError(en, 'no_such_error_code', const {}), isNull);
      expect(localizedApiError(en, '', const {}), isNull);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // B: placeholder を持つ code
  // ───────────────────────────────────────────────────────────────────────────
  group('B: placeholder', () {
    test('ガチャのチケット種別が en の文面に反映される', () {
      String pull(String type) =>
          localizedApiError(en, 'gacha_pull_not_enough_tickets',
              {'ticket_type': type})!;

      expect(pull('daily'), contains('daily'));
      expect(pull('weekly'), contains('weekly'));
      expect(pull('monthly'), contains('monthly'));

      // 3 種が互いに異なる = select が効いている
      expect({pull('daily'), pull('weekly'), pull('monthly')}.length, 3);
    });

    test('ticket_type が欠けたら種別を言わない汎用文になる', () {
      // Backend が fields を返さない旧デプロイと通信した場合を想定。
      // ここで既定を daily にすると、weekly を引いたのに
      // 「デイリーチケットが…」と **誤った種別**を出してしまう。
      final text = localizedApiError(
          en, 'gacha_pull_not_enough_tickets', const {})!;
      expect(text, isNot(contains('daily')));
      expect(text, isNot(contains('weekly')));
      expect(text, isNot(contains('monthly')));
      expect(text, contains('tickets'));
    });

    test('引き直しダイヤの必要数 / 所持数が文面に入る', () {
      final text = localizedApiError(
        en,
        'gacha_redo_insufficient_diamonds',
        const {'required': '30', 'owned': '12'},
      )!;
      expect(text, contains('30'));
      expect(text, contains('12'));
    });

    test('ダイヤの数値が欠けていても例外にならない', () {
      expect(
        localizedApiError(en, 'gacha_redo_insufficient_diamonds', const {}),
        isNotNull,
      );
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // C: ApiError / formatApiError との結線
  // ───────────────────────────────────────────────────────────────────────────
  group('C: 結線', () {
    setUp(() => ServiceL10n.debugSetLocale(const Locale('en')));
    tearDown(() => ServiceL10n.debugSetLocale(const Locale('ja')));

    test('localizedMessage が server の日本語ではなく ARB を返す', () {
      final err = ApiError.fromResponse(const {
        'error': {
          'code': 'shop_purchase_insufficient_coins',
          'message': 'コインが足りないようですね 🪶',
        },
      });

      expect(err.message, contains('コイン'), reason: '前提: server は日本語を返す');
      expect(err.localizedMessage,
          en.apiErrorShopPurchaseInsufficientCoinsSabi_message);
      expect(err.localizedMessage, isNot(contains('コイン')));
    });

    test('未知 code では server の message をそのまま返す (段階導入)', () {
      final err = ApiError.fromResponse(const {
        'error': {'code': 'some_unmapped_code', 'message': '未対応の文言です 🪶'},
      });
      expect(err.localizedMessage, '未対応の文言です 🪶');
    });

    test('formatApiError も ARB 経由になっている', () {
      final e = _FakeDioError(const {
        'error': {
          'code': 'social_gift_not_friend',
          'message': 'フレンドにのみ贈れます 🪶',
        },
      });
      expect(formatApiError(e), en.apiErrorSocialGiftNotFriendSabi_message);
    });

    test('ja locale では日本語が返る (英語化が日本語を壊していない)', () {
      ServiceL10n.debugSetLocale(const Locale('ja'));
      final err = ApiError.fromResponse(const {
        'error': {
          'code': 'shop_purchase_insufficient_coins',
          'message': 'コインが足りないようですね 🪶',
        },
      });
      expect(err.localizedMessage, 'コインが足りないようですね 🪶');
    });

    // 【FEAT-475 Phase 4 (2026-08-04)】旧形式 A の検査はここから外した。
    //
    // 元は「旧形式 `{'error': '<文字列>'}` でも message が出る」を縛っていたが、
    // Phase 4 で Backend の生成側が 0 件になり parser を削除したので成立しない。
    // 「旧形式は汎用文言に落ちる」という新しい契約は
    // `api_error_format_test.dart` が持つ (本ファイルは locale 解決が担当範囲)。

    test('code はあるが message が空の場合は汎用文言に落ちる', () {
      // locale 解決の対象外 + message 空 = 表示できるものが無いケース。
      // `localizedMessage` が空文字を返すと SnackBar が空になるので、
      // 呼び出し側 (`formatApiError`) の空チェックが効くことを確かめる。
      final err = ApiError.fromResponse(const {
        'error': {'code': 'some_unmapped_code', 'message': ''},
      });
      expect(err.localizedMessage, isEmpty);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // D: guard の空振り検出
  // ───────────────────────────────────────────────────────────────────────────
  group('D: guard の空振り検出', () {
    test('対象 code が 20 件以上ある', () {
      // 列挙が空になると A/B の検査が 0 件ループで常時 green になる
      expect(kLocalizedApiErrorCodes.length, greaterThanOrEqualTo(20));
    });

    test('code に重複が無い', () {
      expect(kLocalizedApiErrorCodes.toSet().length,
          kLocalizedApiErrorCodes.length);
    });
  });
}

/// `formatApiError` は `(e as dynamic).response?.data` を読むだけなので、
/// dio に依存せず最小の代役で足りる。
class _FakeDioError {
  _FakeDioError(this.data);
  final Object data;
  _FakeResponse get response => _FakeResponse(data);
}

class _FakeResponse {
  _FakeResponse(this.data);
  final Object data;
}
