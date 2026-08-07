// 【BUG-143 (2026-08-07)】ショップ購入リストのフィルタ契約。
//
// ## 何が起きていたか
//
// ユーザー報告 2026-08-07:
// 「ミスリルの剣や竜殺しの剣がショップで 0coin で売られている。
//   ショップで売られていない想定であった。」
//
// Backend の `ShopItemsView` は、所持品リストに出すために **catalog に entry が
// 無い所持武器** (mythril_sword / dragon_slayer / starter_sword) を
// `price: 0, diamond_price: 0` で動的注入する (2026-07-09)。
//
// その実装は「Mobile が価格 0 の item を購入モードから除外する」前提で書かれ、
// shop.py のコメントが本 repo の shop_page.dart:179-184 を名指ししていた。
// ところが **その行にあったのは `itemType != 'gacha_only'` のフィルタ**で、
// 価格を見る処理は当時も今も存在しなかった。注入 entry は
// `item_type: 'weapon'` なので素通りし、0 コインで購入リストに並んでいた。
//
// ## 本テストが縛るもの
//
// `ShopItem.isPurchasable` = 3 通貨 (coin / ダイヤ / 交換ピース) のいずれかに
// 価格が付いていること。ここが崩れると、Backend が注入する武器が再び
// 購入リストに並ぶ。
//
// **Backend 側 (`shop.py` の注入処理) は本 getter の存在に依存している。**
// 消す場合は shop.py の注入コメントも同時に直すこと。
//
// 実行方法:
// ```powershell
// cd mobile
// flutter test test/gamification/shop_purchasable_test.dart
// ```

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sabiowl/features/gamification/models/gamification_models.dart';

/// Backend レスポンス 1 件分を組み立てる。
/// **`fromJson` を通す**ことで、field 名の取り違えも同時に検査する。
ShopItem _item({
  required String id,
  int price = 0,
  int diamondPrice = 0,
  int piecePrice = 0,
  String itemType = 'consumable',
  int ownedQuantity = 0,
}) {
  return ShopItem.fromJson({
    'id': id,
    'name': id,
    'category': 'weapons',
    'emoji': '⚔️',
    'rarity': 3,
    'price': price,
    'diamond_price': diamondPrice,
    'piece_price': piecePrice,
    'effect': '',
    'item_type': itemType,
    'owned_quantity': ownedQuantity,
  });
}

/// shop_page.dart の購入モードフィルタと同一の条件。
///
/// widget を起動せずに条件式だけを検査する。UI 構築を挟むと、落ちたときに
/// 「フィルタが壊れた」のか「描画が壊れた」のか切り分けられなくなるため。
List<ShopItem> _purchaseMode(List<ShopItem> items) => items
    .where((i) => i.itemType != 'gacha_only' && i.isPurchasable)
    .toList();

void main() {
  group('A: isPurchasable の判定', () {
    test('coin 価格があれば購入可', () {
      expect(_item(id: 'steel_sword', price: 800).isPurchasable, isTrue);
    });

    test('ダイヤ価格があれば購入可', () {
      expect(_item(id: 'slot_expand', diamondPrice: 120).isPurchasable, isTrue);
    });

    test('ピース価格があれば購入可', () {
      expect(_item(id: 'piece_xp_boost', piecePrice: 100).isPurchasable, isTrue);
    });

    test('3 通貨すべて 0 なら購入不可', () {
      expect(_item(id: 'dragon_slayer').isPurchasable, isFalse);
    });
  });

  group('B: 購入モードのフィルタ', () {
    test('Backend が注入する catalog 外の武器を購入リストに出さない', () {
      // Backend `ShopItemsView` の注入 entry と同じ形
      // (item_type='weapon' / 全価格 0 / owned_quantity=1)。
      final injected = [
        _item(id: 'dragon_slayer', itemType: 'weapon', ownedQuantity: 1),
        _item(id: 'mythril_sword', itemType: 'weapon', ownedQuantity: 1),
        _item(id: 'starter_sword', itemType: 'weapon', ownedQuantity: 1),
      ];

      expect(
        _purchaseMode(injected),
        isEmpty,
        reason: 'ガチャ / onboarding 武器が購入リストに並んでいる。'
            '0 コインの商品として表示され、タップすると Backend が 404 を返す '
            '(BUG-143)',
      );
    });

    test('通常の販売武器は購入リストに残る', () {
      // ここが落ちたら、フィルタが**買えるものまで巻き込んで消した**合図。
      final catalog = [
        _item(id: 'bronze_sword', price: 100, itemType: 'weapon'),
        _item(id: 'steel_sword', price: 800, itemType: 'weapon'),
      ];

      expect(
        _purchaseMode(catalog).map((i) => i.id),
        ['bronze_sword', 'steel_sword'],
      );
    });

    test('所持済みでも、買えるものは購入リストに残る (重複購入できる消耗品)', () {
      final owned =
          _item(id: 'recovery_potion', price: 50, ownedQuantity: 3);
      expect(_purchaseMode([owned]), hasLength(1));
    });

    test('gacha_only は価格の有無に関わらず購入リストに出ない', () {
      // `isPurchasable` とは独立した既存ルール (2026-06-14)。
      // 将来 gacha_only 品にダイヤ価格が付いても、この宣言的な除外は効き続ける。
      final gachaOnly =
          _item(id: 'xp_boost_1.5x', itemType: 'gacha_only', diamondPrice: 99);
      expect(_purchaseMode([gachaOnly]), isEmpty);
    });
  });

  group('C: 所持品モードは従来どおり全部見せる', () {
    test('購入手段が無い武器も所持していれば所持品リストに出る', () {
      // 2026-07-09 の修正 (ガチャ武器が所持品に出ない) を巻き戻していないこと。
      // 所持品モードのフィルタは `ownedQuantity > 0` のみ。
      final items = [
        _item(id: 'dragon_slayer', itemType: 'weapon', ownedQuantity: 1),
        _item(id: 'steel_sword', price: 800, itemType: 'weapon'),
      ];

      final inventory = items.where((i) => i.ownedQuantity > 0).toList();

      expect(
        inventory.map((i) => i.id),
        ['dragon_slayer'],
        reason: '所持品モードから gacha 武器が消えると 2026-07-09 の修正の '
            '巻き戻しになる',
      );
    });
  });

  // ───────────────────────────────────────────────────────────────────────
  // E: shop_page.dart が実際に isPurchasable を使っているか
  //
  // A-D の `_purchaseMode` は shop_page.dart の条件式を**複製**している。
  // 複製だけを検査していると、shop_page.dart から isPurchasable が消えても
  // 全部緑のまま通ってしまう。実ソースを読んで結線を確認する。
  //
  // 同パターン: test/habits/habit_card_period_count_test.dart (BUG-73) /
  //             test/category_strings_truth_test.dart (FEAT-307)
  // ───────────────────────────────────────────────────────────────────────
  group('E: shop_page.dart との結線', () {
    late final String shopPageSource;

    setUpAll(() {
      final f = File('lib/features/gamification/pages/shop_page.dart');
      expect(f.existsSync(), isTrue,
          reason: 'shop_page.dart が cwd 配下に見つからない (cwd 不一致)');
      shopPageSource = f.readAsStringSync();
    });

    test('購入モードのフィルタが isPurchasable を参照している', () {
      expect(
        shopPageSource.contains('i.isPurchasable'),
        isTrue,
        reason: 'shop_page.dart の購入モードフィルタから isPurchasable が消えている。'
            'Backend が所持品表示のために注入する catalog 外の武器 '
            '(竜殺しの剣 等) が 0 コインで購入リストに並ぶ (BUG-143)',
      );
    });

    test('gacha_only の除外も残っている', () {
      expect(
        shopPageSource.contains("i.itemType != 'gacha_only'"),
        isTrue,
        reason: 'isPurchasable への置き換えで gacha_only の除外 (2026-06-14) を '
            '消してはいけない。両者は根拠が異なる (意味 vs 構造)',
      );
    });
  });

  group('D: 旧 Backend からのレスポンス', () {
    test('piece_price 欠落でも coin 価格があれば購入可', () {
      final legacy = ShopItem.fromJson({
        'id': 'steel_sword',
        'name': '鋼の剣',
        'category': 'weapons',
        'emoji': '⚔️',
        'rarity': 3,
        'price': 800,
        'effect': '',
        'item_type': 'weapon',
        'owned_quantity': 0,
      });
      expect(legacy.isPurchasable, isTrue);
    });
  });
}
