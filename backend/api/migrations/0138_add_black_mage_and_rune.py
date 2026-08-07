"""【BUG-104 (2026-06-14)】Job「黒魔導士 (black_mage)」+ Character「ルーン (rune)」追加。

【経緯】
  BUG-103 で旧 rune (青魔導士 = blue_mage) → cyan に rename した後、
  PM が新キャラデザを生成し直し、新「ルーン (黒魔導士)」として再投入する形。
  job 'black_mage' は新規 (既存は blue_mage / dark_mage / necromancer / magic_swordsman)。

【Job 設計 (PM 確定)】
  - job_id: 'black_mage', job_name: '黒魔導士'
  - atb_speed_modifier: 0.9  (やや遅い)
  - attack_power_modifier: 1.4  (中-高火力、blue 1.1 < black 1.4 < dark 1.5 の中間)
  - on_hit_effect: 'burn'  (炎付与)
  - ult_cost: 2  (必殺中頻度)
  - description: 「炎と雷を操る攻撃魔導士。安定した魔法ダメージを継続的に叩き込む」

【Character 設計 (PM 確定)】
  - key: 'rune', name: 'ルーン', role: '黒魔導士'
  - image_path: 'rune'  (assets/images/characters/character_rune.png に解決)
  - job: black_mage (1:1 紐付け、FEAT-430 「キャラ=ジョブ固定」原則)
  - price: 800💎  (SR-tier、cyan/lucia/faye/zenon/beatrix と同等)
  - unlock_level: 1, is_starter: False, order: 14 (aurum=13 の次)

【CLAUDE.md「master/seed data 例外条項」適用】
  Job + Character の seed/master 追加のみで user-generated content を破壊しない。
  update_or_create で冪等性確保、再 apply 安全。

【全 FK 影響分析 (例外条項 §2)】
  - 新 Character は新規追加のため既存 FK は不変
  - 新 Job も新規追加、既存 PlayerProfile.active_job / Character.job は不変
  - 既存 Character「cyan」(BUG-103 で rename 済) は影響なし
"""
from django.db import migrations


_NEW_JOB = {
    'job_id': 'black_mage', 'job_name': '黒魔導士',
    'atb_speed_modifier':    0.9,
    'attack_power_modifier': 1.4,
    'on_hit_effect':         'burn',
    'ult_cost':              2,
    'description':           '炎と雷を操る攻撃魔導士。安定した魔法ダメージを継続的に叩き込む',
}

_NEW_CHARACTER = {
    'key':          'rune',
    'name':         'ルーン',
    'role':         '黒魔導士',
    'description':  '禁忌の魔法書を紐解き、自らの内に黒い炎を宿した魔導士',
    'image_path':   'rune',
    'price':        800,
    'unlock_level': 1,
    'is_starter':   False,
    'order':        14,
}


def _add_black_mage_and_rune(apps, schema_editor):
    Job = apps.get_model('api', 'Job')
    Character = apps.get_model('api', 'Character')

    # ── Step 1: Job 'black_mage' を冪等追加 ──
    job, created = Job.objects.update_or_create(
        job_id=_NEW_JOB['job_id'],
        defaults={k: v for k, v in _NEW_JOB.items() if k != 'job_id'},
    )
    print(
        f'[migration 0138 BUG-104] Job black_mage'
        f' {"created" if created else "updated"}'
    )

    # ── Step 2: Character 'rune' を冪等追加、job FK で black_mage に紐付け ──
    char, created = Character.objects.update_or_create(
        key=_NEW_CHARACTER['key'],
        defaults={
            **{k: v for k, v in _NEW_CHARACTER.items() if k != 'key'},
            'job': job,
        },
    )
    print(
        f'[migration 0138 BUG-104] Character rune'
        f' {"created" if created else "updated"} (job=black_mage)'
    )


def _remove_rune_and_black_mage(apps, schema_editor):
    """ロールバック: rune Character → black_mage Job の順で削除。

    順序重要: Character.job が PROTECT 制約のため、先に Character を削除しないと
    Job 削除でエラーになる。
    """
    Character = apps.get_model('api', 'Character')
    Job = apps.get_model('api', 'Job')

    Character.objects.filter(key='rune').delete()
    Job.objects.filter(job_id='black_mage').delete()
    print('[migration 0138 BUG-104 reverse] Removed rune Character + black_mage Job')


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0137_rename_rune_to_cyan'),
    ]

    operations = [
        migrations.RunPython(_add_black_mage_and_rune, _remove_rune_and_black_mage),
    ]
