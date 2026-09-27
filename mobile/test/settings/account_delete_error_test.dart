// 【BUG-157 (2026-09-11)】アカウント削除の「失敗」が、削除できたのかを区別できること。
//
// ## 何が起きていたか
//
// `_executeDelete()` は 6 つの処理を **1 つの `try/catch`** で包み、
// **どこで落ちても同じ汎用文言**を出していた。つまり
//
//   ①で落ちた   → アカウントは**残っている**
//   ②③で落ちた → アカウントは**既に消えている**
//
// が、ユーザーにも運営にも区別できなかった。
//
// 🔴 後者の場合、**アカウントは消えているのに「うまくいきませんでした」と
// 表示され、画面は削除画面に留まる**。ユーザーは「消えていない」と信じて
// もう一度押すが、トークンはもう無効なので今度は①が失敗する ——
// **同じ文言のまま、状態だけが変わっている。**
//
// ## 🔴 「①が成功 + ③が失敗 → 遷移する」が本体
//
// 文言を差し替えただけの実装でも「①が失敗 → 専用文言」は緑になる。
// **分離が本体で、文言は副産物**である。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final source =
      File('lib/features/settings/pages/account_page.dart').readAsStringSync();

  /// `_executeDelete()` の本体。
  String executeDeleteBody() {
    final at = source.indexOf('  Future<void> _executeDelete() async {');
    expect(at, greaterThan(0), reason: '_executeDelete が見つからない');
    final end = source.indexOf('\n  /// FEAT-195:', at);
    expect(end, greaterThan(at));
    return source.substring(at, end);
  }

  /// ①（サーバでの削除）の `catch` ブロック。
  String serverDeleteCatch() {
    final body = executeDeleteBody();
    final at = body.indexOf('deleteAccount(');
    final catchAt = body.indexOf('} catch (e, st) {', at);
    expect(catchAt, greaterThan(0), reason: '① の catch が見つからない');
    return body.substring(catchAt, body.indexOf('\n    }', catchAt));
  }

  group('🔴 ①と②以降が分かれている（本体）', () {
    test('① が独立した try/catch を持ち、その中で return している', () {
      final block = serverDeleteCatch();
      expect(
        block.contains('return;'), isTrue,
        reason: 'サーバ削除が失敗したときだけ中断すること',
      );
    });

    test('🔴 context.go が後片付けの外（最後）にある', () {
      final body = executeDeleteBody();
      final goAt = body.lastIndexOf('context.go(AppRoutes.auth)');
      expect(goAt, greaterThan(0), reason: '遷移が消えている');

      // 後片付け（logout / deleteGuestToken / _clearOnboardingLocalData）が
      // すべて `context.go` より前にあること = go はそれらの後ろにある。
      for (final step in [
        'logout()',
        'deleteGuestToken()',
        '_clearOnboardingLocalData()',
      ]) {
        final at = body.indexOf(step);
        expect(at, greaterThan(0), reason: '$step が消えている');
        expect(
          at, lessThan(goAt),
          reason: '$step が context.go より後ろにある。'
              '後片付けの失敗で遷移が飛ぶと、**削除済みなのに削除画面に留まる**',
        );
      }
    });

    test('🔴 後片付けが個別の try/catch で包まれている', () {
      final body = executeDeleteBody();
      final afterServerDelete = body.substring(body.indexOf('②以降'));
      // 後片付けは 4 ブロック以上（posthog / logout / google / guest token）
      expect(
        'try {'.allMatches(afterServerDelete).length,
        greaterThanOrEqualTo(4),
        reason: '後片付けをまとめて 1 つの try で包むと、'
            '1 つ落ちた時点で残りと遷移が飛ぶ',
      );
    });

    test('⚠️ 後片付けの失敗を黙って捨てていない（debugPrint が残っている）', () {
      // ③の `logout()` が落ちるとローカルにトークンが残り、次回起動で
      // 「消えたアカウントのトークン」で 401 になる（BUG-156 の詰みに合流）。
      // **ログが唯一の手がかりになる。**
      final body = executeDeleteBody();
      expect(body.contains("debugPrint('[account_delete] logout failed"), isTrue);
      expect(
        body.contains("debugPrint('[account_delete] posthog capture failed"),
        isTrue,
      );
    });
  });

  group('文言', () {
    test('🔴 ① の失敗は専用文言（汎用文言ではない）', () {
      final block = serverDeleteCatch();
      expect(
        block.contains('settingsAccountDeleteFailedSabi_message'), isTrue,
        reason: '汎用文言だと「通信を確認する」という取れる行動が伝わらない',
      );
    });

    test('🔴 削除成功以降の経路で汎用エラー文言を出していない', () {
      final body = executeDeleteBody();
      expect(
        body.contains('settingsGenericErrorSnackbarSabi_message'), isFalse,
        reason: '②以降で汎用文言を出すと「削除できたのに失敗と表示される」に戻る',
      );
    });

    test('ja / en の両方に文言がある', () {
      for (final path in ['lib/l10n/app_ja.arb', 'lib/l10n/app_en.arb']) {
        final arb = jsonDecode(
          File(path).readAsStringSync().replaceFirst('﻿', ''),
        ) as Map<String, dynamic>;
        expect(
          arb.containsKey('settingsAccountDeleteFailedSabi_message'), isTrue,
          reason: '$path に文言がない（check_i18n_coverage が落ちる）',
        );
      }
    });

    test('⚠️ サビ口調ルール —— 「！」を使わない / 🪶 は文末', () {
      final arb = jsonDecode(
        File('lib/l10n/app_ja.arb').readAsStringSync().replaceFirst('﻿', ''),
      ) as Map<String, dynamic>;
      final msg = arb['settingsAccountDeleteFailedSabi_message'] as String;
      expect(msg.contains('！'), isFalse);
      expect(msg.trimRight().endsWith('🪶'), isTrue);
      expect(msg.contains('通信状況'), isTrue,
          reason: 'ユーザーが取れる行動を 1 つ示す');
    });
  });
}
