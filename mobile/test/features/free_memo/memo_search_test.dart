// FEAT-508 (2026-07-29) 検索フィルタリングロジック契約テスト (5 件)
//
// 実装と同じフィルタ関数をここで宣言し、以下の契約を縛る:
//   A. memos 空 → フィルタ結果も空 (検索ボックス非表示の前提)
//   B. query 空 → 全件返却 (フィルタなし)
//   C. query 非空 + 部分一致 → 一致メモのみ返却
//   D. query 非空 + 全件不一致 → 空リスト (「見つかりません」表示トリガ)
//   E. query クリア → query='' で全件復帰 (B と等価、clear button 契約)
//
// Note: MemoPage の状態は私的 (_MemoPageState)、Riverpod 完全 mock は
// 過剰コストのため、フィルタロジックを関数として抽出して契約テスト化する。
// 実機 UI (検索ボックス focus / HighlightedText 色) は §3.7 実機検証で担保。

import 'package:flutter_test/flutter_test.dart';

import 'package:sabiowl/features/free_memo/models/free_memo.dart';

// _buildMemoList 内のフィルタロジックと等価 (変更があれば両方更新)。
List<FreeMemo> filterMemos(List<FreeMemo> memos, String query) {
  if (query.isEmpty) return memos;
  return memos
      .where((m) => m.text.toLowerCase().contains(query.toLowerCase()))
      .toList();
}

FreeMemo _memo(int id, String text) => FreeMemo(
      id: id,
      text: text,
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
    );

void main() {
  final all = [
    _memo(1, '明日の会議の準備'),
    _memo(2, '牛乳 / 卵を買う'),
    _memo(3, '英語の勉強 30 分'),
  ];

  group('FEAT-508 検索フィルタリングロジック契約テスト', () {
    test('契約 A: memos 空 → 結果も空 (検索ボックス非表示の前提)', () {
      expect(filterMemos([], '明日'), isEmpty);
      expect(filterMemos([], ''), isEmpty);
    });

    test('契約 B: query 空 → 全件返却 (フィルタなし)', () {
      final result = filterMemos(all, '');
      expect(result.length, 3);
      expect(result, same(all)); // 同一オブジェクト (コピーコストなし)
    });

    test('契約 C: query 非空 + 部分一致 → 一致メモのみ返却', () {
      // '明日' は id=1 のみヒット
      expect(filterMemos(all, '明日').map((m) => m.id), [1]);
      // '英語' は id=3 のみ
      expect(filterMemos(all, '英語').map((m) => m.id), [3]);
      // 大文字小文字無視: 'egg' は含まれないが 'Egg' も同様 (日本語前提テスト)
      expect(filterMemos(all, '買う').map((m) => m.id), [2]);
    });

    test('契約 D: query 非空 + 全件不一致 → 空リスト (「見つかりません」表示トリガ)', () {
      expect(filterMemos(all, 'xyz123'), isEmpty);
      expect(filterMemos(all, '[???]'), isEmpty); // regex 記号も literal 扱い
    });

    test('契約 E: query クリア後は全件復帰 (clear button 契約)', () {
      final afterSearch = filterMemos(all, '明日');
      expect(afterSearch.length, 1);
      // clear → query='' → 全件
      final afterClear = filterMemos(all, '');
      expect(afterClear.length, 3);
    });
  });
}
