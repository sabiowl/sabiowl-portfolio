import '../../../l10n/app_localizations.dart';

/// 【FEAT-295 Phase 1a】3 作戦定義（MVP ハードコード、設計ノート §5.2）。
///
/// 作戦のカスタマイズ（ユーザーがアビリティ組合せ）は Phase 2 で導入予定。
///
/// 【2026-07-02】必殺技の自動発動を offense に移動、conserveUltimate は
/// 手動発動のみ許可する仕様に変更 (label 意味への忠実化):
///   - offense (攻撃重視)  = 攻撃全開: canUltimate なら ultimate 自動発動、
///                           それ以外は 50% normal / 50% strong
///   - conserveUltimate (大技温存) = 温存: 自動発動はしない、手動必殺ボタン
///                                    (queueUltimate) 発動のみ許可
/// 手動発動経路 (queueUltimate) は Tactic 非依存で常に動作するため、
/// conserveUltimate でも手動必殺ボタンを押せば発動する。
enum Tactic {
  /// 攻撃重視: canUltimate → ultimate 自動発動、それ以外 50% 通常 / 50% 強攻撃。
  offense,

  /// 回復重視: HP < 30% で heal、< 50% で strong、それ以外 normal。
  recovery,

  /// 大技温存: 自動発動なし。手動必殺ボタン (queueUltimate) 経由でのみ発動。
  /// chargedSpecialCount は通常攻撃で貯まり続けるが、resolver からは常に normal を返す。
  conserveUltimate;

  // 【FEAT-489 Phase 2F-a】旧 `get label` (日本語 hardcode) を削除。
  // 全呼び出し元が下の localizedLabel(l10n) に移行済で参照 0 件だった。

  String localizedLabel(AppLocalizations l10n) => switch (this) {
        Tactic.offense           => l10n.battleTacticOffense,
        Tactic.recovery          => l10n.battleTacticRecovery,
        Tactic.conserveUltimate  => l10n.battleTacticConserveUltimate,
      };
}
