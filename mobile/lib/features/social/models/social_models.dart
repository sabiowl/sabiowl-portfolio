// ── Social Models ──────────────────────────────────────────────────────────

import '../../gamification/models/gamification_models.dart'
    show CharacterStat;  // 【2026-06-27】フレンドプロフィール ステータスカード表示用

class FriendPlayer {
  final int id;
  final String name;
  final int level;
  final String friendId;
  final String? title;
  // 【BUG-100 (2026-06-14)】設定キャラ画像表示用。Backend FriendPlayerSerializer の
  // active_character サブオブジェクト (key / name / image_path のみ) から読み取る。
  // CharacterAsset.circleWidget(identifier=imagePath, keyFallback=key) で描画。
  final String? activeCharacterKey;
  final String? activeCharacterImagePath;
  // 【2026-06-27】6 ステータス (運動 / 学習 / 健康 / 精神 / 創造 / 貢献)。
  // Backend FriendPlayerSerializer.get_stats から取得 (空配列 = 旧 endpoint からの
  // フォールバック、検索 / リスト時など stats を返さない経路にも互換)。
  final List<CharacterStat> stats;

  const FriendPlayer({
    required this.id,
    required this.name,
    required this.level,
    required this.friendId,
    this.title,
    this.activeCharacterKey,
    this.activeCharacterImagePath,
    this.stats = const [],
  });

  factory FriendPlayer.fromJson(Map<String, dynamic> j) {
    final char = j['active_character'] as Map<String, dynamic>?;
    final rawStats = j['stats'] as List<dynamic>?;
    return FriendPlayer(
      id: j['id'] as int? ?? 0,
      name: j['name'] as String? ?? '',
      level: j['level'] as int? ?? 1,
      friendId: j['friend_id'] as String? ?? '',
      title: j['title'] as String?,
      activeCharacterKey: char?['key'] as String?,
      activeCharacterImagePath: char?['image_path'] as String?,
      stats: rawStats == null
          ? const []
          : rawStats
              .map((e) => CharacterStat.fromJson(e as Map<String, dynamic>))
              .toList(),
    );
  }
}

class FriendEntry {
  final int friendshipId;
  final FriendPlayer player;

  const FriendEntry({required this.friendshipId, required this.player});

  factory FriendEntry.fromJson(Map<String, dynamic> j) => FriendEntry(
        friendshipId: j['friendship_id'] as int? ?? 0,
        player: FriendPlayer.fromJson(j['player'] as Map<String, dynamic>),
      );
}

class SentRequest {
  final int id;
  final FriendPlayer toPlayer;
  final String createdAt;

  const SentRequest({
    required this.id,
    required this.toPlayer,
    required this.createdAt,
  });

  /// 【BUG-114 (2026-06-14)】Backend FriendListView.sent_data は
  /// `{friendship_id, player}` を返す (BUG-100 と同パターンの schema 不整合)。
  /// 旧実装は `j['to_player']` を期待しており null キャストで TypeError →
  /// friendListProvider.error → 画面下部の赤テキスト「うまくいきませんでした」
  /// 表示の真因。Backend response の実形に揃える (`id` には friendship_id を
  /// 使い、`createdAt` は Backend が返さないため空文字フォールバック、UI 未参照)。
  factory SentRequest.fromJson(Map<String, dynamic> j) => SentRequest(
        id: j['friendship_id'] as int? ?? 0,
        toPlayer:
            FriendPlayer.fromJson(j['player'] as Map<String, dynamic>),
        createdAt: j['created_at'] as String? ?? '',
      );
}

class IncomingRequest {
  final int id;
  final FriendPlayer fromPlayer;
  final String createdAt;

  const IncomingRequest({
    required this.id,
    required this.fromPlayer,
    required this.createdAt,
  });

  /// 【BUG-114 (2026-06-14)】Backend FriendRequestView.get は
  /// `{id, player, created_at}` を返す。旧実装は `j['from_player']` を
  /// 期待しており null キャストで TypeError (潜在バグ、incoming pending を
  /// 持つユーザーで顕在化)。Backend response の実形 `player` に揃える。
  factory IncomingRequest.fromJson(Map<String, dynamic> j) => IncomingRequest(
        id: j['id'] as int? ?? 0,
        fromPlayer:
            FriendPlayer.fromJson(j['player'] as Map<String, dynamic>),
        createdAt: j['created_at'] as String? ?? '',
      );
}

class FriendListData {
  final List<FriendEntry> friends;
  final List<SentRequest> sentRequests;

  const FriendListData({required this.friends, required this.sentRequests});

  factory FriendListData.fromJson(Map<String, dynamic> j) => FriendListData(
        friends: (j['friends'] as List<dynamic>? ?? [])
            .map((e) => FriendEntry.fromJson(e as Map<String, dynamic>))
            .toList(),
        sentRequests: (j['sent_requests'] as List<dynamic>? ?? [])
            .map((e) => SentRequest.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

/// relation: 'none' | 'friend' | 'sent' | 'received' | 'self'
class SearchResult {
  final FriendPlayer player;
  final String relation;

  const SearchResult({required this.player, required this.relation});

  /// 【BUG-100 (2026-06-14)】Backend (`FriendSearchView`) はフラット構造で返す:
  /// `{id, name, level, friend_id, relation, relation_from_me, ...}`。
  /// 旧実装は `j['player']` を期待して nested を読みにいき、null キャストで
  /// TypeError → catch → 「見つかりませんでした」と誤表示していた (200 OK でも)。
  /// `j` 自体を FriendPlayer.fromJson に渡す形に修正。
  factory SearchResult.fromJson(Map<String, dynamic> j) => SearchResult(
        player: FriendPlayer.fromJson(j),
        relation: j['relation'] as String? ?? 'none',
      );
}

// 【FEAT-446 (2026-06-20)】AppMessage / MessageThread クラス削除:
// フレンド間メッセージ機能廃止 (トラブル / 悪用未然防止) に伴う dead model 撤去。

// ── Notifications ───────────────────────────────────────────────────────────

class AppNotification {
  final int id;
  final String notifType;
  final String title;
  final String body;
  final int? relatedId;
  final bool isRead;
  final String createdAt;

  const AppNotification({
    required this.id,
    required this.notifType,
    required this.title,
    required this.body,
    this.relatedId,
    required this.isRead,
    required this.createdAt,
  });

  factory AppNotification.fromJson(Map<String, dynamic> j) => AppNotification(
        id: j['id'] as int? ?? 0,
        notifType: j['notif_type'] as String? ?? '',
        title: j['title'] as String? ?? '',
        body: j['body'] as String? ?? '',
        relatedId: j['related_id'] as int?,
        isRead: j['is_read'] as bool? ?? false,
        createdAt: j['created_at'] as String? ?? '',
      );

  AppNotification copyWith({bool? isRead}) => AppNotification(
        id: id,
        notifType: notifType,
        title: title,
        body: body,
        relatedId: relatedId,
        isRead: isRead ?? this.isRead,
        createdAt: createdAt,
      );
}

// ── Friend Profile ──────────────────────────────────────────────────────────

/// 【FEAT-447 (2026-06-20)】Backend `FriendProfileView.get` のフラット response
/// 形に揃えるよう書き換え。
///
/// 旧実装はネスト形 `{player: {...}, current_streak, total_habits, completion_rate}`
/// を期待していたが、Backend は `FriendPlayerSerializer(target).data + friendship_id`
/// をフラットで返す (BUG-100 以降の実装形)。`j['player']` 不在で TypeError →
/// AsyncError → 画面「プロフィールを表示できません」エラー表示に陥っていた。
///
/// 【FEAT-396 (2026-05-31) privacy 整合】
/// - `monthly_rate` (Backend) は常時 0、`public_habits` は常時 [] 固定。
///   → Mobile UI からも「達成率」「習慣数」表示は撤去 (friend_profile_page.dart)
/// - `best_streak` のみフレンド機能のモチベーション源として公開維持 →
///   `currentStreak` として読み取り表示
class FriendProfile {
  final FriendPlayer player;
  final int currentStreak;
  /// 【2026-07-02】今日このフレンドに XP ブーストを既に贈ったか。
  /// Backend `FriendProfileView.get` が per-friend/day の Gift 存在チェックで
  /// 判定した値。UI の「XP ブーストを贈る」ボタン非活性化の根拠。
  /// 旧 Backend (フィールド未返却) 経路の互換 fallback は false。
  final bool hasGiftedToday;

  const FriendProfile({
    required this.player,
    required this.currentStreak,
    required this.hasGiftedToday,
  });

  /// Backend のフラット JSON を直接 FriendPlayer + best_streak として読む。
  /// j 自体が FriendPlayer.fromJson が受け取る形と整合する (id/name/level/
  /// friend_id/title/active_character 等)。
  factory FriendProfile.fromJson(Map<String, dynamic> j) => FriendProfile(
        player: FriendPlayer.fromJson(j),
        currentStreak: j['best_streak'] as int? ?? 0,
        hasGiftedToday: j['has_gifted_today'] as bool? ?? false,
      );
}

// ── Friend Gift Popup Candidate (FEAT-452) ──────────────────────────────

/// 【FEAT-452 (2026-06-20)】フレンドプレゼント popup 候補。
///
/// Backend `check_friend_gift_popup_trigger` が当日 3 回目のタスク達成 +
/// 対象フレンドあり時のみ返却。Mobile はこれを受け取って確認ダイアログを表示し、
/// User が「贈る」を押せば既存 `sendGift(id)` を呼ぶ (FEAT-451 経路再利用)。
class FriendGiftCandidate {
  final int id;
  final String name;
  final int level;
  final String friendId;
  final String? activeCharacterImagePath;
  final String? activeCharacterKey;

  const FriendGiftCandidate({
    required this.id,
    required this.name,
    required this.level,
    required this.friendId,
    this.activeCharacterImagePath,
    this.activeCharacterKey,
  });

  factory FriendGiftCandidate.fromJson(Map<String, dynamic> j) =>
      FriendGiftCandidate(
        id: j['id'] as int? ?? 0,
        name: j['name'] as String? ?? '',
        level: j['level'] as int? ?? 1,
        friendId: j['friend_id'] as String? ?? '',
        activeCharacterImagePath:
            j['active_character_image_path'] as String?,
        activeCharacterKey: j['active_character_key'] as String?,
      );
}
