"""【FEAT-468 (2026-07-02)】チュートリアル carousel popup 用画像モデル新規追加。

CreateModel + AddIndex のみ。RunPython なし (画像は admin から手動 upload)。
Announcement model と同じ Pillow ImageField pattern を流用。
"""
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0167_friend_id_12digit'),
    ]

    operations = [
        migrations.CreateModel(
            name='TutorialImage',
            fields=[
                ('id',        models.AutoField(auto_created=True, primary_key=True,
                                               serialize=False, verbose_name='ID')),
                ('screen',    models.CharField(
                                max_length=16,
                                choices=[
                                    ('home',      'ホーム (onboarding 完了直後)'),
                                    ('challenge', 'チャレンジ'),
                                    ('guild',     'ギルド'),
                                    ('calendar',  'カレンダー'),
                                ],
                                verbose_name='対象画面',
                              )),
                ('image',     models.ImageField(upload_to='tutorials/',
                                               verbose_name='チュートリアル画像')),
                ('caption',   models.CharField(max_length=200, blank=True, default='',
                                               verbose_name='キャプション (任意)',
                                               help_text='将来拡張用 (v1.0 では UI 表示なし)。空欄で構いません。')),
                ('order',     models.IntegerField(default=0, verbose_name='表示順')),
                ('is_active', models.BooleanField(default=True, verbose_name='有効')),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('updated_at', models.DateTimeField(auto_now=True)),
            ],
            options={
                'verbose_name':        'チュートリアル画像',
                'verbose_name_plural': 'チュートリアル画像',
                'ordering':            ['screen', 'order', 'id'],
            },
        ),
        migrations.AddIndex(
            model_name='tutorialimage',
            index=models.Index(
                fields=['screen', 'is_active', 'order'],
                name='idx_tutorial_scrn_active',
            ),
        ),
    ]
