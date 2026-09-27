// 【2026-08-11】ステータスの「正式名」と「短縮名」が同じものを指すと読めることを縛る。
//
// ## なぜ必要か (実際に起きたこと)
//
// ステータス画面には同じステータスが 2 つの語彙で出る:
//
//   一覧 / 6 角形チャート … 短縮名 (`StatHexagonChart.labelFor`)
//   ステータスカードの見出し … 正式名 (`StatHexagonChart.fullNameFor`)
//
// 日本語は「運動」と「運動力」で **語幹が同じ**なので、読み手は同一ステータスだと
// 分かる。ところが英語版は
//
//   Exercise / **Physical**   Study / **Intellect**
//   Health   / **Vitality**   Mental / **Spirit**
//
// と **共通部分がゼロ**で、1 枚の画面に 2 つの別ステータスがあるように見えていた
// (英語スクリーンショットのレビューで検出)。しかも `Physical` カードの中には
// `EXP +40% for "Exercise" habits` と書かれており、3 つ目の語彙が混ざっていた。
//
// 英語には「力」を足す語形が無いため、無理に別語を当てたのが原因。
//
// ## 何を縛るか
//
// 「en では正式名 == 短縮名」と書くと、`Creativity` / `Creative` のように
// **語幹を共有していれば読み手に伝わる**ケースまで弾いてしまう。そこで
//
//     正式名は短縮名で始まる (fullName.startsWith(shortLabel))
//
// を不変条件にする。ja / en の両方でこれが成り立つ:
//
//     運動力.startsWith(運動) ✓      Exercise.startsWith(Exercise) ✓
//     創造力.startsWith(創造) ✓      Creativity.startsWith(Creative) ✓
//
// 言語に依存しない形なので、3 言語目を足したときも同じ規律が効く。
//
// 実行方法:
// ```powershell
// cd mobile; flutter test test/gamification/stat_name_consistency_test.dart
// ```
import 'package:flutter_test/flutter_test.dart';
import 'package:sabiowl/features/gamification/widgets/stat_hexagon_chart.dart';
import 'package:sabiowl/l10n/app_localizations.dart';

/// Backend の `CharacterStat.name` (真実値は日本語)。
const _statNames = <String>[
  '運動力', '学習力', '健康力', '精神力', '創造力', '貢献力',
];

void main() {
  for (final locale in AppLocalizations.supportedLocales) {
    group('ステータス名の一貫性 (${locale.languageCode})', () {
      late AppLocalizations l10n;

      setUp(() async {
        l10n = await AppLocalizations.delegate.load(locale);
      });

      test('正式名は短縮名で始まる (同一ステータスだと読める)', () {
        for (final name in _statNames) {
          final short = StatHexagonChart.labelFor(l10n, name);
          final full = StatHexagonChart.fullNameFor(l10n, name);

          expect(
            full.startsWith(short), isTrue,
            reason: '"$name" の正式名 "$full" が短縮名 "$short" で始まっていない。'
                '同じ画面に一覧 (短縮名) とカード見出し (正式名) が並ぶため、'
                '語幹を共有していないと別ステータスに見える',
          );
        }
      });

      test('6 ステータスの短縮名がすべて異なる', () {
        final shorts = {
          for (final n in _statNames) StatHexagonChart.labelFor(l10n, n),
        };
        expect(shorts.length, _statNames.length,
            reason: '短縮名が重複している: $shorts');
      });

      test('6 ステータスの正式名がすべて異なる', () {
        final fulls = {
          for (final n in _statNames) StatHexagonChart.fullNameFor(l10n, n),
        };
        expect(fulls.length, _statNames.length,
            reason: '正式名が重複している: $fulls');
      });

      test('未知のステータス名はそのまま返す (Backend が値を増やしても落ちない)', () {
        expect(StatHexagonChart.labelFor(l10n, '未知力'), '未知力');
        expect(StatHexagonChart.fullNameFor(l10n, '未知力'), '未知力');
      });
    });
  }
}
