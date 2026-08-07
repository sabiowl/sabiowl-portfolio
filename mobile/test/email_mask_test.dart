// 【FEAT-289 → BUG-89 (2026-06-10)】email_mask ユーティリティの契約テスト。
// マスク表示はプライバシー機能のため、エッジケース（空文字 / null / '@' 欠落 /
// 先頭 '@' / 多重 '@'）の挙動を契約として固定する。
//
// 【BUG-89 (2026-06-10)】先頭 1 文字 → 2 文字に拡張。識別性向上 + プライバシー保護維持。

import 'package:flutter_test/flutter_test.dart';
import 'package:sabiowl/core/utils/email_mask.dart';

void main() {
  group('maskEmail — 基本ケース', () {
    test('一般的な email を「先頭 2 文字 + 4 アスタリスク + ドメイン」に変換', () {
      expect(maskEmail('apple@icloud.com'), 'ap****@icloud.com');
      expect(maskEmail('taro.yamada.99@gmail.com'), 'ta****@gmail.com');
    });

    test('Apple relay email も同形式でマスクされる', () {
      expect(
        maskEmail('axxx@privaterelay.appleid.com'),
        'ax****@privaterelay.appleid.com',
      );
    });

    test('ローカル部 1 文字なら 1 文字のみ表示 + 固定 4 アスタリスク（フォールバック）', () {
      // 元の長さを推測されないよう、アスタリスク数は元のローカル部長に依存しない。
      // 2 文字未満の極稀ケースは取得できた分だけ表示し、無意味な穴埋めはしない。
      expect(maskEmail('a@icloud.com'), 'a****@icloud.com');
    });

    test('ローカル部 2 文字ぴったりなら 2 文字すべて表示 + 4 アスタリスク', () {
      expect(maskEmail('ab@example.com'), 'ab****@example.com');
    });
  });

  group('maskEmail — エッジケース', () {
    test('null / 空文字 → null（呼び出し側で「-」フォールバック）', () {
      expect(maskEmail(null), isNull);
      expect(maskEmail(''),   isNull);
    });

    test('"@" が含まれない → null（不正形式扱い）', () {
      expect(maskEmail('not-an-email'), isNull);
    });

    test('"@" が先頭 → null（不正形式扱い、ローカル部空のため）', () {
      expect(maskEmail('@icloud.com'), isNull);
    });

    test('多重 "@" は最初の "@" を境界として処理（ローカル部 1 文字のため 1 文字フォールバック）', () {
      // RFC 的には不正だが、防御的に最初の '@' で分割（ドメイン側に '@' は通常残らない）
      expect(maskEmail('a@b@c.com'), 'a****@b@c.com');
    });
  });
}
