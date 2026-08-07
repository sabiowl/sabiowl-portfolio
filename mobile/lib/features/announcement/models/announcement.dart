/// 【FEAT-458 (2026-06-21)】お知らせモデル。
///
/// Backend `Announcement` (全ユーザー共通) + `PlayerAnnouncementRead` (per-user
/// 既読管理) を combined した形で Mobile に届く:
///   GET /api/announcements/unread/ → 未読 1 件 or null
///   GET /api/announcements/        → 全件 + 各々 is_read フラグ
///   POST /api/announcements/<id>/read/ → 既読化
///
/// 【2026-06-27】新キャラ追加機能 (Gemini 要件):
///   - `linkCharacter` を nested 軽量 dict (`AnnouncementLinkCharacter`) として保持
///   - 設定時のみ popup に「詳細を見る」ボタンを表示、tap でキャラ詳細シート展開
class Announcement {
  final int id;
  final String title;
  final String body;
  final DateTime publishedAt;
  /// list 経路 (GET /announcements/) でのみ意味あり。unread 経路では常に false。
  final bool isRead;
  /// 【2026-06-27】お知らせから新キャラ詳細への動線。null = 通常お知らせ。
  /// Backend `Announcement.link_character` (FK) から軽量 dict として届く
  /// (id / key / name / image_path / tagline のみ)。
  final AnnouncementLinkCharacter? linkCharacter;
  /// 【2026-06-27】お知らせ画像 URL (任意)。null = 画像なし。
  /// Backend `Announcement.image` (ImageField) から request.build_absolute_uri で
  /// 生成された絶対 URL が届く。Mobile popup / 履歴で本文上に大きく表示。
  /// 旧 Backend (image 未対応) では null fallback。
  final String? imageUrl;

  const Announcement({
    required this.id,
    required this.title,
    required this.body,
    required this.publishedAt,
    this.isRead = false,
    this.linkCharacter,
    this.imageUrl,
  });

  factory Announcement.fromJson(Map<String, dynamic> j) {
    final linkJson = j['link_character'] as Map<String, dynamic>?;
    return Announcement(
      id:          j['id'] as int? ?? 0,
      title:       j['title'] as String? ?? '',
      body:        j['body'] as String? ?? '',
      publishedAt: DateTime.tryParse(j['published_at'] as String? ?? '')
          ?.toLocal() ??
          DateTime.now(),
      isRead:      j['is_read'] as bool? ?? false,
      linkCharacter:
          linkJson == null ? null : AnnouncementLinkCharacter.fromJson(linkJson),
      imageUrl:    j['image_url'] as String?,
    );
  }
}

/// 【2026-06-27】Announcement.link_character の Mobile 表現 (軽量最小集合)。
///
/// 完全な Character (job / price / owned 等) は取得せず、popup の遷移先判定 +
/// プレビュー描画に必要な最小フィールドのみ Backend から受け取る。詳細表示
/// 自体は既存 `charactersNotifierProvider` から完全な Character を引いて
/// `_CharacterDetailSheet` を開く構成 (詳細ロジック重複を避ける)。
class AnnouncementLinkCharacter {
  final int id;
  final String key;
  final String name;
  final String imagePath;
  final String tagline;

  const AnnouncementLinkCharacter({
    required this.id,
    required this.key,
    required this.name,
    required this.imagePath,
    required this.tagline,
  });

  factory AnnouncementLinkCharacter.fromJson(Map<String, dynamic> j) =>
      AnnouncementLinkCharacter(
        id:        j['id'] as int? ?? 0,
        key:       j['key'] as String? ?? '',
        name:      j['name'] as String? ?? '',
        imagePath: j['image_path'] as String? ?? '',
        tagline:   j['tagline'] as String? ?? '',
      );
}
