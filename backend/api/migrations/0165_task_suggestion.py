"""【FEAT-467 (2026-07-02)】タスクタイトル候補モデル新規追加 + 初期 seed。

master/seed data 例外条項適用 (CLAUDE.md「マイグレーション規則」):
  - 対象: TaskSuggestion のみ (user-generated content を含まない)
  - 冪等性: get_or_create (type + title) で重複 seed を防ぐ
  - RunPython 内容: kEventPresets (10 件) / kTodoPresets (6 件) /
    kHabitPresets (10 件) 計 26 件の初期 seed
  - hint/emoji は追加 defaults として保存するが、再 apply 時は上書きしない

本 migration 前に TaskSuggestion テーブルは存在しないため空テーブルへの
seed であり、破壊的データ操作の対象外。
"""
from django.db import migrations, models


def _seed_initial_suggestions(apps, schema_editor):
    TaskSuggestion = apps.get_model('api', 'TaskSuggestion')

    event_data = [
        dict(title='朝のランニング',  category='運動', emoji='🏃', hint=''),
        dict(title='読書の時間',       category='学習', emoji='📖', hint=''),
        dict(title='ストレッチ',       category='体力', emoji='🧘', hint=''),
        dict(title='休憩タイム',       category='休息', emoji='☕', hint=''),
        dict(title='集中作業',         category='仕事', emoji='💻', hint=''),
        dict(title='ミーティング',     category='仕事', emoji='👥', hint=''),
        dict(title='ランチ',           category='健康', emoji='🍽️', hint=''),
        dict(title='振り返りメモ',     category='精神', emoji='📝', hint=''),
        dict(title='趣味の時間',       category='休息', emoji='🎮', hint=''),
        dict(title='ウォーキング',     category='運動', emoji='🚶', hint=''),
    ]

    todo_data = [
        dict(title='コップ1杯の水を飲む',          category='健康', emoji='💧', hint='はじめの一歩'),
        dict(title='本を1ページ開く',              category='学習', emoji='📖', hint='自分への投資'),
        dict(title='5分だけ深呼吸する',            category='精神', emoji='🌬️', hint='心を整える'),
        dict(title='今日の出来事をメモする',        category='学習', emoji='📝', hint='振り返りの習慣'),
        dict(title='部屋を1か所だけ片づける',      category='精神', emoji='🧹', hint='小さな整理'),
        dict(title='誰かに「ありがとう」と伝える', category='社交', emoji='🤝', hint='今日の思いやり'),
    ]

    habit_data = [
        dict(title='朝のストレッチ 5 分', category='健康', emoji='🧘', hint='一日の準備運動'),
        dict(title='本を 15 分読む',      category='学習', emoji='📖', hint='知識を積み上げる'),
        dict(title='水を 2L 飲む',        category='健康', emoji='💧', hint='体の基本ケア'),
        dict(title='英単語 10 個覚える',  category='学習', emoji='🌎', hint='コツコツ語彙力'),
        dict(title='散歩 20 分',          category='運動', emoji='🚶', hint='体と心を整える'),
        dict(title='日記を書く',          category='精神', emoji='📓', hint='一日を振り返る'),
        dict(title='家族・友人に連絡',    category='社交', emoji='☎️', hint='大切な人とのつながり'),
        dict(title='週 1 でジム',         category='運動', emoji='💪', hint='しっかり鍛える'),
        dict(title='部屋を片づける',      category='精神', emoji='🧹', hint='心地よい空間を保つ'),
        dict(title='月 1 で新しいこと',   category='創造', emoji='✨', hint='創造の余白を作る'),
    ]

    for type_, rows in [('event', event_data), ('todo', todo_data), ('habit', habit_data)]:
        for order, row in enumerate(rows):
            TaskSuggestion.objects.get_or_create(
                type=type_,
                title=row['title'],
                defaults=dict(
                    category=row['category'],
                    emoji=row['emoji'],
                    hint=row['hint'],
                    order=order,
                    is_active=True,
                ),
            )


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0164_admin_mfa_challenge'),
    ]

    operations = [
        migrations.CreateModel(
            name='TaskSuggestion',
            fields=[
                ('id',         models.AutoField(auto_created=True, primary_key=True,
                                                 serialize=False, verbose_name='ID')),
                ('type',       models.CharField(max_length=8,
                                                choices=[('event', '予定'),
                                                         ('todo', 'ToDo'),
                                                         ('habit', '習慣')],
                                                verbose_name='種別')),
                ('title',      models.CharField(max_length=100, verbose_name='タイトル')),
                ('category',   models.CharField(max_length=16, blank=True, default='',
                                                verbose_name='カテゴリ')),
                ('emoji',      models.CharField(max_length=8, blank=True, default='',
                                                verbose_name='絵文字')),
                ('hint',       models.CharField(max_length=100, blank=True, default='',
                                                verbose_name='補足テキスト')),
                ('order',      models.IntegerField(default=0, verbose_name='表示順')),
                ('is_active',  models.BooleanField(default=True, verbose_name='有効')),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('updated_at', models.DateTimeField(auto_now=True)),
            ],
            options={
                'verbose_name':        'タスク候補',
                'verbose_name_plural': 'タスク候補',
                'ordering':            ['type', 'order', 'id'],
            },
        ),
        migrations.AddIndex(
            model_name='tasksuggestion',
            index=models.Index(
                fields=['type', 'is_active', 'order'],
                name='idx_tasksugg_type_active_order',
            ),
        ),
        migrations.RunPython(
            _seed_initial_suggestions,
            migrations.RunPython.noop,
        ),
    ]
