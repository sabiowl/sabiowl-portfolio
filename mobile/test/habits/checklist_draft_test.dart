// 【FEAT-525 (2026-08-21)】チェックリスト並び替えの下書きモデル単体テスト。
//
// 並び替えロジックそのもの (index 補正) と、保存 body の組み立てを縛る。
// 画面を通した検証は `checklist_reorder_page_test.dart` (widget test)、
// 構造の縛りは `checklist_reorder_contract_test.dart` (ソース走査) が担当する。

import 'package:flutter_test/flutter_test.dart';
import 'package:sabiowl/features/habits/models/checklist_draft.dart';

void main() {
  group('FEAT-525 reorderDrafts — onReorder の index 補正', () {
    List<ChecklistDraft> seed() => [
          ChecklistDraft(id: 1, text: 'A'),
          ChecklistDraft(id: 2, text: 'B'),
          ChecklistDraft(id: 3, text: 'C'),
        ];

    test('下方向へ動かす: newIndex が 1 減る (この -1 を忘れるのが定番の間違い)', () {
      // A を C の後ろへ = ReorderableListView は (old=0, new=3) で通知する
      final result = reorderDrafts(seed(), 0, 3);
      expect(result.map((d) => d.text).toList(), ['B', 'C', 'A']);
    });

    test('上方向へ動かす: newIndex はそのまま', () {
      final result = reorderDrafts(seed(), 2, 0);
      expect(result.map((d) => d.text).toList(), ['C', 'A', 'B']);
    });

    test('隣へ 1 つ動かす', () {
      expect(reorderDrafts(seed(), 0, 2).map((d) => d.text).toList(),
          ['B', 'A', 'C']);
    });

    test('元のリストは書き換えない (setState で新しい参照を渡す)', () {
      final original = seed();
      final result = reorderDrafts(original, 0, 3);
      expect(original.map((d) => d.text).toList(), ['A', 'B', 'C']);
      expect(identical(original, result), isFalse);
    });

    test('id を持たない新規項目も同じように動かせる', () {
      final drafts = [
        ChecklistDraft(id: 1, text: '既存'),
        ChecklistDraft(text: '新規'),
      ];
      final result = reorderDrafts(drafts, 1, 0);
      expect(result.first.text, '新規');
      expect(result.first.id, isNull);
    });
  });

  group('FEAT-525 buildSetChecklistItemsPayload — 保存 body', () {
    test('表示順どおりに並ぶ', () {
      final payload = buildSetChecklistItemsPayload([
        ChecklistDraft(id: 3, text: 'C'),
        ChecklistDraft(id: 1, text: 'A'),
      ]);
      expect(payload, [
        {'id': 3, 'text': 'C'},
        {'id': 1, 'text': 'A'},
      ]);
    });

    test('新規項目は id キーごと落とす (null を送らない)', () {
      final payload = buildSetChecklistItemsPayload([ChecklistDraft(text: '新規')]);
      expect(payload, [
        {'text': '新規'},
      ]);
      expect(payload.first.containsKey('id'), isFalse);
    });

    test('空リストは空配列 (= 全削除の宣言)', () {
      expect(buildSetChecklistItemsPayload([]), isEmpty);
    });
  });

  group('FEAT-525 localKey — 重複 text でも一意', () {
    test('同じ text の draft でも localKey は異なる', () {
      final a = ChecklistDraft(text: '牛乳');
      final b = ChecklistDraft(text: '牛乳');
      expect(a.localKey, isNot(b.localKey),
          reason: 'text を Key にすると買い物メモで行を取り違える');
    });

    test('id が同じでも別インスタンスなら localKey は異なる', () {
      expect(ChecklistDraft(id: 1, text: 'A').localKey,
          isNot(ChecklistDraft(id: 1, text: 'A').localKey));
    });
  });
}
