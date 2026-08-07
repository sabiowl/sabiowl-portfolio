from django.db import migrations, models
import django.db.models.deletion


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0003_shop'),
    ]

    operations = [
        # Habit に habit_type フィールドを追加
        migrations.AddField(
            model_name='habit',
            name='habit_type',
            field=models.CharField(
                choices=[('count', 'カウント'), ('checklist', 'チェックリスト')],
                default='count',
                max_length=20,
                verbose_name='タイプ',
            ),
        ),

        # ChecklistItem モデルを作成
        migrations.CreateModel(
            name='ChecklistItem',
            fields=[
                ('id',        models.AutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('text',      models.CharField(max_length=200, verbose_name='項目テキスト')),
                ('order',     models.IntegerField(default=0, verbose_name='表示順')),
                ('done_date', models.DateField(blank=True, null=True, verbose_name='完了日')),
                ('habit',     models.ForeignKey(
                    on_delete=django.db.models.deletion.CASCADE,
                    related_name='checklist_items',
                    to='api.habit',
                    verbose_name='習慣',
                )),
            ],
            options={
                'verbose_name':        'チェックリスト項目',
                'verbose_name_plural': 'チェックリスト項目',
                'ordering':            ['order', 'id'],
            },
        ),
    ]
