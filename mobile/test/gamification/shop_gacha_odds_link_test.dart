// 【2026-08-07】ショップ画面の排出確率導線の配置契約。
//
// ## 経緯
//
// FEAT-518 (2026-08-05) が App Store Guideline 3.1.1 (*prior to purchase* の
// 確率開示) 対応として、ショップ画面にも排出確率への導線を置いた。Sabiowl では
//
//     実通貨 120 円 → ダイヤ 120 → ticket_weekly (💎150) → 重み付き抽選
//
// の経路が成立しており、チケットを買う画面が購入前開示の対象になる。
//
// ところが指示書が指定した配置は「チケット購入セクションからのリンク」なのに、
// 実装は **AppBar のグローバルアイコン**になっていた。装備タブでもピースタブでも
// `%` が出る状態で、ユーザー報告 2026-08-07「ガチャ画面だけで良いと思います」に
// 至った。
//
// 本テストは移設後の配置を縛る。**導線そのものを消してはいけない** ——
// 消すと Guideline 3.1.1 の購入前開示がショップ側から失われる。
//
// ## なぜ条件を関数で検査できるのか
//
// `shouldShowGachaOddsLink` は shop_page.dart の **実装が実際に呼ぶ関数**。
// 条件式をテスト側に複製していないので、実装から条件が消えれば必ず落ちる。
// BUG-143 では条件式を複製して検査していたため、実装から消しても A-D 群が
// 全部緑のまま通った。同じ轍を踏まないための構成。
//
// ## このテストが**カバーしていないこと** (実測)
//
// 負の検証で確認した限界: `if (showOddsLink) _buildOddsLinkHeader(...)` を
// `if (false && showOddsLink) ...` に書き換えても **全件緑のまま通る**。
// シンボルは残っているのでソース走査を素通りする。
//
// (なお、当初は `shouldShowGachaOddsLink(` の存在だけを見ていたが、これは
//  **関数定義の宣言行にもマッチする**ため、呼び出しを丸ごと消しても通った。
//  負の検証で発覚し、引数名まで含めた `shouldShowGachaOddsLink(items:` に
//  修正済み。「ソース走査を書いた」だけでは検査になっていないことがある。)
//
// 検出できるのは以下の 3 つ:
//   - 条件そのものの変更 (A 群、実装が呼ぶ関数を直接テストしている)
//   - 呼び出し / widget / route の削除 (B 群)
//   - AppBar への差し戻し (B 群)
//
// 「レンダリングされること」まで縛るには ShopPage の widget test が要る
// (shopNotifierProvider + playerNotifierProvider + GoRouter のモックが必要)。
// 導線が消えると App Store Guideline 3.1.1 の購入前開示に関わるため、
// **v1.1 の審査提出前に実機で目視すること** を運用で補う。
//
// 実行方法:
// ```powershell
// cd mobile
// flutter test test/gamification/shop_gacha_odds_link_test.dart
// ```

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sabiowl/features/gamification/models/gamification_models.dart';
import 'package:sabiowl/features/gamification/pages/shop_page.dart';

ShopItem _item(String id, String itemType, {int price = 100}) {
  return ShopItem.fromJson({
    'id': id,
    'name': id,
    'category': 'x',
    'emoji': '⭐',
    'rarity': 1,
    'price': price,
    'effect': '',
    'item_type': itemType,
    'owned_quantity': 0,
  });
}

void main() {
  group('A: 排出確率リンクを出す条件', () {
    test('チケットタブ (consumable のみ) では出す', () {
      expect(
        shouldShowGachaOddsLink(
          items: [
            _item('ticket_daily', 'consumable'),
            _item('ticket_weekly', 'consumable', price: 0),
          ],
          isInventory: false,
        ),
        isTrue,
      );
    });

    test('「すべて」タブ (チケットが混ざる) でも出す', () {
      // タブ番号で判定すると、ここから ticket_weekly を買うユーザーが
      // 購入前に確率へ到達できなくなる。
      expect(
        shouldShowGachaOddsLink(
          items: [
            _item('steel_sword', 'weapon'),
            _item('ticket_weekly', 'consumable'),
            _item('recovery_potion', 'battle_consumable'),
          ],
          isInventory: false,
        ),
        isTrue,
        reason: '「すべて」タブにもチケットが並ぶ。ここで出さないと '
            'Guideline 3.1.1 の購入前開示が抜ける',
      );
    });

    test('装備タブでは出さない (ユーザー報告の発端)', () {
      expect(
        shouldShowGachaOddsLink(
          items: [_item('steel_sword', 'weapon')],
          isInventory: false,
        ),
        isFalse,
      );
    });

    test('ピースタブでは出さない', () {
      expect(
        shouldShowGachaOddsLink(
          items: [_item('piece_xp_boost', 'piece_exchange')],
          isInventory: false,
        ),
        isFalse,
      );
    });

    test('アイテムタブ (battle_consumable / gacha_only) では出さない', () {
      // `consumable` と `battle_consumable` は別の item_type。
      // 前方一致で判定すると誤爆する。
      expect(
        shouldShowGachaOddsLink(
          items: [
            _item('recovery_potion', 'battle_consumable'),
            _item('xp_boost_1.5x', 'gacha_only'),
            _item('streak_protection', 'streak_protection'),
          ],
          isInventory: false,
        ),
        isFalse,
        reason: 'battle_consumable を consumable と取り違えている',
      );
    });

    test('持ち物モードでは出さない (購入の文脈ではない)', () {
      expect(
        shouldShowGachaOddsLink(
          items: [_item('ticket_weekly', 'consumable')],
          isInventory: true,
        ),
        isFalse,
      );
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // B: shop_page.dart との結線
  //
  // A 群は条件関数を直接呼んでいるので複製ではないが、
  // 「その関数が実際に描画経路から呼ばれているか」までは見ていない。
  // 呼び出しが消えれば A は緑のまま導線だけが消える。
  // ─────────────────────────────────────────────────────────────────────────
  group('B: shop_page.dart との結線', () {
    late final String source;

    setUpAll(() {
      final f = File('lib/features/gamification/pages/shop_page.dart');
      expect(f.existsSync(), isTrue, reason: 'shop_page.dart が見つからない');
      source = f.readAsStringSync();
    });

    test('_buildTabContent が shouldShowGachaOddsLink を呼んでいる', () {
      // 【重要】`shouldShowGachaOddsLink(` だけで検査してはいけない。
      // **関数定義の宣言行にもマッチしてしまう**ため、呼び出しを丸ごと消しても
      // 緑のまま通る (負の検証で実際に踏んだ)。
      // 定義は `bool shouldShowGachaOddsLink({` で始まるので、
      // 引数名まで含めて「呼び出しの形」を縛る。
      expect(
        source.contains('shouldShowGachaOddsLink(items:'),
        isTrue,
        reason: '判定関数の**呼び出し**が消えている。ショップから排出確率へ到達'
            'できなくなり、App Store Guideline 3.1.1 の購入前開示が'
            'ショップ側から失われる (FEAT-518)',
      );
    });

    test('導線 widget が残っている', () {
      expect(
        source.contains('_buildOddsLinkHeader'),
        isTrue,
        reason: '排出確率リンクの widget が消えている',
      );
      expect(
        source.contains('AppRoutes.gachaOdds'),
        isTrue,
        reason: '確率画面への遷移が消えている',
      );
    });

    test('AppBar の actions に排出確率アイコンを戻していない', () {
      // 2026-08-07 の移設前は AppBar に IconButton(Icons.percent) があり、
      // 装備タブでもピースタブでも表示されていた。
      // `_GachaShortcutButton` の直前に IconButton が復活していないかを見る。
      final actionsArea = RegExp(
        r'IconButton\([^)]*Icons\.percent[\s\S]{0,200}?_GachaShortcutButton',
      );
      expect(
        actionsArea.hasMatch(source),
        isFalse,
        reason: 'AppBar に排出確率アイコンが戻っている。全タブに % が出るため '
            'ユーザー報告 2026-08-07 の再発になる',
      );
    });
  });
}
