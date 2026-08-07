"""【新規 (2026-06-26)】実績 13 → 30 件への拡張。

## CLAUDE.md 例外条項適用

本 migration は CLAUDE.md「破壊的データマイグレーション禁止」原則の
**master/seed data 例外条項** (FEAT-391 初例継承) に該当:

1. **対象が master/seed data のみ**: Achievement は admin 管理の master 表、
   user-generated content ではない
2. **冪等性確保**: `get_or_create` で seed 投入、再 apply 安全
3. **FK 走査**: PlayerAchievement → Achievement は CASCADE のみ
   (本 migration は ADD のみで Achievement の DELETE/UPDATE なし)

## 操作

1. AlterField で Achievement.condition_type の choices を 5 → 8 種に拡張
   (perfect_day_count / active_habits / total_exp_earned 追加)
2. RunPython で 17 件の Achievement を get_or_create で seed
   (既存 13 件 + 17 件 = 30 件)

## 17 件の設計意図 (習慣化を助ける効果)

- **数量階梯延長** (5): 既存 total_logs/best_streak/level_reached の高位 tier
  を追加し、長期プレイヤーへのモチベーション維持
- **完璧な日々** (3 件、perfect_day_count): 全 active 習慣を達成した日数を
  カウント。「今日も全部できた」体験を称えることで daily flow を促進
- **多彩さ** (2 件、active_habits): 同時アクティブ習慣数。1 つの習慣しか
  していないユーザーに「複数並行」の入り口を可視化
- **学びの累積** (3 件、total_exp_earned): EXP 合計値の milestone。
  「積み上げの総量」を見える化、行動の蓄積効果を体感
- **絆** (1 件、friends_count): フレンド 5 人の追加
- **365 日** (1 件、best_streak): 1 年連続の究極目標
- **二週間** (1 件、best_streak): 14 日 = 「習慣化が始まる」と言われる節目
- **Lv 30 / 50** (2 件、level_reached): 既存 Lv 5/10/20 の上位 tier
"""
from django.db import migrations, models


def seed_new_achievements(apps, schema_editor):
    """13 → 30 件への拡張で追加する 17 件を get_or_create で投入。"""
    Achievement = apps.get_model('api', 'Achievement')

    seeds = [
        # ── 数量階梯延長 (total_logs 3 件 + best_streak 1 件追加) ────────────
        dict(key='log_300',  name='礎の石',         description='習慣を 300 回記録する',
             icon='🗿', condition_type='total_logs', condition_value=300,  reward_diamonds=250, order=14),
        dict(key='log_500',  name='石塁の主',       description='習慣を 500 回記録する',
             icon='🏯', condition_type='total_logs', condition_value=500,  reward_diamonds=400, order=15),
        dict(key='log_1000', name='千の積み上げ',   description='習慣を 1000 回記録する',
             icon='🗻', condition_type='total_logs', condition_value=1000, reward_diamonds=800, order=16),
        dict(key='streak_14',  name='二週間の航海', description='14 日連続で習慣を記録する (習慣化開始の節目)',
             icon='⛵', condition_type='best_streak', condition_value=14,  reward_diamonds=100, order=23),
        dict(key='streak_60',  name='二月の刻',     description='60 日連続で習慣を記録する',
             icon='🌙', condition_type='best_streak', condition_value=60,  reward_diamonds=400, order=24),
        dict(key='streak_100', name='百日の旅人',   description='100 日連続で習慣を記録する',
             icon='🏔️', condition_type='best_streak', condition_value=100, reward_diamonds=700, order=25),
        dict(key='streak_365', name='年輪の英雄',   description='365 日連続で習慣を記録する (究極の継続)',
             icon='🌳', condition_type='best_streak', condition_value=365, reward_diamonds=2000, order=26),

        # ── Lv 階梯延長 (level_reached 2 件追加) ────────────────────────────
        dict(key='level_30', name='賢者の一歩',    description='レベル 30 に到達する',
             icon='📚', condition_type='level_reached', condition_value=30, reward_diamonds=400,  order=33),
        dict(key='level_50', name='殿堂入り',      description='レベル 50 に到達する',
             icon='🎓', condition_type='level_reached', condition_value=50, reward_diamonds=1000, order=34),

        # ── 完璧な日々 (perfect_day_count、3 件) ────────────────────────────
        #   その日 active な習慣すべてに log がある日 = 「完璧な一日」を称える。
        #   daily flow を強化する設計 (1 日達成感を細分化して可視化)。
        dict(key='perfect_day_1',  name='完璧な一日', description='1 日のすべての習慣を達成する',
             icon='✨', condition_type='perfect_day_count', condition_value=1,  reward_diamonds=30,  order=60),
        dict(key='perfect_day_10', name='完璧の連鎖', description='完璧な一日を 10 日達成する',
             icon='🌠', condition_type='perfect_day_count', condition_value=10, reward_diamonds=100, order=61),
        dict(key='perfect_day_30', name='完璧の月',   description='完璧な一日を 30 日達成する',
             icon='🌌', condition_type='perfect_day_count', condition_value=30, reward_diamonds=300, order=62),

        # ── 多彩な習慣 (active_habits、2 件) ────────────────────────────────
        #   1 つの習慣に固執せず複数並行を促進。
        #   ToDo を除く count/checklist 習慣の同時アクティブ数で判定。
        dict(key='multi_habits_3', name='多彩な日々', description='3 つの習慣を同時に育てる',
             icon='🎨', condition_type='active_habits', condition_value=3, reward_diamonds=30,  order=70),
        dict(key='multi_habits_5', name='広い裾野',   description='5 つの習慣を同時に育てる',
             icon='🗺️', condition_type='active_habits', condition_value=5, reward_diamonds=100, order=71),

        # ── 学びの累積 (total_exp_earned、3 件) ─────────────────────────────
        #   累計獲得 EXP の milestone。行動の総量を可視化、長期積み上げ効果を体感。
        dict(key='exp_1000',  name='学びの泉', description='累計 1,000 EXP を獲得する',
             icon='💧', condition_type='total_exp_earned', condition_value=1000,  reward_diamonds=50,  order=80),
        dict(key='exp_5000',  name='知識の海', description='累計 5,000 EXP を獲得する',
             icon='🌊', condition_type='total_exp_earned', condition_value=5000,  reward_diamonds=150, order=81),
        dict(key='exp_20000', name='経験の山', description='累計 20,000 EXP を獲得する',
             icon='⛰️', condition_type='total_exp_earned', condition_value=20000, reward_diamonds=400, order=82),

        # ── 絆 (friends_count 拡張、1 件) ───────────────────────────────────
        dict(key='friends_5', name='仲間との絆', description='フレンドを 5 人作る',
             icon='👥', condition_type='friends_count', condition_value=5, reward_diamonds=80, order=51),
    ]

    for data in seeds:
        Achievement.objects.get_or_create(key=data['key'], defaults=data)


def _noop_reverse(apps, schema_editor):
    """逆方向は no-op (既存 PlayerAchievement への影響回避)。"""
    pass


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0158_sabi_message'),
    ]

    operations = [
        # ── condition_type choices 拡張 (5 → 8 種) ──────────────────────────
        migrations.AlterField(
            model_name='achievement',
            name='condition_type',
            field=models.CharField(
                choices=[
                    ('total_logs',        '累計ログ回数'),
                    ('best_streak',       '最長ストリーク'),
                    ('level_reached',     '到達レベル'),
                    ('gacha_pulls',       'ガチャ回数'),
                    ('friends_count',     'フレンド数'),
                    ('perfect_day_count', '完璧な達成日数'),
                    ('active_habits',     '同時アクティブ習慣数'),
                    ('total_exp_earned',  '累計獲得EXP'),
                ],
                max_length=32,
            ),
        ),
        # ── 17 件の新規 Achievement を seed 投入 (master/seed data 例外条項適用) ──
        migrations.RunPython(seed_new_achievements, _noop_reverse),
    ]
