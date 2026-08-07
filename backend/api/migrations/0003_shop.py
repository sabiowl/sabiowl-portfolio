from django.db import migrations, models
import django.db.models.deletion
import django.utils.timezone


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0002_habit_frequency'),
    ]

    operations = [
        # PlayerProfile に coins_spent フィールドを追加
        migrations.AddField(
            model_name='playerprofile',
            name='coins_spent',
            field=models.IntegerField(default=0, verbose_name='使用コイン合計'),
        ),

        # PlayerItem モデルを作成
        migrations.CreateModel(
            name='PlayerItem',
            fields=[
                ('id', models.AutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('item_id',      models.CharField(max_length=50, verbose_name='アイテムID')),
                ('quantity',     models.IntegerField(default=1, verbose_name='所持数')),
                ('purchased_at', models.DateTimeField(auto_now_add=True, verbose_name='購入日時')),
                ('player', models.ForeignKey(
                    on_delete=django.db.models.deletion.CASCADE,
                    related_name='items',
                    to='api.playerprofile',
                    verbose_name='プレイヤー',
                )),
            ],
            options={
                'verbose_name':        '所持アイテム',
                'verbose_name_plural': '所持アイテム',
            },
        ),

        # (player, item_id) の unique 制約
        migrations.AlterUniqueTogether(
            name='playeritem',
            unique_together={('player', 'item_id')},
        ),
    ]
