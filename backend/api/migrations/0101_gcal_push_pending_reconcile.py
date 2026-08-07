"""【FEAT-372 (2026-05-28)】BUG-74 構造解消: gcal_push_enabled=False ユーザーの
既存 pending_google_push=True 予定を一括 False に reconcile (1 回限り cleanup)。

【CLAUDE.md「破壊的データマイグレーション禁止」原則の 1 回限り例外承認】
FEAT-370 hotfix (migration 0100 RunPython) と同パターンの 1 回限り例外:
  1. ホスティングプラン Shell 不可: Render Free プランは Shell アクセスを提供しない
     (= management command を migration 外で手動実行する経路が物理的に存在しない)
  2. 明確に意図された 1 回限りの cleanup: BUG-74 既存ユーザーの pending data 状態矛盾
     解消であり、再現性のあるテスト DB (gcal_push_enabled=True ユーザーのみ) では no-op
  3. chicken-and-egg 構造（部分的に該当）: Flutter defense-in-depth を含む新 deploy と
     同じタイミングで DB 状態を正規化したい

承認時の 3 経路記録:
- ✅ 本ファイル冒頭 docstring に「1 回限り例外承認」を明記、経緯 + 条件チェックを記述
- ✅ commit message に「CLAUDE.md 原則の 1 回限り例外」を明示、PM 判断責任を記録
- ✅ management command を並行維持（本 migration と同等ロジック + 2 段階確認付き）は
     Phase 4 以降の対応として「cleanup_gcal_push_pending.py は現在 Phase 1-4 スコープ外」
     を PM が確認して例外承認。単一目的・1 発 migrate で副作用なし。

設計ノート:
- 対象: gcal_push_enabled=False の PlayerProfile に紐付く TimelineEvent で
        pending_google_push=True のもの = 「設定 OFF なのに push 待ち」の矛盾状態
- 処理: 単一 UPDATE クエリで一括 False 更新 (O(n) ではなく player 単位のバッチ)
- reverse_code=noop: rollback 時は状態が戻らない (forward only cleanup の標準パターン)
- テスト DB への影響: gcal_push_enabled=True がデフォルト → テスト状態では no-op
"""

from django.db import migrations


def _reconcile_pending_for_disabled_users(apps, schema_editor):
    """gcal_push_enabled=False ユーザーの pending_google_push=True 予定を False に統一。

    UPDATE 1 回ではなく player ごとにループする理由:
    将来の拡張性 (player 単位の throttle / logging) のため。
    現状のユーザー数 (beta 5 名 + 開発者) では性能問題なし。
    """
    PlayerProfile = apps.get_model('api', 'PlayerProfile')
    TimelineEvent = apps.get_model('api', 'TimelineEvent')

    disabled_players = PlayerProfile.objects.filter(gcal_push_enabled=False)
    total_users = disabled_players.count()
    total_updated = 0

    for player in disabled_players.iterator():
        updated = TimelineEvent.objects.filter(
            player=player,
            pending_google_push=True,
        ).update(pending_google_push=False)
        total_updated += updated

    print(f'[FEAT-372 reconcile] gcal_push_enabled=False ユーザー数: {total_users}')
    print(f'[FEAT-372 reconcile] pending_google_push False 更新件数:  {total_updated}')


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0100_timeline_event_unique_constraint'),
    ]

    operations = [
        migrations.RunPython(
            _reconcile_pending_for_disabled_users,
            reverse_code=migrations.RunPython.noop,
        ),
    ]
