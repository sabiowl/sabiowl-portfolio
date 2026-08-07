"""
管理コマンド: python manage.py send_reminders

毎日決まった時間に cron / Celery beat で実行する想定。
実行すると：
  1. 当日まだ 1 回も記録されていないアクティブ習慣を持つプレイヤーへ
     「習慣リマインダー」通知を送信する（午前中のリマインド用）
  2. 3 日以上の streak を持ち、当日まだ達成していない習慣がある場合に
     「ストリーク危機」通知を送信する

⚠️ 【FEAT-284】現状この command は本番環境で動作していない:
  - Render Free tier は **Cron Jobs に非対応**（有料プラン昇格が必要）
  - 結果として `streak_alert` 通知種別は実装は存在するが配信されない状態
  - リリース前提として継続率向上の最強テコが機能していない問題は把握済み

将来の選択肢:
  - **Phase 2 (v1.1)**: Flutter local notif で代替実装（端末側で 21:00 に
    キャッシュ済 habits をチェックして自前で通知発火）。Render 課金不要、
    アンインストール / バックグラウンドキル時に失敗するが 90% 以上カバー
  - **代替案 B**: Render 有料プラン昇格で cron 復活（月額コスト発生）
  - **代替案 C**: 外部 cron サービス (cron-job.org 等) から本コマンドの
    エンドポイント版を叩く（外部依存）

本 command は **将来の Render 有料プラン昇格 / 外部 cron 連携時に再利用できる
ロジック資産**として残置している（FEAT-284 Phase 1 判断）。削除はしない。

使用例:
  # 開発環境（コンソール PUSH ログ）
  cd backend && python manage.py send_reminders

  # crontab（毎日 8:00 に実行、Render 有料プラン or 外部 cron 経由想定）
  0 8 * * * /path/to/venv/bin/python /path/to/manage.py send_reminders
"""

from datetime import date, datetime, timedelta

from django.core.management.base import BaseCommand
from django.db.models import Q

from api.models import Habit, HabitLog, Notification, PlayerProfile


class Command(BaseCommand):
    help = 'ストリーク危機・習慣リマインダー通知を送信する'

    def add_arguments(self, parser):
        parser.add_argument(
            '--dry-run',
            action='store_true',
            help='通知を作成せず、対象プレイヤー数だけ表示する',
        )
        parser.add_argument(
            '--streak-only',
            action='store_true',
            help='ストリーク危機通知のみ送信する',
        )
        parser.add_argument(
            '--reminder-only',
            action='store_true',
            help='習慣リマインダー通知のみ送信する',
        )

    def handle(self, *args, **options):
        dry_run      = options['dry_run']
        streak_only  = options['streak_only']
        reminder_only = options['reminder_only']
        today        = date.today()

        # 通知インポート（循環参照を避けるため遅延インポートしない — 同パッケージ内なのでOK）
        # 【FEAT-517】文面は api/i18n_messages.py が持つ (宛先の言語で組み立てる)。
        from api.services.push_service import (  # noqa: PLC0415
            create_localized_notification as _create_localized,
        )

        streak_count   = 0
        reminder_count = 0

        # 現在時刻（JST = UTC+9）を分数に変換
        now_jst = datetime.utcnow() + timedelta(hours=9)
        current_minutes = now_jst.hour * 60 + now_jst.minute  # 0〜1439 の分数

        # アクティブなプレイヤー（Userが紐付いていないゲストは除外）を対象
        # reminder_enabled=True かつ reminder_time が設定されているプレイヤーを取得し、
        # 各プレイヤーの reminder_time が現在時刻の ±30 分以内の場合のみ対象とする
        players_all = PlayerProfile.objects.filter(
            user__isnull=False,
            reminder_enabled=True,
            reminder_time__isnull=False,
        ).prefetch_related('habits')

        players = []
        for p in players_all:
            rt = p.reminder_time  # time オブジェクト
            player_minutes = rt.hour * 60 + rt.minute
            diff = abs(current_minutes - player_minutes)
            # 日をまたぐ場合（例: 23:45 と 00:15 の差が 1410 にならないよう）
            diff = min(diff, 1440 - diff)
            if diff <= 30:
                players.append(p)

        for player in players:
            active_habits = list(
                Habit.objects.filter(player=player, is_active=True, frequency='daily')
            )
            if not active_habits:
                continue

            # 本日達成済み habit の ID セット
            done_ids = set(
                HabitLog.objects.filter(
                    habit__in=active_habits,
                    date=today,
                    count__gte=1,
                ).values_list('habit_id', flat=True)
            )

            # ─── ストリーク危機 ──────────────────────────────────────
            if not reminder_only:
                at_risk = [
                    h for h in active_habits
                    if h.streak >= 3 and h.id not in done_ids
                ]
                if at_risk:
                    names = '、'.join(h.name for h in at_risk[:3])
                    if len(at_risk) > 3:
                        names += f' 他 {len(at_risk) - 3} 件'
                    self.stdout.write(
                        f'[streak_alert] {player.name}: {names}'
                    )
                    if not dry_run:
                        # 同日に同種の通知が既にあればスキップ
                        already = Notification.objects.filter(
                            player=player,
                            notif_type='streak_alert',
                            created_at__date=today,
                        ).exists()
                        if not already:
                            _create_localized(
                                player,
                                'streak_alert',
                                'streak_at_risk',
                                habit_names=names,
                            )
                            streak_count += 1

            # ─── 習慣リマインダー ────────────────────────────────────
            if not streak_only:
                undone = [h for h in active_habits if h.id not in done_ids]
                if undone:
                    names = '、'.join(h.name for h in undone[:3])
                    if len(undone) > 3:
                        names += f' 他 {len(undone) - 3} 件'
                    self.stdout.write(
                        f'[reminder] {player.name}: {names}'
                    )
                    if not dry_run:
                        already = Notification.objects.filter(
                            player=player,
                            notif_type='streak_alert',  # reminder は streak_alert と同種扱い
                            created_at__date=today,
                        ).exists()
                        if not already:
                            _create_localized(
                                player,
                                'streak_alert',
                                'daily_check',
                                habit_names=names,
                            )
                            reminder_count += 1

        if dry_run:
            self.stdout.write(self.style.WARNING('[DRY RUN] 通知は送信されませんでした'))
        else:
            self.stdout.write(
                self.style.SUCCESS(
                    f'完了: ストリーク危機={streak_count}件 / リマインダー={reminder_count}件'
                )
            )
