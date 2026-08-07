/// 【FEAT-289 → BUG-89 (2026-06-10)】メールアドレスをプライバシー配慮付きで
/// 表示するユーティリティ。
///
/// 表示画面（マイページのアカウント連携セクション等）で email をそのまま見せると、
/// 画面録画・スクショ・肩越しの覗き見で第三者にアドレスが漏れる懸念がある。
/// 一方、まったく非表示にすると「どのアカウントで連携しているか」がユーザー本人にも
/// 分からなくなって UX が悪化する。両者のバランスとして、**先頭 2 文字 + 固定 4 文字の
/// アスタリスク代替 + ドメイン**で表示する。
///
/// 例:
///   - `apple@icloud.com` → `ap****@icloud.com`
///   - `taro.yamada.99@gmail.com` → `ta****@gmail.com`
///   - `axxx@privaterelay.appleid.com` → `ax****@privaterelay.appleid.com`
///   - `a@example.com` → `a****@example.com`(1 文字フォールバック)
///   - `''` / `null` → `null`（呼び出し側で「-」等にフォールバック）
///
/// 設計判断:
///   - 先頭 2 文字を残すのは「自分のアドレスか他人のアドレスか」をユーザー本人が
///     判別しやすくするため（ユーザー要望 2026-06-10、1 文字だと識別性が低かった）。
///     2 文字でアドレス特定はほぼ不可能なので、プライバシー保護は実用上維持。
///   - アスタリスク数は元の長さに依存せず**固定 4 個**にする。
///     → 元の長さを推測されるサイドチャネル情報を消す（軽微だが意識する）。
///   - ドメインはそのまま出す。OAuth プロバイダー判別やサポート問い合わせ時に
///     ユーザー本人がアドレスを思い出すヒントになるため。
///   - local part が 1 文字以下の極稀ケースは取得できた分だけ表示
///     （例: `a@...` は `a****@...` で出す、無意味な穴埋めはしない）。
String? maskEmail(String? raw) {
  if (raw == null || raw.isEmpty) return null;

  final atIndex = raw.indexOf('@');
  // '@' がない / '@' が先頭 = 不正形式の email → そのまま返さず null
  // （上位で「-」表示にフォールバックさせる）
  if (atIndex <= 0) return null;

  final localPart = raw.substring(0, atIndex);
  final domain    = raw.substring(atIndex); // '@' 含む

  // 【BUG-89 (2026-06-10)】先頭 2 文字を残す。local part が 1 文字以下の極稀
  // ケースはそのまま表示（= 'a' + '****@...' = 'a****@...'）。
  final visibleChars =
      localPart.length >= 2 ? localPart.substring(0, 2) : localPart;
  return '$visibleChars****$domain';
}
