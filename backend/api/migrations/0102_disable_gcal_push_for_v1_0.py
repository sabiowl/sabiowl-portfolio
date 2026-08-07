"""【FEAT-373 (2026-05-29)】v1.0 で Google Calendar push 機能廃止に伴う
全 PlayerProfile.gcal_push_enabled=False + 全 TimelineEvent.pending_google_push=False
一括 reconcile (1 回限り cleanup)。

【採用方針】
v1.0 で Google Calendar push (Sabiowl → Google) 機能を構造的に廃止する。
片方向同期 (Google → Sabiowl のみ) への戦略的後退。理由:
1. BUG-74 系の「設定無視で push されるバグ」が構造的再発リスクを持つ
2. プライバシーリスクの構造解消 (push しないなら漏洩リスクなし)
3. Sabiowl コアループ (習慣管理 + RPG) への集中

【CLAUDE.md「破壊的データマイグレーション禁止」原則の 1 回限り例外承認】
FEAT-370 hotfix (migration 0100) + FEAT-372 (migration 0101) と同パターン:
  1. ホスティングプラン Shell 不可: Render Free プランは Shell アクセスを提供しない
  2. 明確に意図された 1 回限り cleanup: v1.0 リリースに向けた push 機能廃止の
     DB 状態正規化であり、再現性のあるテスト DB では no-op またはクリーンな状態
  3. chicken-and-egg 構造 (部分的に該当): Flutter / Backend 修正と同 deploy で
     DB 状態を正規化することが確実な廃止保証に不可欠

承認時の 3 経路記録:
- ✅ 本ファイル冒頭 docstring に「1 回限り例外承認」を明記
- ✅ commit message に「CLAUDE.md 原則の 1 回限り例外」を明示
- ✅ management command 等の並行維持は不要 (本 migration が唯一の正規化経路)

【v1.1+ 復元手順】
1. feature_flags.dart の gcalPushEnabled = true に変更
2. _initial_pending_google_push を git history から復元
3. Settings UI トグルを git history から復元
4. 新規 migration 0XXX で全 user の gcal_push_enabled をリセット
5. 法務文書を再更新
詳細: FEAT-373 指示書 §9 参照
"""

from django.db import migrations


def _disable_push_for_all_users(apps, schema_editor):
    """v1.0 push 廃止: 全 PlayerProfile.gcal_push_enabled=False +
    全 TimelineEvent.pending_google_push=False に一括更新。

    pending_google_push=True のまま残置されていた予定が retryPendingPushes 等で
    Google に push されるリスクを構造的に排除する。
    FEAT-372 migration 0101 では「gcal_push_enabled=False ユーザーのみ」を対象としたが、
    本 migration 0102 では「全 player 一律」を対象とする (v1.0 で push 機能全廃のため)。
    """
    PlayerProfile = apps.get_model('api', 'PlayerProfile')
    TimelineEvent = apps.get_model('api', 'TimelineEvent')

    # 全 PlayerProfile の gcal_push_enabled を False に固定
    player_updated = PlayerProfile.objects.filter(
        gcal_push_enabled=True,
    ).update(gcal_push_enabled=False)
    print(f'[FEAT-373 reconcile] gcal_push_enabled True→False: {player_updated} player(s)')

    # 全 TimelineEvent の pending_google_push を False に reconcile
    event_updated = TimelineEvent.objects.filter(
        pending_google_push=True,
    ).update(pending_google_push=False)
    print(f'[FEAT-373 reconcile] pending_google_push True→False: {event_updated} event(s)')


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0101_gcal_push_pending_reconcile'),
    ]

    operations = [
        migrations.RunPython(
            _disable_push_for_all_users,
            reverse_code=migrations.RunPython.noop,
        ),
    ]
