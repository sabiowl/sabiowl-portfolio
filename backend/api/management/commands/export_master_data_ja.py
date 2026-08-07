"""【FEAT-489】master data の日本語原文を翻訳作業用に export する。

`scripts/build_master_data_en.py` がこの出力を読み、**英訳だけを足して**
`doc/i18n/master_data_en.json` を組み立てる。原文を手で転記しないので、
`translate_master_data` の source 検証に転記ミスで落ちることがない。

使用例:
    python manage.py export_master_data_ja --output ../doc/i18n/_source_ja.json

## 🔴 どの DB に対して実行するか

**ローカルの開発 DB に対して実行してはいけない。**

開発 DB には admin 経由の手編集が溜まっている。実際 2026-08-03 時点で
`Character.beatrix` の名前が開発 DB では「セラ」、migration では「ベアトリス」
と食い違っており、開発 DB を元に翻訳を作ると **prod で全件 skip される**
(source 検証が正しく弾く) 状態だった。

正しい手順:

1. **prod のスナップショット** に対して実行する (最も確実)
2. それが難しければ **migration だけを適用した空 DB** に対して実行する
   (= `manage.py test` が作る DB と同じ状態)

いずれにせよ、投入時に `translate_master_data` が source を検証するので、
食い違ったまま prod に書き込まれることはない。
"""
import json
from pathlib import Path

from django.core.management.base import BaseCommand

from api.models import (
    Achievement, Challenge, Character, Enemy, GachaReward, Job,
    MaintenanceConfig, PuzzleWorldScene, SabiMessage, TaskSuggestion,
    WeaponMaster,
)


class Command(BaseCommand):
    help = 'Export Japanese master data as a translation work file'

    def add_arguments(self, parser):
        parser.add_argument(
            '--output',
            required=True,
            help='書き出し先の JSON パス',
        )

    def handle(self, *args, **options):
        data = {
            # pk 指定 (自然キーが無い model)。source 検証が取り違えを防ぐ。
            'SabiMessage': [
                {'id': m.pk, 'pool': m.pool, 'content': m.content}
                for m in SabiMessage.objects.order_by('pool', 'sort_order', 'id')
            ],
            'TaskSuggestion': [
                {'id': t.pk, 'title': t.title, 'hint': t.hint}
                for t in TaskSuggestion.objects.order_by('id')
            ],
            # 自然キー指定 (pk はローカルと prod でずれうる)
            'Enemy': [
                {'key': e.key, 'name': e.name}
                for e in Enemy.objects.order_by('key')
            ],
            'Character': [
                {
                    'key': c.key, 'name': c.name, 'role': c.role,
                    'tagline': c.tagline, 'description': c.description,
                }
                for c in Character.objects.order_by('key')
            ],
            # 【FEAT-516】自然キーを持つもの
            'Achievement': [
                {'key': a.key, 'name': a.name, 'description': a.description}
                for a in Achievement.objects.order_by('key')
            ],
            'Job': [
                {'job_id': j.job_id, 'description': j.description}
                for j in Job.objects.order_by('job_id')
            ],
            'WeaponMaster': [
                {'key': w.key, 'name': w.name, 'description': w.description}
                for w in WeaponMaster.objects.order_by('key')
            ],
            'PuzzleWorldScene': [
                {'key': p.key, 'name': p.name, 'tagline': p.tagline}
                for p in PuzzleWorldScene.objects.order_by('key')
            ],
            # 自然キーが無いので pk + source 検証で守る
            'GachaReward': [
                {'id': g.pk, 'ticket_type': g.ticket_type, 'rarity': g.rarity,
                 'name': g.name, 'detail': g.detail}
                for g in GachaReward.objects.order_by('ticket_type', 'rarity', 'id')
            ],
            # admin が運用中に作るため通常 0 行。行が増えたらここに出る。
            'Challenge': [
                {'id': c.pk, 'title': c.title, 'description': c.description}
                for c in Challenge.objects.order_by('id')
            ],
            'MaintenanceConfig': [
                {'id': m.pk, 'title': m.title, 'body': m.body}
                for m in MaintenanceConfig.objects.order_by('id')
            ],
        }

        dest = Path(options['output'])
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_text(
            json.dumps(data, ensure_ascii=False, indent=1), encoding='utf-8',
        )

        for model_name, rows in data.items():
            self.stdout.write(f'  {model_name}: {len(rows)} 行')
        self.stdout.write(self.style.SUCCESS(f'\n{dest} に書き出した。'))
