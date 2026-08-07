"""【BUG-76 (2026-05-30)】Google sync 100% 失敗バグ構造解消: UniqueConstraint に source 軸追加。

FEAT-370 (migration 0100) で導入した UniqueConstraint が source 軸を考慮しておらず、
Sabiowl 既存予定 + Google Calendar 同名予定の構造的衝突で Google sync が 100% 失敗
していた。本 migration で source 軸を追加し、source 別に重複防止 + cross-source の
同名予定共存を許可する。

【衝突メカニズム】
- ExternalCalendarImportView.post() の update_or_create は (player, source, external_id)
  を look-up キーとし、該当 row なし → INSERT 試行
- 旧 UniqueConstraint(player, date, title, start_time) は source を区別しない
- Sabiowl 既存予定 (例: 「ランチ 12:00-12:30」, source='local') + Google 同名予定
  (source='google') の cross-source 衝突で IntegrityError → 500

【設計判断】
- 拡張方向 (制約緩和) のため既存データ破壊なし、cleanup 不要
  (既存データは旧制約に合致 = 新制約にも自動合致、source 軸追加で範囲が広がるのみ)
- 既存制約名 (unique_timeline_event_with_starttime / unique_timeline_event_no_starttime)
  を維持して Django migration の混乱回避 (Remove → Add の組み合わせで実施)
- BUG-70 本来の目的 (同一 source 内重複防止) は完全に維持

【CLAUDE.md 原則準拠】
- ❌ データ cleanup 不要 (拡張方向のため既存データ全て自動合致)
- ✅ 制約 metadata のみ変更 (Postgres DDL transaction で atomic)
- ✅ rollback 安全 (RemoveConstraint reverse = AddConstraint、双方向動作)

【関連】
- BUG-76 指示書 (`doc/instructions/BUG-76_calendar_sync_unique_constraint_source_missing.md`)
- migration 0100 (`backend/api/migrations/0100_timeline_event_unique_constraint.py`) の修正
- cleanup_duplicate_timeline_events.py management command の同調修正 (グルーピングキー追加)
- 契約テスト: backend/api/tests/test_calendar_sync_cross_source.py

【SEC-14 (2026-05-30)】Migration 番号衝突修正のため 0101 → 0113 にリネーム。
旧 0101_timeline_event_unique_constraint_source は同名の親
(`0100_timeline_event_unique_constraint`) を持つ `0101_gcal_push_pending_reconcile`
(FEAT-372、commit `15e7325`) と番号衝突しており、線形チェーン (`0102 → ... → 0112`)
に組み込まれない孤立リーフ状態だった。BUG-76 hotfix (commit `5143fef`、2026-05-30)
の構造的解消の意図を維持しつつ、最新線形チェーン末尾 (`0112_job_system_8job_expansion`)
に依存を変更してリーフ統合した。

関連:
- 起源: doc/security_audit/20260530_audit_report.md H-01
- 指示書: doc/instructions/SEC-14_fix_migration_0101_collision.md

【CLAUDE.md「破壊的データマイグレーション禁止」原則の 1 回限り例外承認】
FEAT-370 hotfix (migration 0100 RunPython) と同パターンの 1 回限り例外:
  1. ホスティングプラン Shell 不可: Render Free プランは Shell アクセスを提供しない
     (= django_migrations row 名 UPDATE を migration 外で手動実行する経路が物理的に存在しない)
  2. chicken-and-egg 構造: ファイルリネーム後の deploy で row 名乖離が発生、
     migration 自身で row 名同期する以外に経路がない
  3. 明確に意図された 1 回限りの cleanup: BUG-76 hotfix 残骸の row 名整合、
     再現性のあるテスト DB (旧 0101 が存在しない fresh DB) では no-op

承認時の 3 経路記録:
- ✅ 本ファイル冒頭 docstring に「1 回限り例外承認」を明記、経緯 + 条件チェックを記述
- ✅ commit message に「CLAUDE.md 原則の 1 回限り例外」を明示、PM 判断責任を記録
- ✅ management command 並行維持不要: row 名 UPDATE は別環境 (fresh DB) では発火しない
     (WHERE 条件に該当 row が存在しないため 0 row UPDATE = no-op、冪等性確保)
"""
from django.db import migrations, models


def _rename_old_migration_row(apps, schema_editor):
    """旧 0101_timeline_event_unique_constraint_source row を 0113 にリネーム。

    Phase 1 でファイル名を変更したが、production DB の django_migrations テーブルには
    旧 row 名が残っているため、新ファイル apply 時に「履歴と現物の乖離」エラーが起きる。
    本関数で migration apply の最初に row 名を新ファイル名へ書き換える。

    fresh DB / 旧 row 不在環境では 0 row 更新 = no-op (冪等)。

    注: apps.get_model は使えない (django_migrations は Django 内部テーブル)。
    """
    from django.db import connection
    with connection.cursor() as cursor:
        cursor.execute(
            "UPDATE django_migrations "
            "SET name = '0113_timeline_event_unique_constraint_source' "
            "WHERE app = 'api' "
            "AND name = '0101_timeline_event_unique_constraint_source'"
        )


class Migration(migrations.Migration):

    dependencies = [
        # 【SEC-14】旧: ('api', '0100_timeline_event_unique_constraint') (孤立リーフ)
        # 新: 線形チェーン末尾に統合して孤立を解消
        ('api', '0112_job_system_8job_expansion'),
    ]

    operations = [
        # ── SEC-14: production DB の旧 row 名 → 新 row 名に同期 ───────
        # 詳細は本ファイル docstring「1 回限り例外承認」セクションを参照。
        # fresh DB / ローカル新規 DB では no-op (WHERE 条件不一致で 0 row UPDATE)。
        migrations.RunPython(
            _rename_old_migration_row,
            reverse_code=migrations.RunPython.noop,
        ),
        # ── BUG-76 既存 operations (制約の Remove + Add) ──────────────
        # 旧制約 (source 軸なし) を撤去 ──────────────────────────────
        migrations.RemoveConstraint(
            model_name='timelineevent',
            name='unique_timeline_event_with_starttime',
        ),
        migrations.RemoveConstraint(
            model_name='timelineevent',
            name='unique_timeline_event_no_starttime',
        ),
        # 新制約 (source 軸追加) を適用 ──────────────────────────────
        # source 別に重複防止、cross-source の同名予定は共存可能
        migrations.AddConstraint(
            model_name='timelineevent',
            constraint=models.UniqueConstraint(
                fields=['player', 'source', 'date', 'title', 'start_time'],
                condition=models.Q(start_time__isnull=False),
                name='unique_timeline_event_with_starttime',
            ),
        ),
        migrations.AddConstraint(
            model_name='timelineevent',
            constraint=models.UniqueConstraint(
                fields=['player', 'source', 'date', 'title'],
                condition=models.Q(start_time__isnull=True),
                name='unique_timeline_event_no_starttime',
            ),
        ),
    ]
