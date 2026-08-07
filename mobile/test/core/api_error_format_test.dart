// 【FEAT-515 / FEAT-475 Phase 4】Backend のエラー形式がユーザーに届くことを縛る。
//
// ## なぜ必要か
//
// `formatApiError` は旧実装で `data['error'] as String` と書かれていた。
// 新形式 `{'error': {'code', 'message'}}` では `data['error']` が **Map** なので
// cast が例外になり、`catch (_)` に飲まれて **必ず汎用文言にフォールバック**する。
//
// FEAT-475 で 77 endpoint を新形式に移行済みだったため、**その 77 経路すべてで
// 個別のエラー文言がユーザーに届いていなかった**。例外は握り潰され、型エラーと
// しても表面化せず、「なんとなく汎用文言が出る」だけだったので気付けなかった。
//
// ## 【FEAT-475 Phase 4 (2026-08-04)】旧形式 A / B の検査を落とした
//
// Backend 側の生成側が 0 件になったので、`ApiError.fromResponse` から
// 旧形式の parser を削除した。それに合わせて本テストも
// **「旧形式でも文言が出る」から「新形式以外は汎用文言に落ちる」** に変えている。
//
// 旧形式を投げたら汎用文言になる、という検査を **残している**のが要点で、
// 「parser を消したつもりが実は別経路で拾えていた」を検出できる。

import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabiowl/core/api/dio_error_helper.dart';
import 'package:sabiowl/core/api/error_formatter.dart';
import 'package:sabiowl/core/l10n/service_l10n.dart';

DioException _err(dynamic body) => DioException(
      requestOptions: RequestOptions(path: '/api/test/'),
      response: Response<dynamic>(
        requestOptions: RequestOptions(path: '/api/test/'),
        statusCode: 400,
        data: body,
      ),
    );

void main() {
  // `formatApiError` は fallback に ServiceL10n を使う。テスト間で漏れないよう戻す。
  tearDown(() => ServiceL10n.debugSetLocale(const Locale('ja')));

  final generic = ServiceL10n.current.coreApiDefaultErrorSabi_message;

  group('formatApiError — 新形式のサーバー文言が届く', () {
    test('新形式 {error: {code, message}}', () {
      // ここが旧実装で壊れていた本体。
      //
      // 【FEAT-515 Phase 2】code は **locale 解決の対象外のもの**を使う。
      // 対象 code (`gacha_pull_not_enough_tickets` 等) を使うと、
      // 本テストが見ているのが「新形式を parse できたか」なのか
      // 「ARB を引けたか」なのか区別できなくなるため。
      // ARB 解決側は `api_error_l10n_test.dart` が担当する。
      final msg = formatApiError(_err({
        'error': {
          'code': 'gacha_status_unavailable',
          'message': 'ガチャ情報の取得に失敗しました。少し時間をおいてお試しください 🪶',
        },
      }));
      expect(msg, 'ガチャ情報の取得に失敗しました。少し時間をおいてお試しください 🪶',
          reason: '新形式の message が汎用文言に置き換わっている');
    });

    test('message が空の新形式は汎用文言に落ちる', () {
      final msg = formatApiError(_err({
        'error': {'code': 'some_code', 'message': ''},
      }));
      expect(msg, generic);
    });

    test('パースできない body は汎用文言に落ちる', () {
      final msg = formatApiError(_err('プレーンテキスト'));
      expect(msg, generic);
    });

    test('response が無い例外でも例外を投げない', () {
      expect(() => formatApiError(Exception('boom')), returnsNormally);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // 【FEAT-475 Phase 4】旧形式は「読めない」ことを縛る
  // ───────────────────────────────────────────────────────────────────────────
  group('旧形式 A / B は parse されない (Phase 4 で削除済み)', () {
    test('旧形式 A {error: "<文字列>"} は汎用文言に落ちる', () {
      // Backend の生成側は 0 件 (test_error_response_format.py が縛っている)。
      // ここが「文字列がそのまま出る」に戻ったら parser が復活している。
      expect(formatApiError(_err({'error': 'コインが不足しています 🪶'})), generic);
      expect(ApiError.fromResponse({'error': 'daily_battle_limit_reached'}).code,
          'unknown',
          reason: '旧形式 A の code を拾ってしまうと、削除したはずの経路が生きている');
    });

    test('旧形式 B {errors: {...}} は fields を持たない', () {
      final e = ApiError.fromResponse({
        'errors': {'name': 'この項目は必須です'},
      });
      expect(e.code, 'unknown');
      expect(e.fields, isEmpty);
    });

    test('DRF 既定の {detail: ...} も従来どおり汎用文言 (挙動が変わっていない)', () {
      // 401 / 403 / throttle が返す形。元々どの parser にも当たらず
      // 汎用文言だった。Phase 4 で**変わっていない**ことを固定する。
      expect(formatApiError(_err({'detail': '認証情報が含まれていません。'})), generic);
    });
  });

  group('ApiError.code — Mobile の分岐は code だけを見る', () {
    // 【FEAT-515 Phase 1 の申し送り】raw `data['error']` を文字列比較すると
    // 新形式で Map になり **黙って false** になる。必ず ApiError.code を使う。
    test('新形式から code が取れる', () {
      final e = ApiError.fromResponse({
        'error': {'code': 'daily_battle_limit_reached', 'message': '本日の上限です 🪶'},
      });
      expect(e.code, 'daily_battle_limit_reached');
    });

    test('新形式の fields が取れる', () {
      final e = ApiError.fromResponse({
        'error': {
          'code': 'contact_validation_failed',
          'message': '入力内容をご確認ください 🪶',
          'fields': {'name': 'この項目は必須です'},
        },
      });
      expect(e.fields['name'], 'この項目は必須です');
    });
  });
}
