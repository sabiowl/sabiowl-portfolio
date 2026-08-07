from django.db import migrations


class Migration(migrations.Migration):
    """
    各キャラクターの description を2〜3文の本格的なストーリー文に更新する。
    スキーマ変更なし（データマイグレーションのみ）。
    """

    dependencies = [
        ('api', '0022_alter_playergachastatus_daily_last_granted'),
    ]

    operations = [
        migrations.RunSQL(
            sql="""
            UPDATE api_character SET description =
'幼いころ、村を焼いた炎の中で誓った。二度とあの日の無力感を繰り返さないと。戦場を渡り歩いた傷が全身を覆うが、剣を握る手だけは一度も震えたことがない。言葉より先に剣が語る——それが彼の流儀だ。'
            WHERE key = 'warrior_m';

            UPDATE api_character SET description =
'笑顔は仮面であり、最大の武器だ。ギルドに身を売ってから十年、標的の名前すら憶えていない。でも、あの子どもの目だけは忘れられない。いつかその記憶を清算する日のために、今日も影の中を歩く。'
            WHERE key = 'assassin_f';

            UPDATE api_character SET description =
'禁書庫の奥で見つけた一ページが、彼の人生を変えた。古代語で書かれた呪文を唱えた瞬間、世界は別の色に染まった。知識は力であり、同時に孤独だ——すべてを知る者に、並走できる者はいない。'
            WHERE key = 'mage_m';

            UPDATE api_character SET description =
'傷を癒す光は、自分自身が深く傷ついているほど温かくなる。幼いころの病が彼女を医術へと向かわせ、戦場の悲劇が彼女を戦場医に変えた。誰かが苦しんでいる限り、彼女の手は止まらない。'
            WHERE key = 'healer_f';

            UPDATE api_character SET description =
'鎧を纏うのは自分を守るためではない、守るべき者の笑顔を守るためだ。女性騎士として偏見と戦いながら、彼女は誰よりも正面から盾を構え続けた。その背中を見て育った子どもたちが、今では彼女の誇りになっている。'
            WHERE key = 'knight_f';

            UPDATE api_character SET description =
'師に教わった言葉がある——「矢は放ったら戻らない、だから放つ前に全てを賭けろ」。森で独り修行した千日が、彼の目と腕を別次元へと磨き上げた。百発百中を超えた先に、彼だけが見える境地がある。'
            WHERE key = 'archer_m';

            UPDATE api_character SET description =
'禁じられた力を手にした代償として、彼女は孤独を選んだ。世界の均衡を壊しかねない魔法を、自分の意志だけで制御し続けている。誰も近づかせないのは冷たさからではない——守りたいものがあるから、距離を置くのだ。'
            WHERE key = 'dark_sorceress_f';
            """,
            reverse_sql="""
            UPDATE api_character SET description = '無言で剣を振り続ける。かつての傷跡が、今の強さになった。' WHERE key = 'warrior_m';
            UPDATE api_character SET description = '影に潜み、瞬く間に仕留める。笑顔の裏に刃を隠す。' WHERE key = 'assassin_f';
            UPDATE api_character SET description = '古代の文字を読み解いた日から、世界の色が変わって見えた。' WHERE key = 'mage_m';
            UPDATE api_character SET description = '癒しの光は、彼女自身の痛みを知っているから温かい。' WHERE key = 'healer_f';
            UPDATE api_character SET description = '鎧の重さより、守る者の笑顔の重さを知っている。' WHERE key = 'knight_f';
            UPDATE api_character SET description = '放った矢は戻らない。だからこそ、一射に全てを込める。' WHERE key = 'archer_m';
            UPDATE api_character SET description = '禁じられた力を手にした者だけが、世界の真実に触れられる。' WHERE key = 'dark_sorceress_f';
            """,
        ),
    ]
