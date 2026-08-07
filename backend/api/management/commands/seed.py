"""
python manage.py seed

初期データを投入するmanagementコマンド。
既存データがある場合は上書きしない（idempotent）。
--reset オプションで全データを削除してから再投入する。
"""
from django.core.management.base import BaseCommand
from api.models import PlayerProfile, CharacterStat, Habit


STAT_NAMES = ['運動力', '学習力', '精神力', '健康力']

SAMPLE_HABITS = [
    # 毎日
    {'name': '朝のストレッチ',       'category': '運動',    'frequency': 'daily',   'order': 0},
    {'name': '読書30分',             'category': '学習',    'frequency': 'daily',   'order': 1},
    {'name': '水を2L飲む',           'category': '健康',    'frequency': 'daily',   'order': 2},
    # 毎週
    {'name': '週次レビュー',         'category': '学習',    'frequency': 'weekly',  'order': 3},
    {'name': '部屋の掃除',           'category': '健康',    'frequency': 'weekly',  'order': 4},
    # 毎月
    {'name': '月次目標の振り返り',   'category': 'メンタル', 'frequency': 'monthly', 'order': 5},
]


class Command(BaseCommand):
    help = '初期データを投入します（PlayerProfile / CharacterStat / Habit）'

    def add_arguments(self, parser):
        parser.add_argument(
            '--reset',
            action='store_true',
            help='既存データをすべて削除してから再投入する',
        )

    def handle(self, *args, **options):
        if options['reset']:
            self.stdout.write('既存データを削除しています...')
            Habit.objects.all().delete()
            CharacterStat.objects.all().delete()
            PlayerProfile.objects.all().delete()
            self.stdout.write(self.style.WARNING('  → 削除完了'))

        # ── PlayerProfile ──────────────────────────
        player, created = PlayerProfile.objects.get_or_create(
            id=1,
            defaults={
                'name': '勇者',
                'level': 1,
                'current_exp': 0,
                'max_exp': 100,
                'allocatable_points': 0,
                'gender': 'f',
            },
        )
        if created:
            self.stdout.write(self.style.SUCCESS(f'  ✔ PlayerProfile 作成: {player}'))
        else:
            self.stdout.write(f'  ℹ PlayerProfile 既存: {player}')

        # ── CharacterStat (4種) ────────────────────
        for stat_name in STAT_NAMES:
            stat, created = CharacterStat.objects.get_or_create(
                player=player,
                name=stat_name,
                defaults={
                    'level': 1,
                    'current_exp': 0,
                    'max_exp': 100,
                },
            )
            status = '✔ 作成' if created else 'ℹ 既存'
            self.stdout.write(
                (self.style.SUCCESS if created else str)(f'  {status}: CharacterStat - {stat_name}')
            )

        # ── Habit (サンプル6件) ────────────────────
        for habit_data in SAMPLE_HABITS:
            habit, created = Habit.objects.get_or_create(
                player=player,
                name=habit_data['name'],
                defaults={
                    'category':  habit_data['category'],
                    'frequency': habit_data['frequency'],
                    'order':     habit_data['order'],
                },
            )
            status = '✔ 作成' if created else 'ℹ 既存'
            self.stdout.write(
                (self.style.SUCCESS if created else str)(
                    f'  {status}: Habit - {habit.name} ({habit.category} / {habit_data["frequency"]})'
                )
            )

        self.stdout.write('')
        self.stdout.write(self.style.SUCCESS('✅ seed 完了！'))
        self.stdout.write('   http://127.0.0.1:8000/api/health/ でサーバーの動作を確認できます。')
