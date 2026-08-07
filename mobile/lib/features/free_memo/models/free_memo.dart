// 【FEAT-493 (2026-07-25)】フリーメモ機能 — FreeMemo モデル。
// plain class + fromJson パターン (Habit / ChallengeEntry 等と同方針)。
//
// 【FEAT-502 (2026-07-26)】archivedAt → deletedAt に rename。
// Backend で archived_at (auto archive 用) と deleted_at (user 削除) を意味分離した
// のに合わせ、本 model は user 削除 (soft delete / trash) を表す deletedAt のみを持つ。
// auto archive は将来 (cron 復活時) の別 field で、v1.0.4 の Flutter には露出しない。

class FreeMemo {
  final int id;
  final String text;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? deletedAt;
  final String? aiSuggestedType;

  const FreeMemo({
    required this.id,
    required this.text,
    required this.createdAt,
    required this.updatedAt,
    this.deletedAt,
    this.aiSuggestedType,
  });

  factory FreeMemo.fromJson(Map<String, dynamic> j) => FreeMemo(
        id: j['id'] as int,
        text: j['text'] as String? ?? '',
        createdAt: DateTime.parse(j['created_at'] as String),
        updatedAt: DateTime.parse(j['updated_at'] as String),
        deletedAt: j['deleted_at'] == null
            ? null
            : DateTime.parse(j['deleted_at'] as String),
        aiSuggestedType: j['ai_suggested_type'] as String?,
      );

  bool get isDeleted => deletedAt != null;
}
