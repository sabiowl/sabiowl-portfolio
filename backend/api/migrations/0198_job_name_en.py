# 【FEAT-489 Phase 2F-a】Job.job_name_en 追加 + 既存 14 ジョブの英名 seed
#
# ## 経緯
#
# FEAT-489 Phase 4 で `Enemy.name_en` (0194) / `Character.name_en` (0195) /
# `Announcement.title_en` (0192) / `TaskSuggestion.title_en` (0193) を追加した際、
# **Job だけが漏れていた**。Phase 2E の Mobile 側 verify で検出。
#
# `Job.job_name` は `character_page` / `party_edit_dialog` / `Combatant` で表示される
# ため、英語 locale でも API から日本語が返り続けていた。Mobile 側の fallback だけを
# 英語化すると「API 由来は『戦士』/ fallback だけ Warrior」の画面内 2 言語混在に
# なるため、Backend の field 追加が前提条件になっている。
#
# ## master/seed data 例外条項の適用 (CLAUDE.md「マイグレーション規則」/ FEAT-391)
#
# 本 migration は `RunPython` を含むが、**master data のみ + FK 網羅 + 冪等性**の
# 3 条件を満たすため例外条項に該当する:
#
#   - master data のみ: `Job` は運営が admin で管理するマスタ。ユーザーデータを
#     一切触らない (破壊的操作なし、`.delete()` / 一括 `update()` を含まない)
#   - FK 網羅: `job_id` を一意キーとして既存 row のみ更新。新規 row を作らないため
#     FK 不整合が起き得ない
#   - 冪等性: `filter(job_id=...).update(job_name_en=...)` は再 apply 安全。
#     row が無ければ 0 件更新で no-op
#
# ## 英名の出典
#
# `mobile/lib/l10n/app_en.arb` の `battleJobName*` (Phase 2A で投入済) と**同値**。
# 2 箇所に同じ文字列を持つことになるが、これは意図的:
#   - Backend: API 経由で表示される `Job.job_name` の真実値
#   - Mobile:  `job_choices.dart` のローカルカタログ (オフライン / 楽観 UI 用)
# 値がずれると表示が揺れるため、片方を変えたら必ずもう片方も合わせること。

from django.db import migrations, models

# job_id -> 英語表示名 (mobile/lib/l10n/app_en.arb の battleJobName* と一致させる)
_JOB_NAME_EN = {
    'warrior':         'Warrior',
    'assassin':        'Assassin',
    'blue_mage':       'Blue Mage',
    # 【migration 0147】job_id は 'healer' のまま、表示名だけ 白魔導士 / White Mage
    'healer':          'White Mage',
    'knight':          'Knight',
    'archer':          'Archer',
    'monk':            'Monk',
    'dark_mage':       'Dark Mage',
    'magic_swordsman': 'Magic Swordsman',
    'bard':            'Bard',
    'necromancer':     'Necromancer',
    'gunner':          'Gunner',
    'alchemist':       'Alchemist',
    'black_mage':      'Black Mage',
}


def seed_job_name_en(apps, schema_editor):
    """既存 Job row に英名を埋める。冪等 (再 apply しても同じ結果)。"""
    Job = apps.get_model('api', 'Job')
    for job_id, name_en in _JOB_NAME_EN.items():
        Job.objects.filter(job_id=job_id).update(job_name_en=name_en)


def unseed_job_name_en(apps, schema_editor):
    """reverse: 英名を空に戻す (field 自体は AddField の reverse が落とす)。"""
    Job = apps.get_model('api', 'Job')
    Job.objects.filter(job_id__in=list(_JOB_NAME_EN)).update(job_name_en='')


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0197_enemy_bg_path_webp'),
    ]

    operations = [
        migrations.AddField(
            model_name='job',
            name='job_name_en',
            field=models.CharField(
                blank=True,
                default='',
                max_length=64,
                verbose_name='表示名(英語版)',
            ),
        ),
        migrations.RunPython(seed_job_name_en, unseed_job_name_en),
    ]
