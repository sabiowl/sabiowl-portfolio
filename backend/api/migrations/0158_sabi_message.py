"""【新規 (2026-06-26)】SabiMessage モデル作成 + YAML から初期 seed 投入。

## CLAUDE.md 例外条項適用

本 migration は CLAUDE.md「破壊的データマイグレーション禁止」原則の
**master/seed data 例外条項** (FEAT-391 初例) に該当:

1. **対象が master/seed data のみ**: SabiMessage は admin 管理の master 表、
   user-generated content ではない
2. **冪等性確保**: `get_or_create` で seed 投入、再 apply 安全
3. **FK 走査不要**: SabiMessage は他モデルへの FK 参照なし

## 操作

1. CreateModel SabiMessage (新規テーブル + index)
2. RunPython `_seed_from_yaml`: `sabi_dialogue.yaml` から home/context/time_segment
   配下の主要 18 プールを読み込み、SabiMessage 行として一括 create
   (greetings / streak / knowledge は YAML 専用のため対象外)
"""
import django.db.models.deletion
from django.db import migrations, models


def _seed_from_yaml(apps, schema_editor):
    """sabi_dialogue.yaml から SabiMessage 行を投入 (冪等)。"""
    import yaml
    from pathlib import Path

    SabiMessage = apps.get_model('api', 'SabiMessage')

    yaml_path = Path(__file__).parent.parent / 'sabi_dialogue.yaml'
    if not yaml_path.exists():
        # YAML 未配置時は seed 投入をスキップ (テスト時等の許容ケース)
        return

    with open(yaml_path, encoding='utf-8') as f:
        data = yaml.safe_load(f)

    def _seed_pool(pool_key: str, messages: list):
        if not isinstance(messages, list):
            return
        for idx, content in enumerate(messages):
            if not isinstance(content, str):
                continue
            SabiMessage.objects.get_or_create(
                pool=pool_key,
                content=content,
                defaults={'sort_order': idx, 'is_active': True},
            )

    # ── home pools (8) ──────────────────────────────────────────────
    home = data.get('home', {})
    for key in [
        'no_habits', 'all_done', 'partial', 'none_done',
        'high_level', 'early_level', 'pun', 'knowledge_general',
    ]:
        _seed_pool(f'home_{key}', home.get(key, []))

    # ── contexts (4) ────────────────────────────────────────────────
    contexts = data.get('contexts', {})
    for key in ['rest_day', 'comeback', 'default', 'undo']:
        _seed_pool(f'context_{key}', contexts.get(key, []))

    # ── time_segment (6) ────────────────────────────────────────────
    time_seg = data.get('time_segment', {})
    for key in [
        'early_morning', 'morning', 'noon',
        'evening', 'night', 'late_night',
    ]:
        _seed_pool(f'time_{key}', time_seg.get(key, []))


def _noop_reverse(apps, schema_editor):
    """逆方向は no-op (table 全 drop は CreateModel 逆操作で実施)。"""
    pass


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0157_challenge_v11_tier_system'),
    ]

    operations = [
        migrations.CreateModel(
            name='SabiMessage',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('pool', models.CharField(choices=[
                    ('home_no_habits',         'ホーム: 習慣ゼロ'),
                    ('home_all_done',          'ホーム: 全達成'),
                    ('home_partial',           'ホーム: 一部達成'),
                    ('home_none_done',         'ホーム: 達成ゼロ'),
                    ('home_high_level',        'ホーム: 高レベル (Lv30+)'),
                    ('home_early_level',       'ホーム: 初期レベル (Lv<5)'),
                    ('home_pun',               'ホーム: コツコツ系 (10 回に 1 回)'),
                    ('home_knowledge_general', 'ホーム: 習慣化知識 (7 回に 1 回)'),
                    ('context_rest_day',       'context: 休息日'),
                    ('context_comeback',       'context: コンバック'),
                    ('context_default',        'context: デフォルト'),
                    ('context_undo',           'context: Undo 操作後'),
                    ('time_early_morning',     '時間帯: 早朝 (5-8 時)'),
                    ('time_morning',           '時間帯: 朝 (8-12 時)'),
                    ('time_noon',              '時間帯: 昼 (12-17 時)'),
                    ('time_evening',           '時間帯: 夕 (17-21 時)'),
                    ('time_night',             '時間帯: 夜 (21-24 時)'),
                    ('time_late_night',        '時間帯: 深夜 (0-5 時)'),
                ], db_index=True, max_length=32, verbose_name='プール',
                    help_text='どの場面で表示されるかのカテゴリ')),
                ('content', models.TextField(verbose_name='セリフ',
                    help_text='サビ口調統一: 「〜ですね」「〜ますよ」、感嘆符 / じゃ / だね 禁止')),
                ('is_active', models.BooleanField(default=True, db_index=True, verbose_name='有効',
                    help_text='OFF にすると本セリフは出現しなくなる (削除せず一時無効化したい時)')),
                ('sort_order', models.IntegerField(default=0, verbose_name='並び順',
                    help_text='admin 画面の表示順 (実際の選択は seed % 件数 でランダム)')),
                ('note', models.TextField(blank=True, default='', verbose_name='管理メモ',
                    help_text='運営用メモ。「2026-06 追加」「ABテスト対象」等 (ユーザーには非表示)')),
                ('created_at', models.DateTimeField(auto_now_add=True, verbose_name='作成日時')),
                ('updated_at', models.DateTimeField(auto_now=True, verbose_name='更新日時')),
            ],
            options={
                'verbose_name': 'サビセリフ',
                'verbose_name_plural': 'サビセリフ',
                'ordering': ['pool', 'sort_order', 'id'],
            },
        ),
        migrations.AddIndex(
            model_name='sabimessage',
            index=models.Index(fields=['pool', 'is_active'],
                               name='idx_sabimsg_pool_active'),
        ),
        # YAML から seed 投入 (master/seed data 例外条項)
        migrations.RunPython(_seed_from_yaml, _noop_reverse),
    ]
