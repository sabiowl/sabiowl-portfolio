// 【BUG-149 (2026-08-26)】出陣前シートのはみ出しに対する回帰テスト。
//
// 実機報告: **攻撃の薬・防御の薬を所持すると「BOTTOM OVERFLOWED BY 32 PIXELS」**。
//
// 原因は 3 つあった:
//
//   ① 下部セーフエリアの二重計上 —— `SafeArea(top: false)` が既に下部インセットを
//      入れているのに、`padding:` でも `MediaQuery.padding.bottom` を足していた。
//      `padding:` を評価している `context` は SafeArea より上なので生の値が取れる。
//      実測: シートが 678.6 → 746.6 (= +34 × 2) に膨らむ。**これが 32px の主因。**
//   ② 全体が非スクロールの `Column` —— 内容が画面を超えると下端が切れ、
//      **「出陣」ボタンが押せなくなる**（報告のスクリーンショットの黄黒ストライプが
//      まさに出陣ボタンの位置）。
//   ③ ラベル `Row` が横にも溢れる —— `Text(絵文字) + Text(長いラベル) + Spacer()` で
//      ラベルが `Flexible` に包まれていなかった。報告には無いが同じ画面の別の欠陥。
//
// 🔴 セクションは**所持状況で増減する**（advisory / 上位回復薬 / 攻撃の薬 / 防御の薬）。
// 「4 種すべて所持 + advisory あり」が最大構成で、そこだけを縛っても
// **次にセクションが 1 つ増えたときに黙って戻る**ので、
// 端末サイズ × 文字サイズの組み合わせで縛る。
//
// 実行方法:
// ```powershell
// cd mobile
// flutter test test/battle/battle_pre_start_sheet_layout_test.dart
// ```

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sabiowl/features/battle/models/enemy.dart';
import 'package:sabiowl/features/battle/widgets/battle_pre_start_sheet.dart';
import 'package:sabiowl/features/gamification/models/gamification_models.dart';
import 'package:sabiowl/features/gamification/providers/gamification_provider.dart';
import 'package:sabiowl/l10n/app_localizations.dart';

ShopItem _item(String id, int qty) => ShopItem.fromJson({
      'id': id,
      'name': id,
      'owned_quantity': qty,
    });

/// 実機報告と同じ相手（物理耐性あり + 撃破済 → advisory が出る = 最大構成）。
EnemyMaster _chimera() => EnemyMaster.fromJson({
      'key': 'chimera',
      'name': 'キメラ',
      'sprite_key': 'chimera',
      'physical_resistance': 0.5,
      'defeated': true,
    });

/// 4 種すべて所持 = セクションが最大まで並ぶ構成。
class _AllPotionsShop extends ShopNotifier {
  @override
  Future<ShopState> build() async => ShopState(coins: 0, items: [
        _item('recovery_potion', 1),
        _item('recovery_potion_plus', 3),
        _item('attack_potion', 1),
        _item('defense_potion', 1),
      ]);
}

/// 回復薬だけ = 修正前も収まっていた構成（退行の巻き添えが無いことの確認用）。
class _RecoveryOnlyShop extends ShopNotifier {
  @override
  Future<ShopState> build() async => ShopState(coins: 0, items: [
        _item('recovery_potion', 1),
      ]);
}

/// 端末サイズ × 文字サイズ × 下部セーフエリアを指定してシートを描く。
Future<List<String>> _pumpSheet(
  WidgetTester tester, {
  required Size size,
  required double textScale,
  double bottomInset = 34,
  ShopNotifier Function() shop = _AllPotionsShop.new,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  tester.view.padding = FakeViewPadding(bottom: bottomInset);
  tester.view.viewPadding = FakeViewPadding(bottom: bottomInset);
  addTearDown(tester.view.reset);

  final errors = <String>[];
  final prev = FlutterError.onError;
  FlutterError.onError = (d) => errors.add(d.exceptionAsString());

  await tester.pumpWidget(ProviderScope(
    overrides: [shopNotifierProvider.overrideWith(shop)],
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('ja'),
      builder: (c, w) => MediaQuery(
        data: MediaQuery.of(c).copyWith(
          textScaler: TextScaler.linear(textScale),
        ),
        child: w!,
      ),
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: BattlePreStartSheet(enemyName: 'キメラ', enemy: _chimera()),
        ),
      ),
    ),
  ));
  await tester.pump();
  FlutterError.onError = prev;

  return errors.where((e) => e.contains('overflowed')).toList();
}

void main() {
  // 実機報告の端末に近い 3 サイズ。iPhone SE 相当 (375x667) が最も厳しい。
  const sizes = <Size>[Size(432, 844), Size(390, 844), Size(375, 667)];
  // 標準 / アクセシビリティで拡大した状態。
  const scales = <double>[1.0, 1.15, 1.3];

  // ───────────────────────────────────────────────────────────────────────────
  // A: どの組み合わせでも溢れない
  // ───────────────────────────────────────────────────────────────────────────
  group('A: はみ出しゼロ (4 種すべて所持 + advisory)', () {
    for (final size in sizes) {
      for (final scale in scales) {
        final label =
            '${size.width.toInt()}x${size.height.toInt()} / 文字 ${scale}x';
        testWidgets('A: $label で overflow が出ない', (tester) async {
          final overflows = await _pumpSheet(
            tester,
            size: size,
            textScale: scale,
          );
          expect(
            overflows,
            isEmpty,
            reason: '🔴 $label —— 修正前の実測値:\n'
                '  375x667 標準: 下 80px / 文字 1.3x: 下 178px\n'
                '  390x844 標準: 右 46px / 文字 1.3x: 右 163px\n'
                'セクションを足したり長いラベルを追加したりすると再発する',
          );
        });
      }
    }
  });

  // ───────────────────────────────────────────────────────────────────────────
  // B: 出陣ボタンが必ず画面内にある（これが本当に守りたいこと）
  // ───────────────────────────────────────────────────────────────────────────
  group('B: 出陣ボタンは常に押せる', () {
    for (final size in sizes) {
      for (final scale in scales) {
        final label =
            '${size.width.toInt()}x${size.height.toInt()} / 文字 ${scale}x';
        testWidgets('B: $label で出陣ボタンが画面内に収まっている', (tester) async {
          await _pumpSheet(tester, size: size, textScale: scale);

          // `ElevatedButton.icon` は `_ElevatedButtonWithIcon` を返すので、
          // `find.byType` (完全一致) では見つからない。
          final button = find.byWidgetPredicate((w) => w is ElevatedButton);
          expect(button, findsOneWidget, reason: '出陣ボタンが見つからない');

          final rect = tester.getRect(button);
          expect(
            rect.bottom,
            lessThanOrEqualTo(size.height),
            reason: '🔴 $label —— 出陣ボタンが画面外に押し出されている。'
                'はみ出しの見た目ではなく **押せないこと** が実害である',
          );
          expect(rect.top, greaterThanOrEqualTo(0.0));
        });
      }
    }
  });

  // ───────────────────────────────────────────────────────────────────────────
  // C: 二重計上の再発防止（①の直接の縛り）
  // ───────────────────────────────────────────────────────────────────────────
  group('C: 下部セーフエリアを二重に数えない', () {
    testWidgets('C-1: セーフエリアが増えても、増える高さはその 1 倍だけ',
        (tester) async {
      await _pumpSheet(tester,
          size: const Size(432, 844), textScale: 1.0, bottomInset: 0);
      final without = tester.getSize(find.byType(BattlePreStartSheet)).height;

      await _pumpSheet(tester,
          size: const Size(432, 844), textScale: 1.0, bottomInset: 34);
      final with34 = tester.getSize(find.byType(BattlePreStartSheet)).height;

      expect(
        with34 - without,
        closeTo(34, 1.0),
        reason: '🔴 差が 68 (= 34 × 2) になったら二重計上が戻っている。\n'
            '`padding:` を評価する context は `SafeArea` より上なので、'
            'そこで `MediaQuery.padding.bottom` を足すと SafeArea と重複する',
      );
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // D: 収まる構成では従来どおり（スクロールを足したことの巻き添えが無い）
  // ───────────────────────────────────────────────────────────────────────────
  group('D: 収まる構成では見た目が変わらない', () {
    testWidgets('D-1: 回復薬だけならシートは内容ぶんの高さで止まる',
        (tester) async {
      await _pumpSheet(
        tester,
        size: const Size(432, 844),
        textScale: 1.0,
        shop: _RecoveryOnlyShop.new,
      );

      final height = tester.getSize(find.byType(BattlePreStartSheet)).height;
      expect(
        height,
        lessThan(844 * 0.9),
        reason: '🔴 `Flexible` を `Expanded` にすると、内容が短くても'
            '常に上限まで伸びてシートが画面の 9 割を占める',
      );
    });
  });
}
