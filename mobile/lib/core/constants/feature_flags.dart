/// 【FEAT-373 (2026-05-29)】v1.0 で Google Calendar push (Sabiowl → Google) 機能を
/// 構造的に廃止するため feature flag を 1 箇所に集約。
///
/// ## 採用方針 (ユーザー判断 2026-05-29)
/// - ❌ Sabiowl で追加した予定は Google Calendar に反映されない (push 機能停止)
/// - ✅ Google Calendar で追加した予定は Sabiowl の同期ボタンで取り込み可能 (sync 維持)
///
/// = 片方向同期 (Google → Sabiowl のみ) への戦略的後退。
///
/// ## 廃止理由
/// 1. BUG-74 系の「設定無視で push されるバグ」が構造的再発リスクを持つ
/// 2. プライバシーリスクの構造解消 (push しないなら漏洩リスクなし)
/// 3. Sabiowl コアループ (習慣管理 + RPG) への集中
/// 4. 「サビ = 静かな聖域」哲学整合 (補助機能でユーザー不満を出さない)
///
/// ## v1.1+ 復元手順
/// 1. `gcalPushEnabled = true` に変更
/// 2. 5 push 経路の flag gate は削除せず維持 (コメント書き換えのみ)
/// 3. `backend/api/views/timeline.py:_initial_pending_google_push` を git history から復元
/// 4. Settings UI トグルを git history から復元
/// 5. 新規 migration 0XXX で全 user の gcal_push_enabled をリセット
/// 6. 法務文書を再更新
/// 詳細: FEAT-373 指示書 §9 参照
class FeatureFlags {
  FeatureFlags._();

  /// 【FEAT-373】Google Calendar push (Sabiowl → Google) の有効フラグ。
  ///
  /// v1.0 では `false` 固定。
  /// 5 push 経路すべてが `if (!FeatureFlags.gcalPushEnabled) return;` で gate される。
  static const bool gcalPushEnabled = false;
}
