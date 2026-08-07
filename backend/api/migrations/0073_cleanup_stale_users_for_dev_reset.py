"""
FEAT-250: 元々は非管理者 User を全削除する破壊的データマイグレーションだったが、
management command (`python manage.py cleanup_stale_users`) に移行した。

経緯:
- 2026-05-20: BUG-67 の応急処置として作成、Render で 4 件 / 97 行 CASCADE 削除を実行済
- 2026-05-21: FEAT-250 で no-op 化、ロジックは management command に移植

Render では既に実行完了済のため、ロジックを消しても事実は変わらない（マイグレーション
履歴には「実行済」記録だけ残る）。

今後同種の cleanup が必要になった場合:
    python manage.py cleanup_stale_users --dry-run    # 確認
    python manage.py cleanup_stale_users --confirm    # 実行

設計反省:
`RunPython` で `.delete()` / 大量 `update()` 等の破壊的データ操作を `migrate`
パイプラインに組み込むのはアンチパターン。`build.sh` の自動実行で本番データが
不可逆的に変質する事故の温床となるため、必ず management command に分離する。
"""
from django.db import migrations


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0072_cleanup_orphan_users'),
    ]

    operations = [
        # FEAT-250: ロジックは management command (cleanup_stale_users) に移行済。
        # 既に Render で実行完了済 + migration 履歴は「実行済」記録のみ残せばよいため no-op。
        migrations.RunPython(migrations.RunPython.noop, migrations.RunPython.noop),
    ]
