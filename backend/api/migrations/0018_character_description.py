from django.db import migrations, models


class Migration(migrations.Migration):
    """
    Character モデルに description（説明文）フィールドを追加し、
    既存キャラクターの背景設定・一言コメントを投入する。
    """

    dependencies = [
        ('api', '0017_reset_settings'),
    ]

    operations = [
        # ── 1. フィールド追加 ──────────────────────────────────────
        migrations.AddField(
            model_name='character',
            name='description',
            field=models.TextField(blank=True, default='', verbose_name='説明文'),
        ),

        # ── 2. 既存キャラクターの説明文を投入 ─────────────────────
        migrations.RunSQL(
            sql="""
            UPDATE api_character SET description = '無言で剣を振り続ける。かつての傷跡が、今の強さになった。'
            WHERE key = 'warrior_m';

            UPDATE api_character SET description = '影に潜み、瞬く間に仕留める。笑顔の裏に刃を隠す。'
            WHERE key = 'assassin_f';

            UPDATE api_character SET description = '古代の文字を読み解いた日から、世界の色が変わって見えた。'
            WHERE key = 'mage_m';

            UPDATE api_character SET description = '癒しの光は、彼女自身の痛みを知っているから温かい。'
            WHERE key = 'healer_f';

            UPDATE api_character SET description = '鎧の重さより、守る者の笑顔の重さを知っている。'
            WHERE key = 'knight_f';

            UPDATE api_character SET description = '放った矢は戻らない。だからこそ、一射に全てを込める。'
            WHERE key = 'archer_m';

            UPDATE api_character SET description = '禁じられた力を手にした者だけが、世界の真実に触れられる。'
            WHERE key = 'dark_sorceress_f';
            """,
            reverse_sql="UPDATE api_character SET description = '';",
        ),
    ]
