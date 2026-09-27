import logging
import os

import requests

from rest_framework import status
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response
from rest_framework.views import APIView

from ..permissions import IsAuthenticatedOrGuest  # FEAT-187

from django.db import transaction
from django.utils import timezone  # P0-02: TZ-aware な日付取得（JST 基準）

from ..models import (
    AccountDeletionFeedback, CharacterStat,
    DELETION_REASON_CHOICES, PlayerProfile,
    PlayerWeapon, WeaponMaster,  # 【FEAT-326】EquipWeaponView 用
    SocialAccount,  # 【FEAT-245】Firebase Auth 削除のため uid 取得用
)
from ..serializers import (
    CharacterStatSerializer,
    PlayerProfileSerializer,
    get_i18n_field,  # 【BUG-146 Phase 2】master data の _en を読む
)
from ..services.daily_throttle_service import (
    reset_battle_charges_if_new_day,
    reset_daily_battle_count_if_new_day,
)
# 【FEAT-538 (2026-08-29)】「1 人 1 装備」の手続きは services/weapon_equip.py が
# 単一真実値。admin (PlayerWeaponAdmin.save_model) も同じ関数を呼ぶ。
from ..services.weapon_equip import equip_exclusively
from ..views.sabi import today_summary
from ..views.shop import compute_coins
from ._error_helpers import error_response  # 【FEAT-475 Phase 3c】新形式統一
from .mixins import PlayerMixin

# 【廃止 (2026-06-26)】 旧 `current_title()` helper + `TITLES` import は撤去。
# 称号 6 段階システムを実績 30 件に統合したため不要。constants.py の TITLES
# 定数も同時撤去済 (本ファイル冒頭にコメント記録あり)。

_logger = logging.getLogger(__name__)


# ── FEAT-200 + 【FEAT-245 hotfix】: PostHog Identity Deletion (2-step) ──────
# アカウント削除時に PostHog 側のユーザーデータも削除する（GDPR/プライバシーポリシー対応）。
#
# 環境変数:
#   POSTHOG_PERSONAL_API_KEY: PostHog Personal API Key（Render ダッシュボードで手動設定）
#     - Scope: `person:write` 必須（Write は Read を包含するため Step 1 の GET も同キーで可）
#     - **Organization & project access** に対象プロジェクトを明示許可（or `All` 指定）
#       が必須。新 Scoped Personal API Keys は default で空 = どのプロジェクトにも触れない仕様。
#   POSTHOG_PROJECT_ID:       PostHog Project ID（数値）
#   POSTHOG_HOST:             https://us.i.posthog.com（FEAT-200 で US リージョン採用）
# キー未設定時は no-op（ローカル開発・テスト環境でも動作に支障なし）。
#
# 【FEAT-245 hotfix 2026-05-20】Personal API Key で叩けるエンドポイントが限定される
# ことが実機検証で判明。`DELETE /persons/?distinct_id=X` のバルク削除エンドポイント
# は OAuth/session 認証専用で Personal API Key 非対応（scope に関わらず 403
# permission_denied "This action does not support personal API key access"）。
# 正しいパターンは GET で numeric person_id を解決 → DELETE で ID 指定削除の 2-step。
def _delete_posthog_identity(player_id: int) -> None:
    """PostHog 側のユーザーデータを削除する（best-effort、2-step）。

    PostHog の Personal API Key は bulk-delete-by-distinct_id エンドポイントを
    叩けない（OAuth/session 専用）ため、以下 2-step で削除する:
      1. GET /api/projects/<id>/persons/?distinct_id=X で numeric person_id を解決
      2. DELETE /api/projects/<id>/persons/<id>/?delete_events=true で人 + イベントを削除

    必要な Personal API Key scope: `person:write`（Write は Read を包含するため、
    GET lookup も同キーで可能）。加えて Key の **Organization & project access**
    設定で対象プロジェクトを許可している必要がある（PostHog 新 UI 仕様、デフォルト
    では空のためアクセス権なし）。
    失敗してもアカウント削除処理自体は継続する（既にユーザーは消えており、
    PostHog 側に残った匿名イベントログは時間経過で価値が下がるため）。
    """
    api_key    = os.environ.get('POSTHOG_PERSONAL_API_KEY', '').strip()
    project_id = os.environ.get('POSTHOG_PROJECT_ID', '').strip()
    host       = os.environ.get('POSTHOG_HOST', 'https://us.i.posthog.com').rstrip('/')

    if not (api_key and project_id):
        # 未設定（ローカル開発時など）は完全に no-op
        return

    distinct_id = f'player_{player_id}'
    headers     = {'Authorization': f'Bearer {api_key}'}

    # 【FEAT-245 hotfix 観測性】Render の Django デフォルト LOGGING は WARNING 以上のみ
    # 表示されるため、`_logger.info(...)` は production で見えない（settings.py に LOGGING
    # 設定なし → root logger = WARNING）。実機ロールアウト中の動作確認のため、各経路の
    # 結果ログをすべて WARNING で出す（success / not_found / error すべて可視化）。
    # 将来ノイズが気になる場合は LOGGING 設定で `api` logger を INFO に上げて、これらを
    # `_logger.info(...)` に戻す方が semantic 的にきれい。

    # ── Step 1: distinct_id → 内部 numeric person_id を解決（person:read）──
    try:
        list_res = requests.get(
            f'{host}/api/projects/{project_id}/persons/',
            params={'distinct_id': distinct_id},
            headers=headers,
            timeout=10,
        )
        if list_res.status_code != 200:
            _logger.warning(
                'PostHog person lookup returned %s for %s: %s',
                list_res.status_code, distinct_id, list_res.text[:200],
            )
            return
        results = list_res.json().get('results', [])
        if not results:
            # 該当 person なし（既に削除済み or 一度も capture されていない）。
            # 観測性のため WARNING で出す（本来 INFO 相当だが Render Logs で見えるように）。
            _logger.warning('PostHog person not found for %s, skip delete', distinct_id)
            return
        person_id = results[0]['id']
    except requests.RequestException as exc:
        _logger.warning('PostHog lookup error for %s: %s', distinct_id, exc)
        return
    except (KeyError, ValueError, TypeError) as exc:
        # JSON 構造が想定外の場合も best-effort で諦める
        _logger.warning('PostHog response parse error for %s: %s', distinct_id, exc)
        return

    # ── Step 2: numeric person_id 指定で削除 + イベントも一括削除（person:write）──
    try:
        del_res = requests.delete(
            f'{host}/api/projects/{project_id}/persons/{person_id}/',
            params={'delete_events': 'true'},
            headers=headers,
            timeout=10,
        )
        if del_res.status_code >= 400:
            _logger.warning(
                'PostHog deletion returned %s for player_%s (person_id=%s): %s',
                del_res.status_code, player_id, person_id, del_res.text[:200],
            )
        else:
            # 成功経路の観測性確保（200/204 = 削除成功）。Render Logs で見えるように WARNING。
            _logger.warning(
                'PostHog deletion succeeded for player_%s (person_id=%s, status=%s)',
                player_id, person_id, del_res.status_code,
            )
    except requests.RequestException as exc:
        _logger.warning('PostHog delete error for player_%s: %s', player_id, exc)


# ── 【FEAT-245】Firebase Auth Identity Deletion ─────────────────────────────
# アカウント削除時に Firebase Auth 側のユーザーレコード（uid / email /
# display_name / 最終ログイン履歴等）も削除する。プライバシーポリシー上の
# 「全データ削除」担保 + ストア審査要件（iOS/Android のアカウント削除要件）対応。
#
# Firebase Admin SDK が初期化されていない（FIREBASE_SERVICE_ACCOUNT_JSON 未設定の
# ローカル開発環境等）は warning のみで完了させる best-effort 設計。
def _delete_firebase_users(uids: list[str]) -> None:
    """Firebase Auth から uid 群を一括削除する（best-effort）。

    Sabiowl の `request.user.delete()` で SocialAccount は CASCADE 削除されるが、
    Firebase Auth 側のユーザーレコード（uid / email / display_name / 最終ログイン等）
    は明示的に削除しないと残置する。プライバシーポリシー上「全データ削除」を
    担保するため、Sabiowl アカウント削除と同期して Firebase 側も削除する。

    失敗してもアカウント削除処理自体は完了させる（既に Django 側ユーザーは
    消えており、Firebase 側に残った匿名 uid は再ログイン時に新規 SocialAccount
    として整合する。FEAT-178 + BUG-67 の構造に依存）。
    """
    if not uids:
        _logger.warning('Firebase deletion skipped (no SocialAccount uids)')
        return
    try:
        import firebase_admin.auth as _fb_auth
        # batch API は最大 1000 件 / 呼び出し。Sabiowl は 1 ユーザー 1 プロバイダ制約
        # （FEAT-178）なので通常 1〜2 件しか入らないが、API 一貫性のため batch を使用。
        result = _fb_auth.delete_users(uids)
        if result.failure_count:
            _logger.warning(
                'Firebase delete partial failure: %s/%s failed for uids=%s errors=%s',
                result.failure_count, len(uids), uids,
                [(e.index, e.reason) for e in result.errors],
            )
        else:
            # 成功経路の観測性確保（FEAT-245 hotfix）。Render Logs で見えるように WARNING。
            _logger.warning(
                'Firebase deletion succeeded for %s uid(s): %s',
                result.success_count, uids,
            )
    except Exception as exc:
        # ネットワーク・SDK 初期化失敗等は warning のみ。
        # アカウント削除自体は完了させる。
        _logger.warning('Firebase deletion failed for uids=%s: %s', uids, exc)


class PlayerProfileView(PlayerMixin, APIView):
    permission_classes = [IsAuthenticatedOrGuest]

    # H-05: mode は EXP +20% ボーナス判定で参照されるため choices 検証必須
    _VALID_MODES   = ('training', 'adventure')
    _FCM_TOKEN_MAX = 400  # 一般的な FCM token は ~163 文字、余裕を持って 400 上限

    def get(self, request):
        player = self.get_player(request)
        # 【BUG-122 (2026-06-14)】日次ログインボーナスを「ログイン trigger」から
        # 「その日初回タスク達成 trigger」に移行 (BUG-120 を置換)。
        # 本 view では bonus の付与はしない (habit_count_service / TimelineCompleteView /
        # ChecklistItemToggleView で award_daily_first_task_bonus が呼ばれる)。
        from django.utils import timezone
        today = timezone.localdate()

        # 【BUG-78】日付変更後、Flutter の BattleAvailability が stale な 10/10 を
        # 見て出陣ボタンを無効化し続ける問題を防ぐ。player fetch はアプリ起動・
        # refresh の主要 read path のため、ここで DB 状態も JST 当日に同期する。
        # 【BUG-118 (2026-06-14)】FEAT-406 で導入した battle_charges 日次リセットが
        # write path (habit_count / battle / timeline) のみで実行されており、read
        # path 未対応のため翌日に古い charges 数が表示され続けてユーザーがクエスト
        # 参加不能になる問題を解消。daily_battle_count と同じパターンで read path にも
        # 追加。
        # 【FEAT-478 Phase 2b (2026-07-04)】reset_*_if_new_day 関数は内部で
        # player.battle (PlayerBattleState) を save 済のため、外側の
        # player.save(update_fields=[...]) は不要 (home.py と同一の理由)。
        with transaction.atomic():
            player = PlayerProfile.objects.select_for_update().get(pk=player.pk)
            reset_daily_battle_count_if_new_day(player)
            reset_battle_charges_if_new_day(player)

        # BUG-2026-0512-01: `gacha_tickets` は PlayerProfileSerializer の
        # SerializerMethodField に組み込み済み（HomeBootstrap / HabitCount でも自動付与される）。
        # ここでは追加注入は不要。
        data = PlayerProfileSerializer(player, context={"request": request}).data
        data['today_summary'] = today_summary(player)
        data['coins'] = compute_coins(player)
        return Response(data)

    def patch(self, request):
        player = self.get_player(request)
        allowed = {k: v for k, v in request.data.items() if k in (
            'name', 'gender', 'fcm_token', 'reminder_enabled', 'reminder_time', 'mode',
            # 【FEAT-257】Settings 画面の Google カレンダー push トグル
            'gcal_push_enabled',
            # 【FEAT-273】タイムライン予定の +15 分未完了リマインダー（Settings で更新可能）
            'timeline_uncompleted_reminder_enabled',
            # 【FEAT-377】ストリーク自動保護 ON/OFF トグル（Settings で更新可能）
            'streak_protection_auto_enabled',
            # 【FEAT-493 (2026-07-25 hotfix)】フリーメモ機能 opt-in トグル
            # (Settings β 機能セクションで更新可能)。allowed 未追記により
            # PATCH が silent 無視され、Flutter の optimistic UI が 2 秒後に
            # OFF に戻る不具合を修正。
            'free_memo_enabled',
        )}

        # H-05: mode は choices 検証（不正値で adventure ボーナス判定が誤動作するのを防ぐ）
        if 'mode' in allowed and allowed['mode'] not in self._VALID_MODES:
            return error_response(
                       code='player_update_invalid_mode',
                       message=f"mode は {self._VALID_MODES} のいずれかを指定してください",
                       status=status.HTTP_400_BAD_REQUEST,
                   )
        # fcm_token は長さ制限（DoS による DB 容量浪費を防ぐ）
        if 'fcm_token' in allowed and len(str(allowed['fcm_token'])) > self._FCM_TOKEN_MAX:
            return error_response(
                       code='player_update_fcm_token_too_long',
                       message='fcm_token が長すぎます',
                       status=status.HTTP_400_BAD_REQUEST,
                   )

        serializer = PlayerProfileSerializer(player, data=allowed, partial=True)
        if serializer.is_valid():
            serializer.save()
            # 【FEAT-420 Pre-mortem S2】自動保護を ON にしたら pending 予約は強制クリア
            # (二重消費防止: 自動経路が優先のため、予約は無効化する)
            if allowed.get('streak_protection_auto_enabled') is True:
                _eco = player.economy
                if _eco.streak_protection_pending:
                    _eco.streak_protection_pending = False
                    _eco.save(update_fields=['streak_protection_pending'])
                    serializer = PlayerProfileSerializer(player, context={"request": request})
            return Response(serializer.data)
        return Response(serializer.errors, status=status.HTTP_400_BAD_REQUEST)

    def delete(self, request):
        """アカウント削除（理由フィードバックを保存してからユーザーごと削除）。

        【BUG-128 (2026-06-14)】ゲストモードでも削除可能に変更 (旧 FEAT-187 で 403 拒否)。
        permission_classes=[IsAuthenticatedOrGuest] で endpoint は到達可能、PlayerMixin.
        get_player もゲスト対応済、GuestSession.player_profile=OneToOneField(CASCADE) +
        Habit/Timeline/GachaStatus 等の FK 構造で player.delete() による全 CASCADE
        清掃が機能する。認証済 (linked account) は従来通り request.user.delete()、
        ゲストは player.delete() に分岐。Firebase Auth 削除はソーシャル UID 経由のため
        ゲスト時は no-op (provider_uids 空)、PostHog Identity 削除は player_id ベースで
        両モード共通。
        """
        player      = self.get_player(request)
        # 【BUG-128】ゲスト判定: is_guest=True なら user 不在、PlayerProfile を直接削除
        is_guest    = not (request.user and request.user.is_authenticated)
        reason      = request.data.get('reason', '')
        # SEC-09 / M-01: AccountDeletionFeedback は退会理由統計用に **恒久保存**
        # される（player_id は FK ではない IntegerField のため CASCADE 削除対象外）。
        # 攻撃者が巨大な reason_text（数 MB〜）を添付して連続退会リクエストを送ると
        # DB 容量を圧迫する累積的 DoS 経路があるため、サーバー側で 1000 文字に切り詰める。
        # 退会理由のフリーテキストとして 1000 文字あれば十分（Twitter 280 文字、
        # Instagram bio 150 文字との比較からも余裕がある）。
        reason_text = (request.data.get('reason_text', '') or '')[:1000]
        # 念のため app_version も切り詰め（モデル側 max_length=20 と整合）。
        app_version = (request.data.get('app_version', '') or '')[:20]

        valid_reasons = [r[0] for r in DELETION_REASON_CHOICES]
        if reason not in valid_reasons:
            return error_response(code='player_delete_missing_reason', message='削除理由を選択してください 🪶', fields={'delete_reason': '削除理由は必須です'})

        # FEAT-200: PostHog 側のデータも削除するため、player.id をトランザクション前に控える
        # （request.user.delete() 後は player オブジェクトが detach されるため）。
        deleted_player_id = player.id

        # 【FEAT-245】Firebase Auth ユーザー削除のため、削除前に provider_uid を控える。
        # `request.user.delete()` 後は SocialAccount も CASCADE で消えるため取得不能。
        # 通常は 1 件（FEAT-178 で 1 ユーザー 1 プロバイダ制約）だが、過去のデータ
        # 移行残骸等で複数あっても batch API で一括削除する。
        # 【BUG-128】ゲストモードは user 不在 → SocialAccount もないため空 list。
        if is_guest:
            firebase_uids = []
        else:
            firebase_uids = list(
                SocialAccount.objects.filter(user=request.user)
                .values_list('provider_uid', flat=True)
            )

        # P0-03: フィードバック保存と user/player の削除を同一トランザクションに統合する。
        # 旧実装は両者が別トランザクションだったため:
        # - フィードバック作成成功 → user.delete() 失敗 → ユーザーには「削除完了」表示
        #   なのにアカウントが残留しフィードバックだけ存在する不整合
        # - DB 接続切断中の中途失敗で部分適用
        # AccountDeletionFeedback.player_id は IntegerField（FK ではない）のため
        # user.delete() / player.delete() の CASCADE 連鎖削除対象にならず、削除後も統計用に残る。
        with transaction.atomic():
            AccountDeletionFeedback.objects.create(
                player_id=deleted_player_id,
                player_level=player.battle.level,
                reason=reason,
                reason_text=reason_text,
                app_version=app_version,
            )
            # 【BUG-128 (2026-06-14)】認証経路で削除対象を分岐:
            # - 認証済: request.user.delete() で User CASCADE
            #   → PlayerProfile, SocialAccount, Token, GuestSession 等を清掃
            # - ゲスト: player.delete() で PlayerProfile CASCADE
            #   → GuestSession (OneToOneField CASCADE), Habit, Timeline, GachaStatus,
            #     OwnedCharacter, PlayerItem, Friendship 等を清掃 (User は不在)
            if is_guest:
                player.delete()
            else:
                request.user.delete()

        # 【FEAT-245】Firebase Auth ユーザーも削除（best-effort）。
        # 失敗してもユーザー側削除処理（Django CASCADE）は完了済みなので 204 を返す。
        # トランザクション外で実行することで、Firebase API の遅延・失敗が DB
        # ロールバックを引き起こさないようにする。
        # ヘルパー内部の try/except で通常は捕捉されるが、import 失敗等の極端な
        # ケースに備えて defense-in-depth で view 側にも try/except を置く。
        # PostHog 側も同様に独立して呼び出し、片方が失敗しても他方は続行する。
        try:
            _delete_firebase_users(firebase_uids)
        except Exception as exc:
            _logger.warning(
                'Firebase deletion helper raised for player_%s: %s',
                deleted_player_id, exc,
            )

        # FEAT-200: PostHog 側のユーザーデータも削除する（best-effort）。
        # 失敗してもユーザー側削除処理は完了済みなので 204 は返す。
        try:
            _delete_posthog_identity(deleted_player_id)
        except Exception as exc:
            _logger.warning(
                'PostHog deletion helper raised for player_%s: %s',
                deleted_player_id, exc,
            )

        return Response(status=204)


# 【FEAT-407 (2026-06-01)】ResetSettingsView 削除: Flutter caller ゼロ確認済。
# FEAT-396 で Flutter の公開設定 UI が撤廃されたため Backend API も不要。
# grep -rn "reset-settings|ResetSettings" mobile/lib → ゼロ件 (2026-06-01 確認)

class PlayerStatsView(PlayerMixin, APIView):
    permission_classes = [IsAuthenticatedOrGuest]
    # 【FEAT-233】6 値拡張 + 順序統一（健康 ⇄ 精神を入れ替え）。
    # ユーザー要望「上から運動力 → 学習力 → 健康力 → 精神力 → 創造力 → 貢献力」と整合。
    # 創造力 / 貢献力が `_STAT_ORDER` に含まれない時代は `else 999` で末尾不定だった
    # （割り振り後の並び順が変わる現象の主因）。本修正で順序を完全固定。
    # 機能レビュー 20260518 P3-2（BUG-66 STAT_NAMES 順序統一）を本 FEAT で吸収。
    _STAT_ORDER = ['運動力', '学習力', '健康力', '精神力', '創造力', '貢献力']

    def get(self, request):
        player = self.get_player(request)
        stat_list = list(CharacterStat.objects.filter(player=player))
        stat_list.sort(
            key=lambda s: self._STAT_ORDER.index(s.name)
            if s.name in self._STAT_ORDER else 999
        )
        return Response(CharacterStatSerializer(stat_list, many=True).data)


class StatAllocateView(PlayerMixin, APIView):
    permission_classes = [IsAuthenticatedOrGuest]

    def post(self, request, pk):
        player = self.get_player(request)

        try:
            stat = CharacterStat.objects.get(pk=pk, player=player)
        except CharacterStat.DoesNotExist:
            return Response({'detail': 'Not found.'}, status=status.HTTP_404_NOT_FOUND)

        with transaction.atomic():
            player = PlayerProfile.objects.select_for_update().get(pk=player.pk)
            locked_battle = player.battle

            if locked_battle.allocatable_points <= 0:
                return error_response(
                           code='player_allocate_no_points',
                           message='割り振れるポイントがありません',
                           status=status.HTTP_400_BAD_REQUEST,
                       )

            locked_battle.allocatable_points -= 1
            locked_battle.save(update_fields=['allocatable_points'])

            # stat も同一トランザクション内で再取得してから更新（競合防止）
            stat = CharacterStat.objects.select_for_update().get(pk=stat.pk)
            stat.current_exp += 10
            # BUG-M: 旧実装は `current_exp = 0` で余剰 EXP を破棄していた（HabitCountView の
            # `_auto_allocate_by_ratio` の while + -= max_exp と非対称）。
            # current_exp が max_exp の数倍に跳ねる経路は無いが、整合のため while + 減算で繰越し。
            # 【2026-07-09 レビュー §5 P3】max_exp *= 1.2 の直書きを撲滅、共有 helper 経由に統一。
            from ..services.exp_service import _award_crystal_on_stat_level_up, apply_stat_level_up_step
            crystals_awarded_alloc: dict = {}
            while stat.current_exp >= stat.max_exp:
                # 【2026-07-09 レビュー §5 P3】habits.py と共通の真実値
                # (exp_service.STAT_LEVEL_UP_MULTIPLIER) 経由で Lv UP を反映。
                apply_stat_level_up_step(stat)
                # 【FEAT-379】手動配分経路でも結晶付与 (PlayerProfile は上で select_for_update 済)
                crystal_key = _award_crystal_on_stat_level_up(stat, player)
                if crystal_key:
                    crystals_awarded_alloc[crystal_key] = \
                        crystals_awarded_alloc.get(crystal_key, 0) + 1
            stat.save(update_fields=['level', 'current_exp', 'max_exp'])

        return Response({
            'stat':               CharacterStatSerializer(stat).data,
            'allocatable_points': locked_battle.allocatable_points,
            # 【FEAT-379】今回付与した結晶 (stat Lv UP 時のみ非空)
            'crystals_awarded':   crystals_awarded_alloc,
        })


# 【廃止 (2026-06-26)】 旧 `TitlesView` (GET /api/player/titles/) は撤去。
# 称号 6 段階システムを実績 30 件に統合したため不要。Mobile の TitlesPage /
# fetchTitles() / Title・TitlesData モデルも同時撤去済。


# ────────────────────────────────────────────────────────────────
# 【FEAT-304】ActiveJobUpdateView — PartyEditDialog からのジョブ切替
# ────────────────────────────────────────────────────────────────

class ActiveJobUpdateView(PlayerMixin, APIView):
    """`PATCH /api/player/active-job/` — 【FEAT-430 (2026-06-12)】v1.0 で deactivate。

    【背景】v1.0 では「キャラ = ジョブ」を固定 (active_character.job のみを真実値に)。
    v1.1+ で熟練度システム (doc/design/job_mastery_v1_1.md) が実装されたら、
    熟練度 Max ジョブの「上書き」用にこの endpoint を再活性化する予定。

    現在: 410 Gone を返す。endpoint 自体は urls.py に残し、v1.1+ で復活させる。
    """
    permission_classes = [IsAuthenticatedOrGuest]

    def patch(self, request):
        return error_response(
            code='player_active_job_feature_deactivated',
            message='ジョブはキャラと共に決まりますよ。熟練度システムは v1.1+ でご用意します 🪶',
            status=status.HTTP_410_GONE,
        )


class PlayerWeaponsView(PlayerMixin, APIView):
    """【FEAT-327 Fix-1】 `GET /api/player/weapons/` — プレイヤー所持武器の全件取得。

    EquipmentSelectionOverlay (FEAT-327 §2.1 guild_equipment_2.md §1.2 仕様準拠 widget)
    が「現在装備中 + 所持武器一覧」を独立表示するための endpoint。Shop 経由ではなく
    `PlayerWeapon` から直接所持武器を取得することで、ガチャ排出武器 (mythril/dragon_slayer)
    の `WeaponMaster.id` も解決可能になる (FEAT-326 残課題の解消)。

    レスポンス例:
      ```
      {
        "weapons": [
          {
            "id": 1, "key": "starter_sword", "name": "見習いの剣",
            "atk_bonus": 10, "description": "...",
            "is_equipped": true, "acquired_at": "2026-05-27T03:30:00Z"
          },
          ...
        ]
      }
      ```

    認証 (Pre-mortem #4): `IsAuthenticatedOrGuest` でゲスト経由でも装備一覧取得可能。
    PlayerMixin.get_player() がゲスト/通常ユーザー両対応。
    """
    permission_classes = [IsAuthenticatedOrGuest]

    def get(self, request):
        player = self.get_player(request)
        # 【BUG-146 Phase 2】locale の解決は view ごとに 1 行だけ (Pre-mortem #4)。
        locale = getattr(request, 'locale', 'ja')
        weapons = (
            PlayerWeapon.objects
            .filter(player=player)
            .select_related('weapon')
            .order_by('acquired_at')
        )
        return Response({
            'weapons': [
                {
                    'id':                    pw.weapon.id,
                    'key':                   pw.weapon.key,
                    # 【BUG-146 Phase 2】WeaponMaster は master data (_en 投入済)。
                    'name':                  get_i18n_field(pw.weapon, 'name', locale),
                    'atk_bonus':             pw.weapon.atk_bonus,
                    'description':           get_i18n_field(pw.weapon, 'description', locale),
                    'is_equipped':           pw.is_equipped,
                    'acquired_at':           pw.acquired_at.isoformat(),
                    # 【FEAT-379】ソケット情報 (v1.0 は表示のみ、装着は v1.1+)
                    'socket_count':          pw.weapon.socket_count,
                    'socket_1_crystal_type': pw.socket_1_crystal_type,
                    'socket_2_crystal_type': pw.socket_2_crystal_type,
                    'socket_3_crystal_type': pw.socket_3_crystal_type,
                }
                for pw in weapons
            ],
        })


class EquipWeaponView(PlayerMixin, APIView):
    """【FEAT-326】 `PATCH /api/player/equip-weapon/`

    PartyEditDialog の装備変更 BottomSheet からタップ → 装備中の武器を即時切替。
    Optimistic UI 想定で成功時は即時 200。`PlayerWeapon.is_equipped` のフラグを
    更新するため、内部で `PlayerProfile → PlayerWeapon` 順 (FK 昇順) で
    `select_for_update` ロックを取得し UniqueConstraint 違反を構造的に防ぐ。

    リクエストボディ:
      ```
      { "weapon_id": 3 }  // WeaponMaster.id (PlayerWeapon.weapon_id ではない)
      ```

    レスポンス (成功):
      ```
      {
        "equipped_weapon": {
          "id": 3, "key": "iron_sword", "name": "鉄の剣", "atk_bonus": 10,
        }
      }
      ```

    エラー:
      - 400 weapon_id 欠落 / 不正型
      - 404 該当 PlayerWeapon が存在しない (所持していない武器を装備しようとした)

    関連 Pre-mortem (FEAT-326 §3):
      #1 同時実行 UniqueConstraint 違反 → 本 view では新規 PlayerWeapon 作成しない
         (Shop/Gacha 経路で作成済前提)、is_equipped フラグ更新のみで race 無し
      #4 dispose race → caller (Flutter) で showModalBottomSheet 経由、本 view は
         単純 API なので navigation race を作らない
    """
    permission_classes = [IsAuthenticatedOrGuest]

    def patch(self, request):
        weapon_id = request.data.get('weapon_id')
        if weapon_id is None:
            return error_response(
                       code='weapon_id_required',
                       message='weapon_id が必要です 🪶',
                       status=status.HTTP_400_BAD_REQUEST,
                   )
        try:
            weapon_id = int(weapon_id)
        except (TypeError, ValueError):
            return error_response(
                       code='weapon_id_invalid',
                       message='weapon_id は整数で指定してください 🪶',
                       status=status.HTTP_400_BAD_REQUEST,
                   )

        player = self.get_player(request)
        with transaction.atomic():
            player = PlayerProfile.objects.select_for_update().get(pk=player.pk)

            target = (
                PlayerWeapon.objects
                .select_for_update()
                .filter(player=player, weapon_id=weapon_id)
                .select_related('weapon')
                .first()
            )
            if target is None:
                return error_response(
                           code='weapon_not_owned',
                           message='所持していない武器のようです 🪶',
                           status=status.HTTP_404_NOT_FOUND,
                       )

            # 【FEAT-538 (2026-08-29)】「1 人 1 武器装備」の不変条件は
            # services/weapon_equip.equip_exclusively が単一真実値。
            # UniqueConstraint は (player, weapon) だけで is_equipped 単独の
            # DB 制約は無いため、**この関数を通らない書き込みは何も守られない**。
            # admin も同じ関数を呼ぶ (複製すると経路が増えるたびに穴が空く)。
            equip_exclusively(player, target)

        return Response({
            'equipped_weapon': {
                'id':        target.weapon.id,
                'key':       target.weapon.key,
                # 【BUG-146 Phase 2】装備変更直後の表示名も master data。
                'name':      get_i18n_field(
                    target.weapon, 'name', getattr(request, 'locale', 'ja')),
                'atk_bonus': target.weapon.atk_bonus,
            },
        })


class StreakProtectionManualUseView(PlayerMixin, APIView):
    """POST /api/streak-protection/use/ — ストリーク保護アイテムの予約。

    【FEAT-420 (2026-06-10)】「予約 → 翌日判定」モード。
    旧 FEAT-377 の「即時消費 + 昨日の RestDay 作成」は廃止。

    設計:
    - 押下時は即座に消費せず `streak_protection_pending = True` のみ設定する
    - 翌日の習慣達成判定 (`habit_count_service._compute_streak_on_first_done`) で
      「途切れていた」と判定された場合のみ在庫を 1 消費して保護を発動する
    - 自動保護 ON のときは予約は不要 (400 で拒否)
    - 既に予約中の場合は冪等に 200 を返す

    Pre-mortem #3 遵守: select_for_update + transaction.atomic で race 防止。
    """
    permission_classes = [IsAuthenticatedOrGuest]

    def post(self, request):
        player = self.get_player(request)

        with transaction.atomic():
            player_locked = PlayerProfile.objects.select_for_update().get(pk=player.pk)
            locked_eco = player_locked.economy

            # 検証 1: 在庫あるか
            if (locked_eco.streak_protection_count or 0) <= 0:
                return error_response(
                           code='streak_protection_no_stock',
                           message='焦らずとも構いません。次の一歩を、また穏やかに始めましょう 🪶',
                           status=status.HTTP_400_BAD_REQUEST,
                       )

            # 検証 2: 自動保護 ON のときは予約不要 (二重消費防止)
            if locked_eco.streak_protection_auto_enabled:
                return error_response(
                           code='streak_protection_auto_enabled',
                           message='自動保護が有効になっています。手動予約は不要ですよ 🪶',
                           status=status.HTTP_400_BAD_REQUEST,
                       )

            # 既に予約中なら冪等に成功扱い
            if locked_eco.streak_protection_pending:
                return Response({
                    'streak_protection_pending': True,
                    'streak_protection_count': locked_eco.streak_protection_count,
                    'message': '既に予約中です。明日の様子を見守りましょう 🪶',
                }, status=status.HTTP_200_OK)

            locked_eco.streak_protection_pending = True
            locked_eco.save(update_fields=['streak_protection_pending'])

        return Response({
            'streak_protection_pending': True,
            'streak_protection_count': locked_eco.streak_protection_count,
            'message': '保護の予約をしました。翌日、必要なときに静かに使わせていただきます 🪶',
        }, status=status.HTTP_200_OK)


class StreakProtectionCancelView(PlayerMixin, APIView):
    """POST /api/streak-protection/cancel/ — ストリーク保護予約の取消。

    【FEAT-420 (2026-06-10)】予約 (`streak_protection_pending=True`) を False に
    戻すだけの軽量 view。在庫・統計には影響しない。冪等 (未予約でも 200)。

    Pre-mortem S4 遵守: select_for_update + transaction.atomic で
    「取消」と「翌日判定での消費」の race を防止する。
    """
    permission_classes = [IsAuthenticatedOrGuest]

    def post(self, request):
        player = self.get_player(request)

        with transaction.atomic():
            player_locked = PlayerProfile.objects.select_for_update().get(pk=player.pk)
            locked_eco = player_locked.economy
            if locked_eco.streak_protection_pending:
                locked_eco.streak_protection_pending = False
                locked_eco.save(update_fields=['streak_protection_pending'])

        return Response({
            'streak_protection_pending': False,
            'message': '予約を取り消しました 🪶',
        }, status=status.HTTP_200_OK)
