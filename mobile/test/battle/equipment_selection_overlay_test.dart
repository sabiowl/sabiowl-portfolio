// 【FEAT-327 Phase 2】 EquipmentSelectionOverlay widget test 3 件。
//
// 検証対象 (guild_equipment_2.md §1.2 仕様準拠):
//   A: ヘッダー (＜ 戻る + 装備の変更 + ×) + 現在装備中の固定枠が描画される
//   B: 「装備する」ボタンタップで onEquip callback が発火する
//   C: ヘッダー「×」と「＜ 戻る」両方が onClose callback を発火する (3 経路のうち 2 経路)
//
// 設計判断: カード外背景タップで閉じる動線 (3 経路目) は親 (_PartyEditDialogState)
// 側で `GestureDetector(behavior: HitTestBehavior.opaque, onTap: onClose)` を背景に
// 重ねる責務のため、本 widget の単体 test スコープ外。

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sabiowl/features/battle/models/weapon_info.dart';
import 'package:sabiowl/features/battle/widgets/equipment_selection_overlay.dart';
import 'package:sabiowl/features/habits/providers/habits_provider.dart';
import 'package:sabiowl/l10n/app_localizations.dart';

void main() {
  group('FEAT-327 EquipmentSelectionOverlay 描画契約', () {
    const starter = WeaponInfo(
      id: 1, key: 'starter_sword', name: '見習いの剣', atkBonus: 10,
    );
    const bronze = WeaponInfo(
      id: 2, key: 'bronze_sword', name: '銅の剣', atkBonus: 5,
    );

    /// playerWeaponsProvider を fixed list で override してテストを deterministic にする。
    Widget _wrap(
      Widget child, {
      required List<WeaponInfo> weapons,
    }) {
      return ProviderScope(
        overrides: [
          playerWeaponsProvider.overrideWith((ref) async => weapons),
        ],
        child: MaterialApp(
          locale: const Locale('ja'),
          localizationsDelegates: [
            AppLocalizations.delegate,
            ...GlobalMaterialLocalizations.delegates,
          ],
          supportedLocales: const [Locale('ja'), Locale('en')],
          home: Scaffold(
            body: Center(
              child: SizedBox(width: 320, height: 600, child: child),
            ),
          ),
        ),
      );
    }

    testWidgets('A: ヘッダー + 現在装備中の固定枠 + 装備一覧が表示される', (tester) async {
      await tester.pumpWidget(_wrap(
        EquipmentSelectionOverlay(
          currentWeapon: starter,
          onClose: () {},
          onEquip: (_) {},
        ),
        weapons: [starter, bronze],
      ));
      await tester.pumpAndSettle();

      // ヘッダー: タイトル
      expect(find.text('装備の変更'), findsOneWidget);
      // ヘッダー: 戻るアイコン + × アイコン
      expect(find.byIcon(Icons.chevron_left), findsOneWidget);
      expect(find.byIcon(Icons.close), findsOneWidget);
      // 現在装備中の固定枠
      expect(find.text('現在装備中: ⚔️ 見習いの剣 (+10)'), findsOneWidget);
      // 装備一覧 (starter は装備中なのでボタンは「装備中」、bronze は「装備する」)
      expect(find.text('見習いの剣'), findsOneWidget);
      expect(find.text('銅の剣'), findsOneWidget);
      expect(find.text('装備中'), findsOneWidget);
      expect(find.text('装備する'), findsOneWidget);
    });

    testWidgets('B: 「装備する」ボタンタップで onEquip callback が発火する', (tester) async {
      WeaponInfo? equippedArg;
      await tester.pumpWidget(_wrap(
        EquipmentSelectionOverlay(
          currentWeapon: starter,
          onClose: () {},
          onEquip: (w) => equippedArg = w,
        ),
        weapons: [starter, bronze],
      ));
      await tester.pumpAndSettle();

      // bronze の「装備する」ボタンをタップ
      await tester.tap(find.text('装備する'));
      await tester.pumpAndSettle();

      expect(equippedArg, isNotNull,
          reason: '「装備する」タップで onEquip callback が発火するはず');
      expect(equippedArg!.key, 'bronze_sword');
    });

    testWidgets('C: ヘッダー「×」と「＜ 戻る」両方で onClose callback が発火する', (tester) async {
      int closeCount = 0;
      await tester.pumpWidget(_wrap(
        EquipmentSelectionOverlay(
          currentWeapon: starter,
          onClose: () => closeCount++,
          onEquip: (_) {},
        ),
        weapons: [starter],
      ));
      await tester.pumpAndSettle();

      // 「×」(Icons.close) タップ
      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();
      expect(closeCount, 1, reason: '× タップで 1 回目発火');

      // 「＜ 戻る」(Icons.chevron_left) タップ
      await tester.tap(find.byIcon(Icons.chevron_left));
      await tester.pumpAndSettle();
      expect(closeCount, 2, reason: '＜ 戻るタップで 2 回目発火');
    });
  });
}
