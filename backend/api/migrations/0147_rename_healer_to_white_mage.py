"""【BUG-139 (2026-06-20)】ジョブ rename: 「ヒーラー」→「白魔導士」+ lucia role 連動。

【経緯】
  PM 判断 (2026-06-20): healer ジョブの表示名 (Job.job_name) を「ヒーラー」から
  「白魔導士」へ変更。FF 系の白魔/黒魔の対比 (rune = 黒魔導士, lucia = 白魔導士)
  でジョブ命名体系を統一する意図。Mobile 側 job_choices.dart / 関連テストも
  同コミットで同期更新済 (kJobs[3].name)。

【変更内容】
  - Job.job_id = 'healer' の job_name を 'ヒーラー' → '白魔導士' に更新
  - Character.key = 'lucia' の role を 'ヒーラー' → '白魔導士' に更新
    (BUG-110 / migration 0141 の cyan 同期と同じ整合ルール: role と job_name は一致)

【CLAUDE.md「master/seed data 例外条項」適用】
  - Job + Character の master/seed data 限定の UPDATE のみ (user-generated content
    を破壊しない)
  - filter().update() で冪等性確保、再 apply 安全 (reversible)
  - 例外条項 §1-3 を全て満たす

【全 FK 影響分析 (例外条項 §2)】
  - PlayerProfile.active_job → 不変 (Job.id 不変、job_name のみ String 更新)
  - Character.job → 不変 (同上)
  - OwnedCharacter / PlayerProfile.active_character → 不変 (Character.id 不変、
    Character.role は表示用 String、JOIN/lookup には使われない)
  - 結論: FK 影響ゼロ、表示文字列のみの変更
"""
from django.db import migrations


def _rename_healer_to_white_mage(apps, schema_editor):
    Job = apps.get_model('api', 'Job')
    Character = apps.get_model('api', 'Character')

    job_updated = Job.objects.filter(job_id='healer').update(job_name='白魔導士')
    char_updated = Character.objects.filter(key='lucia').update(role='白魔導士')

    print(f'[migration 0147 BUG-139] Job healer.job_name -> 白魔導士 ({job_updated} row(s))')
    print(f'[migration 0147 BUG-139] Character lucia.role -> 白魔導士 ({char_updated} row(s))')


def _revert_rename(apps, schema_editor):
    Job = apps.get_model('api', 'Job')
    Character = apps.get_model('api', 'Character')

    Job.objects.filter(job_id='healer').update(job_name='ヒーラー')
    Character.objects.filter(key='lucia').update(role='ヒーラー')
    print('[migration 0147 BUG-139 reverse] Restored healer -> ヒーラー')


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0146_iap_receipt'),
    ]

    operations = [
        migrations.RunPython(_rename_healer_to_white_mage, _revert_rename),
    ]
