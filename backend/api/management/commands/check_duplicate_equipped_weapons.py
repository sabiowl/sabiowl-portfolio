"""【FEAT-538 Phase 2 (2026-08-29)】`is_equipped=True` が 2 本以上ある player を検出する。

## なぜ migration ではなくコマンドなのか

CLAUDE.md「破壊的データマイグレーション禁止 (FEAT-250)」。`RunPython` の中で
既存データを書き換えると、**デプロイのたびに勝手に走り、実行記録も残らない**。
収束は運営が実行タイミングを選べる management command として置く。

## 既定は検出のみ

`--fix` を付けたときだけ書き換える。運営が意図して 2 本にしている可能性が
あり、それをコマンドが勝手に潰すのは事故（Pre-mortem #4）。

**まず `--fix` なしで prod に対して実行し、件数を記録すること。**
その結果が 0 件のときに限り、部分ユニーク制約（Phase 5）を入れられる。
1 件でも残っていると `AddConstraint` が失敗し、`build.sh` の migrate が
止まって**デプロイ不能**になる。

## `--fix` が残すのは「最新 acquired_at」

直近に配ったものが運営の意図である可能性が高いため。収束処理そのものは
`services/weapon_equip.equip_exclusively` を呼ぶ —— ここで独自に
`update(is_equipped=False)` を書くと、admin / view と並ぶ 3 つ目の真実値に
なる。
"""

from django.core.management.base import BaseCommand
from django.db.models import Count

from api.models import PlayerWeapon
from api.services.weapon_equip import equip_exclusively


class Command(BaseCommand):
    help = (
        'is_equipped=True の武器を 2 本以上持つプレイヤーを検出する。'
        '--fix を付けると最新 acquired_at の 1 本に収束させる。'
    )

    def add_arguments(self, parser):
        parser.add_argument(
            '--fix',
            action='store_true',
            help=(
                '検出だけでなく収束させる（最新 acquired_at を残して他を外す）。'
                '既定は検出のみ。'
            ),
        )

    def handle(self, *args, **options):
        fix = options['fix']

        duplicated_player_ids = list(
            PlayerWeapon.objects
            .filter(is_equipped=True)
            .values('player_id')
            .annotate(equipped_count=Count('id'))
            .filter(equipped_count__gt=1)
            .order_by('player_id')
            .values_list('player_id', flat=True)
        )

        if not duplicated_player_ids:
            self.stdout.write(self.style.SUCCESS(
                '重複なし: 0 件（is_equipped=True が 2 本以上のプレイヤーはいません）'
            ))
            return

        self.stdout.write(self.style.WARNING(
            f'重複あり: {len(duplicated_player_ids)} 件'
        ))

        for player_id in duplicated_player_ids:
            equipped = list(
                PlayerWeapon.objects
                .filter(player_id=player_id, is_equipped=True)
                .select_related('player', 'weapon')
                # 最新を先頭に。--fix はこの先頭を残す。
                .order_by('-acquired_at', '-pk')
            )
            player = equipped[0].player
            self.stdout.write(
                f'player_id={player_id} 「{player.name}」 '
                f'装備 {len(equipped)} 本'
            )
            for index, pw in enumerate(equipped):
                mark = '[残す]' if index == 0 else '[外す]'
                self.stdout.write(
                    f'  {mark} PlayerWeapon id={pw.pk} '
                    f'{pw.weapon.name} (acquired_at={pw.acquired_at:%Y-%m-%d %H:%M})'
                )

            if fix:
                demoted = equip_exclusively(player, equipped[0])
                self.stdout.write(self.style.SUCCESS(
                    f'  → 「{equipped[0].weapon.name}」1 本に収束'
                    f'（{len(demoted)} 本を外した）'
                ))

        if not fix:
            self.stdout.write(
                '検出のみ実行しました。収束させるには --fix を付けてください。'
            )
