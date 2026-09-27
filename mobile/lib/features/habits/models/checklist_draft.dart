/// 【FEAT-525 (2026-08-21)】チェックリスト項目の「下書き」表現。
///
/// 編集画面は **既存項目 (id 付き)** と **未保存の新規項目 (id 未確定)** を
/// 区別せず **1 本のリスト**として表示する。ユーザーは両者を混ぜて並べ替えるので、
/// 「既存 / 追加 / 削除」の 3 状態を別々に持つと順序が表現できない。
///
/// 保存時は `buildSetChecklistItemsPayload()` でそのまま
/// `PATCH /api/habits/<pk>/` の `set_checklist_items` に写す。
class ChecklistDraft {
  ChecklistDraft({this.id, required this.text}) : localKey = _nextLocalKey++;

  /// `ReorderableListView` の `Key` に使う一意値。
  ///
  /// **`text` や index を Key にしてはいけない。** text は重複しうる
  /// (「牛乳」を 2 行書く買い物メモ)、index は並び替えのたびに意味が変わる。
  /// どちらも Flutter が行を取り違えて、掴んだのと違う項目が動く。
  final int localKey;
  static int _nextLocalKey = 0;

  /// `null` = まだ保存されていない新規項目。
  final int? id;
  final String text;

  /// `set_checklist_items` の 1 要素。
  ///
  /// **id は「無いときは送らない」**。`{'id': null}` を送ると backend 側で
  /// 「id フィールドがある」と読めてしまう形になるため、キーごと落とす。
  Map<String, dynamic> toJson() =>
      id == null ? {'text': text} : {'id': id, 'text': text};
}

/// `ReorderableListView.onReorder` の index 補正を 1 箇所に閉じ込める。
///
/// `newIndex` は「移動前のリストにおける挿入位置」で渡ってくるため、
/// 下方向へ動かしたときは 1 引かないと 1 つずれる。**この -1 を忘れる**のが
/// 並び替え実装で最も多い間違いなので、両画面でこの関数を共有する。
List<ChecklistDraft> reorderDrafts(
  List<ChecklistDraft> drafts,
  int oldIndex,
  int newIndex,
) {
  final next = [...drafts];
  if (newIndex > oldIndex) newIndex--;
  final moved = next.removeAt(oldIndex);
  next.insert(newIndex, moved);
  return next;
}

/// 保存 body の `set_checklist_items` を **表示順どおり**に組む。
List<Map<String, dynamic>> buildSetChecklistItemsPayload(
  List<ChecklistDraft> drafts,
) =>
    drafts.map((d) => d.toJson()).toList(growable: false);
