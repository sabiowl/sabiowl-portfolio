from django.db import migrations


class Migration(migrations.Migration):
    """
    キャラクタースターター設定の更新:
    1. warrior_m / assassin_f の image_path を _normal に変更
    2. mage_m / healer_f / knight_f / archer_m を is_starter=True に（初期選択可能）
    3. dark_sorceress_f は引き続き is_starter=False（ショップのみ）
    """

    dependencies = [
        ('api', '0015_character_system'),
    ]

    operations = [
        migrations.RunSQL(
            sql="""
            -- warrior_m: image_path を _normal に更新
            UPDATE api_character
            SET image_path = '/character_m_normal.png'
            WHERE key = 'warrior_m';

            -- assassin_f: image_path を _normal に更新
            UPDATE api_character
            SET image_path = '/character_f_normal.png'
            WHERE key = 'assassin_f';

            -- mage_m / healer_f / knight_f / archer_m を is_starter=TRUE に
            UPDATE api_character
            SET is_starter = TRUE
            WHERE key IN ('mage_m', 'healer_f', 'knight_f', 'archer_m');
            """,
            reverse_sql="""
            UPDATE api_character
            SET image_path = '/character_m_lv10.png'
            WHERE key = 'warrior_m';

            UPDATE api_character
            SET image_path = '/character_f_lv20.png'
            WHERE key = 'assassin_f';

            UPDATE api_character
            SET is_starter = FALSE
            WHERE key IN ('mage_m', 'healer_f', 'knight_f', 'archer_m');
            """,
        ),
    ]
