// 【FEAT-525 (2026-08-21)】並び替え UI の構造契約 (ソース走査)。
//
// ## Pre-mortem #6 —「ハンドルだけ増えて機能が付かない画面」の再発防止
//
// 本件の原因そのもの。UX-F08 が編集画面を作ったとき、ホーム画面から
// `Icons.drag_indicator` の見た目だけを流用し、`onReorder` を付けなかった。
// **飾りのハンドルは「壊れている」と読まれる** —— ユーザーからは未実装と
// 不具合の区別が付かない。
//
// そこで「ドラッグハンドルを描くなら、同じファイルに掴み先がある」ことを
// CI で縛る。新しい画面でハンドルだけ足した瞬間にここが赤くなる。
//
// 同 pattern: `category_strings_truth_test.dart` / `habit_increment_inflight_test.dart`。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// `Icons.drag_indicator` を描いている実装ファイルを列挙する。
List<File> _filesDrawingDragHandle() {
  final result = <File>[];
  for (final entity in Directory('lib').listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.dart')) continue;
    if (entity.path.endsWith('.g.dart')) continue;
    if (entity.readAsStringSync().contains('Icons.drag_indicator')) {
      result.add(entity);
    }
  }
  return result;
}

void main() {
  group('FEAT-525 Pre-mortem #6 — 飾りのドラッグハンドルを作らない', () {
    test('drag_indicator を描くファイルには必ず掴み先 (onReorder) がある', () {
      final files = _filesDrawingDragHandle();
      expect(files, isNotEmpty,
          reason: 'ハンドルを描くファイルが 1 つも無い = 走査が壊れている');

      final decorative = <String>[];
      for (final f in files) {
        final source = f.readAsStringSync();
        final hasReorder = source.contains('onReorder');
        final isHandleOnly = source.contains('ReorderableDragStartListener');
        // 自分で `onReorder` を持つか、親から渡される `leading` として
        // ハンドルだけを描くか (HabitCard 型) のどちらかであること。
        if (!hasReorder && !isHandleOnly) decorative.add(f.path);
      }

      expect(decorative, isEmpty,
          reason: 'ドラッグハンドルを描いているのに掴み先が無い '
              '(= 動かないハンドル。UX-F08 と同じ失敗): $decorative');
    });
  });

  group('FEAT-525 ネストしたスクロールの罠 (Pre-mortem #4)', () {
    // 編集 / 新規作成のどちらもフォーム全体が外側 `ListView` で縦スクロールする。
    // その中に `ReorderableListView` を置くので `shrinkWrap: true` +
    // `NeverScrollableScrollPhysics` が要る。忘れると
    // `Vertical viewport was given unbounded height` で画面が落ちる。
    const pages = [
      'lib/features/habits/pages/edit_habit_page.dart',
      'lib/features/habits/pages/add_habit_page.dart',
    ];

    for (final path in pages) {
      test('$path: shrinkWrap + NeverScrollableScrollPhysics', () {
        final source = File(path).readAsStringSync();
        expect(source, contains('ReorderableListView'));
        expect(source, contains('shrinkWrap: true'));
        expect(source, contains('NeverScrollableScrollPhysics'));
      });

      test('$path: ドラッグ起点はハンドルだけ (× ボタンを潰さない)', () {
        // 行全体を掴めるようにすると × が押しづらくなり、
        // リストのスクロールとも競合する (`home_body.dart` が同じ形)。
        final source = File(path).readAsStringSync();
        expect(source, contains('buildDefaultDragHandles: false'));
        expect(source, contains('ReorderableDragStartListener'));
      });
    }
  });

  group('FEAT-525 保存経路 — 旧フィールドを併送しない', () {
    test('edit_habit_page は set_checklist_items だけを送る', () {
      // 新形式と旧形式を同時に送ると backend が 400
      // (`habit_update_checklist_payload_conflict`) を返す。
      // 旧 2 フィールドは **公開中の v1.0.5 / 審査中の 1.1.0+6 のために
      // backend 側に残っている**だけで、新クライアントは使わない。
      final source =
          File('lib/features/habits/pages/edit_habit_page.dart').readAsStringSync();
      expect(source, contains("body['set_checklist_items']"));
      expect(source.contains("'add_checklist_items'"), isFalse);
      expect(source.contains("'delete_checklist_items'"), isFalse);
    });
  });
}
