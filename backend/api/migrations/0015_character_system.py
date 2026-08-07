from django.db import migrations, models
import django.db.models.deletion


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0014_habit_difficulty'),
    ]

    operations = [
        # ── 1. Character テーブル ──────────────────────────────────
        migrations.CreateModel(
            name='Character',
            fields=[
                ('id',           models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('key',          models.CharField(max_length=50, unique=True, verbose_name='キー')),
                ('name',         models.CharField(max_length=50, verbose_name='名前')),
                ('role',         models.CharField(max_length=50, verbose_name='役職')),
                ('image_path',   models.CharField(max_length=100, verbose_name='画像パス')),
                ('price',        models.IntegerField(default=1500, verbose_name='購入価格（ゴールド）')),
                ('unlock_level', models.IntegerField(default=1, verbose_name='解放レベル')),
                ('is_starter',   models.BooleanField(default=False, verbose_name='初期選択可能')),
                ('order',        models.IntegerField(default=0, verbose_name='表示順')),
            ],
            options={
                'verbose_name':        'キャラクター',
                'verbose_name_plural': 'キャラクター',
                'ordering':            ['order'],
            },
        ),

        # ── 2. OwnedCharacter テーブル ────────────────────────────
        migrations.CreateModel(
            name='OwnedCharacter',
            fields=[
                ('id',           models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('purchased_at', models.DateTimeField(auto_now_add=True, verbose_name='取得日時')),
                ('character',    models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='owners',   to='api.character', verbose_name='キャラクター')),
                ('player',       models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='owned_characters', to='api.playerprofile', verbose_name='プレイヤー')),
            ],
            options={
                'verbose_name':        '所持キャラクター',
                'verbose_name_plural': '所持キャラクター',
            },
        ),
        migrations.AlterUniqueTogether(
            name='ownedcharacter',
            unique_together={('player', 'character')},
        ),

        # ── 3. PlayerProfile に active_character FK 追加 ──────────
        migrations.AddField(
            model_name='playerprofile',
            name='active_character',
            field=models.ForeignKey(
                blank=True, null=True,
                on_delete=django.db.models.deletion.SET_NULL,
                related_name='+',
                to='api.character',
                verbose_name='使用中キャラクター',
            ),
        ),

        # ── 4. 初期キャラクターデータ ─────────────────────────────
        migrations.RunSQL(
            sql="""
            INSERT INTO api_character (key, name, role, image_path, price, unlock_level, is_starter, "order") VALUES
              ('warrior_m',        'ソウル',   '戦士',       '/character_sol.png',         0,    1,  TRUE,  0),
              ('assassin_f',       'アリア',   'アサシン',    '/character_aria.png',          0,    1,  TRUE,  1),
              ('mage_m',           'ルーン',   '魔法使い',    '/character_rune.png',           1500, 1,  FALSE, 2),
              ('healer_f',         'ルシア',   'ヒーラー',    '/character_lucia.png',         1500, 1,  FALSE, 3),
              ('monk_m',         'ゼノン',   'モンク',    '/character_zenon.png',         1500, 1,  FALSE, 4),
              ('knight_f',         'ベアトリス',    'ナイト',      '/character_beatrix.png',         1500, 1,  FALSE, 5),
              ('archer_m',         'フェイ',   'アーチャー',  '/character_faye.png',         1500, 1,  FALSE, 6),
              ('dark_sorceress_f', 'ノワール', '暗黒魔道士',  '/character_noir.png',  3000, 20, FALSE, 7);
            """,
            reverse_sql="DELETE FROM api_character;",
        ),
    ]
