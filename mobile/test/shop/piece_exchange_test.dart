// 【FEAT-497 (2026-08-04)】交換ピース (dead currency 解消) の Flutter 側契約。
//
// ## 何を守るか
//
// 交換ピースは **3 つ目の通貨**。コイン / ダイヤと違って
// `price` も `diamondPrice` も 0 なので、判定の順序を間違えると
// **「🪙 0」ボタンとして描画されて、タダで買えるように見える**。
// Backend 側 (`test_shop_piece_exchange.py` の S6) と同じ罠が UI にもある。
//
// また `piecePrice` は旧 Backend では field ごと欠落するので、
// **欠落しても壊れない** (= ピース商品として扱わない) ことも縛る。
//
// 実行方法:
// ```powershell
// cd mobile
// flutter test test/shop/piece_exchange_test.dart
// ```

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabiowl/features/gamification/models/gamification_models.dart';
import 'package:sabiowl/features/habits/models/player.dart';
import 'package:sabiowl/l10n/app_localizations.dart';

ShopItem _item({int price = 0, int diamondPrice = 0, int piecePrice = 0}) =>
    ShopItem(
      id: 'x',
      name: 'テスト',
      category: 'pieces',
      emoji: '🧩',
      rarity: 2,
      price: price,
      diamondPrice: diamondPrice,
      effect: '',
      itemType: 'piece_exchange',
      ownedQuantity: 0,
      piecePrice: piecePrice,
    );

void main() {
  // ───────────────────────────────────────────────────────────────────────────
  // A: ShopItem の parse
  // ───────────────────────────────────────────────────────────────────────────
  group('A: ShopItem.piecePrice の parse', () {
    test('piece_price を読み取り isPieceExchange が true になる', () {
      final item = ShopItem.fromJson(const {
        'id': 'piece_character_ticket',
        'name': 'キャラ交換券',
        'category': 'pieces',
        'price': 0,
        'diamond_price': 0,
        'piece_price': 500,
        'item_type': 'piece_exchange',
      });
      expect(item.piecePrice, 500);
      expect(item.isPieceExchange, isTrue);
    });

    test('piece_price 欠落時は 0 = ピース商品ではない (旧 Backend 互換)', () {
      // Backend を更新する前のアプリ / 逆順デプロイでも壊れないこと。
      // ピースタブが空になるだけで、他タブの購入は従来通り動く。
      final item = ShopItem.fromJson(const {
        'id': 'recovery_potion',
        'name': '回復薬',
        'category': 'items',
        'price': 0,
        'diamond_price': 30,
        'item_type': 'battle_consumable',
      });
      expect(item.piecePrice, 0);
      expect(item.isPieceExchange, isFalse);
    });

    test('コイン / ダイヤ商品は isPieceExchange が false', () {
      expect(_item(price: 100).isPieceExchange, isFalse);
      expect(_item(diamondPrice: 30).isPieceExchange, isFalse);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // B: 通貨判定の順序 — 🔴 ピース商品がコイン商品に化けないこと
  // ───────────────────────────────────────────────────────────────────────────
  group('B: 通貨の取り違え防止', () {
    test('ピース商品は price / diamondPrice が 0 でもコイン扱いにならない', () {
      final item = _item(piecePrice: 100);

      // UI (shop_page.dart) は次の順で分岐する:
      //   isPieceExchange -> diamondPrice > 0 -> (それ以外 = コイン)
      // ピース判定を後ろに置くと `price=0` のコインボタンになり、
      // **所持 0 でも押せて「0 コインで買える」ように見える**。
      expect(item.isPieceExchange, isTrue,
          reason: '🔴 これが false になると、UI がコイン経路に落ちます');
      expect(item.price, 0);
      expect(item.diamondPrice, 0);
    });

    test('所持ピースで購入可否が決まる', () {
      final item = _item(piecePrice: 500);
      expect(499 >= item.piecePrice, isFalse, reason: '不足なら押せない');
      expect(500 >= item.piecePrice, isTrue, reason: 'ちょうどなら押せる');
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // C: Player.exchangePieces
  // ───────────────────────────────────────────────────────────────────────────
  group('C: Player.exchangePieces', () {
    test('exchange_pieces を parse する', () {
      final p = Player.fromJson(const {
        'id': 1,
        'name': 'テスト',
        'exchange_pieces': 350,
      });
      expect(p.exchangePieces, 350);
    });

    test('欠落時は 0 (旧 Backend 互換、残高 0 表示で壊れない)', () {
      final p = Player.fromJson(const {'id': 1, 'name': 'テスト'});
      expect(p.exchangePieces, 0);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // D: 文言 — 消費先を案内していること
  // ───────────────────────────────────────────────────────────────────────────
  group('D: 文言', () {
    test('ピースタブ / 交換ボタンの文言が ja / en 両方にある', () {
      for (final locale in const [Locale('ja'), Locale('en')]) {
        final l = lookupAppLocalizations(locale);
        expect(l.gamifShopTabPiece, isNotEmpty);
        expect(l.gamifShopBuyWithPieceButton(100), contains('100'));
        expect(l.gamifGachaPieceLabel, isNotEmpty);
        expect(l.gamifGachaPieceToast, isNotEmpty);
      }
    });

    test('ピース獲得 toast が交換先 (ショップのピースタブ) を案内する', () {
      // v1.0 の dead currency 体験は「貯まるが使い道が分からない」だった。
      // 獲得時に消費先を書いておかないと同じ印象になる。
      final ja = lookupAppLocalizations(const Locale('ja'));
      final en = lookupAppLocalizations(const Locale('en'));
      expect(ja.gamifGachaPieceToast, contains(ja.gamifShopTabPiece));
      expect(en.gamifGachaPieceToast.toLowerCase(),
          contains(en.gamifShopTabPiece.toLowerCase()));
    });

    test('en の文言に日本語が混ざっていない', () {
      final en = lookupAppLocalizations(const Locale('en'));
      final jaChars = RegExp(r'[ぁ-んァ-ヶ一-龠]');
      for (final s in [
        en.gamifShopTabPiece,
        en.gamifShopBuyWithPieceButton(100),
        en.gamifGachaPieceLabel,
        en.gamifGachaPieceToast,
      ]) {
        expect(jaChars.hasMatch(s), isFalse, reason: '英語 UI に日本語: $s');
      }
    });
  });
}
