// 【2026-07-02】フレンド ID のフォーマット helper。
//
// Backend の `PlayerProfile.friend_id` は 2026-07-02 に 8 → 12 桁化された。
// - 12 桁の新形式: 「0000-0000-0000」(4-4-4 区切り) で表示
// - 8 桁の旧形式:  「0000-0000」(4-4 区切り) で後方互換維持
// - それ以外の長さ: そのまま表示 (safe fallback、想定外の入力に潰されない)
//
// 検索やクリップボードコピーには [stripFriendIdSeparators] を使い、
// 常に `-` なしの raw 数字文字列を扱う。Backend の `FriendSearchView` は
// 受信 friend_id から `-` を除去する後方互換を持つが、Mobile 側でも入力を
// clean にしてから送る二重防御を採る。

/// 表示用フォーマット。`-` を除去してから長さで判定して区切りを挿入する
/// (入力が既に `-` 入りでも正規化される)。
String formatFriendId(String friendId) {
  final digits = friendId.replaceAll('-', '');
  if (digits.length == 12) {
    return '${digits.substring(0, 4)}-'
        '${digits.substring(4, 8)}-'
        '${digits.substring(8, 12)}';
  }
  if (digits.length == 8) {
    return '${digits.substring(0, 4)}-${digits.substring(4, 8)}';
  }
  return friendId;
}

/// 検索・コピー用: `-` を除去した raw 数字。
/// Backend API 送信 / Clipboard.setData で使う (常に区切りなし)。
String stripFriendIdSeparators(String friendId) {
  return friendId.replaceAll('-', '');
}
