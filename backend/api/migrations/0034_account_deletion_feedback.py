from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0033_rest_day'),
    ]

    operations = [
        migrations.CreateModel(
            name='AccountDeletionFeedback',
            fields=[
                ('id',           models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('player_id',    models.IntegerField()),
                ('player_level', models.IntegerField(default=1)),
                ('reason',       models.CharField(
                    max_length=30,
                    choices=[
                        ('too_difficult',    '使い方がわからなかった'),
                        ('hard_to_continue', '続けるのが難しかった'),
                        ('not_my_style',     'サビやゲーム要素が合わなかった'),
                        ('switched_app',     '他のアプリに乗り換えた'),
                        ('bored',            '飽きてしまった'),
                        ('privacy_concern',  'データを残したくない'),
                        ('other',            'その他'),
                    ],
                )),
                ('reason_text',  models.TextField(blank=True, default='')),
                ('app_version',  models.CharField(blank=True, max_length=20)),
                ('created_at',   models.DateTimeField(auto_now_add=True)),
            ],
            options={
                'ordering': ['-created_at'],
            },
        ),
    ]
