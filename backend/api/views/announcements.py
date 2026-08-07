"""【FEAT-458 (2026-06-21)】お知らせ機能の View 3 件。

エンドポイント:
  - GET  /api/announcements/unread/  : 未読の最新お知らせ 1 件 (popup 表示用)
  - GET  /api/announcements/         : 全 is_active なお知らせ一覧 + is_read フラグ
                                        (通知画面お知らせタブ表示用)
  - POST /api/announcements/<pk>/read/ : 「確認した」既読化 (popup チェック時)

【認証】 IsAuthenticated (ゲスト未対応、ログインユーザー向け機能)
"""
from django.db import IntegrityError
from django.db.models import Exists, OuterRef
from django.utils import timezone
from rest_framework import status
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response
from rest_framework.views import APIView

from ..models import Announcement, PlayerAnnouncementRead
from ..serializers import get_i18n_field
from .mixins import PlayerMixin
from ._error_helpers import error_response  # 【FEAT-515】


def _serialize_link_character(char):
    """【2026-06-27】Announcement.link_character (Character or None) を Mobile の
    最小集合 dict に変換。Mobile はこれを使って popup の「詳細を見る」遷移先を
    判断するだけなので、id / key / name / image_path / tagline のみ返却。
    None は None のまま (Mobile 側で null チェック)。"""
    if char is None:
        return None
    return {
        'id':         char.id,
        'key':        char.key,
        'name':       char.name,
        'image_path': char.image_path,
        'tagline':    char.tagline or '',
    }


def _build_image_url(request, image_field):
    """【2026-06-27】Announcement.image (FieldFile or None) を絶対 URL に変換。
    None / 空ファイルなら None を返却 (Mobile 側で null チェック)。
    request.build_absolute_uri で MEDIA_URL に host を補完して Mobile から
    Network 越しにアクセス可能な URL を生成。"""
    if not image_field:
        return None
    try:
        return request.build_absolute_uri(image_field.url)
    except (ValueError, AttributeError):
        # FieldFile.url 失敗 (まだファイルなし等) は null fallback
        return None


class AnnouncementUnreadView(PlayerMixin, APIView):
    """GET /api/announcements/unread/

    現在公開中 + 未読の最新お知らせ 1 件を返す (ホーム popup 表示用)。

    Response:
        200 { id, title, body, published_at }    未読あり (popup 表示)
        200 null                                  未読なし (popup 非表示)
    """
    permission_classes = [IsAuthenticated]

    def get(self, request):
        player = self.get_player(request)
        now = timezone.now()

        # 【FEAT-460 (2026-06-22)】LEFT JOIN で 1 クエリ未読取得 (P2-A 解消)。
        # PlayerAnnouncementRead.related_name='reads' を経由して
        # `exclude(reads__player=player)` で「既読でない」を直接表現。
        # 旧実装は既読 set を全件取得 + IN 句で除外、announcement 数 100+ で線形悪化。
        # 【2026-06-27】link_character の N+1 回避のため select_related 追加。
        # 【2026-06-27】公開予約機能: published_at__lte=now で未来日のお知らせを除外。
        # 運営が admin で未来日時を設定したお知らせは到達まで非公開、到達後自動公開。
        latest = (
            Announcement.objects
            .select_related('link_character')
            .filter(is_active=True, published_at__lte=now)
            .exclude(expires_at__lt=now)  # expires_at が null は除外されない (公開無期限)
            .exclude(reads__player=player)
            .order_by('-published_at')
            .first()
        )

        if latest is None:
            return Response(None)

        locale = getattr(request, 'locale', 'ja')
        return Response({
            'id':             latest.id,
            'title':          get_i18n_field(latest, 'title', locale),
            'body':           get_i18n_field(latest, 'body', locale),
            'published_at':   latest.published_at.isoformat(),
            # 【2026-06-27】お知らせから新キャラ詳細への動線。null = 通常お知らせ。
            'link_character': _serialize_link_character(latest.link_character),
            # 【2026-06-27】お知らせ画像 (任意)。null = 画像なし、Mobile popup で
            # 本文上に大きく表示するための絶対 URL (request.build_absolute_uri 経由)。
            'image_url':      _build_image_url(request, latest.image),
        })


class AnnouncementListView(PlayerMixin, APIView):
    """GET /api/announcements/

    現在公開中の全お知らせを既読フラグ付きで返す (通知画面お知らせタブ表示用)。
    新しい順、最大 50 件。

    Response:
        200 { announcements: [{id, title, body, published_at, is_read}, ...] }
    """
    permission_classes = [IsAuthenticated]

    def get(self, request):
        player = self.get_player(request)
        now = timezone.now()

        # 【FEAT-460 (2026-06-22)】is_read を Exists(OuterRef) で annotate し
        # 1 クエリに集約 (旧実装は既読 set 全件取得 + Python 側 in 判定)。
        # 【2026-06-27】link_character の N+1 回避のため select_related 追加。
        # 【2026-06-27】公開予約機能: published_at__lte=now で未来日のお知らせを除外
        # (Unread View と同条件、お知らせタブの履歴閲覧経路にも適用)。
        announcements = (
            Announcement.objects
            .select_related('link_character')
            .filter(is_active=True, published_at__lte=now)
            .exclude(expires_at__lt=now)
            .annotate(
                is_read=Exists(
                    PlayerAnnouncementRead.objects.filter(
                        player=player,
                        announcement=OuterRef('pk'),
                    )
                )
            )
            .order_by('-published_at')[:50]
        )

        locale = getattr(request, 'locale', 'ja')
        return Response({
            'announcements': [
                {
                    'id':             a.id,
                    'title':          get_i18n_field(a, 'title', locale),
                    'body':           get_i18n_field(a, 'body', locale),
                    'published_at':   a.published_at.isoformat(),
                    'is_read':        a.is_read,
                    # 【2026-06-27】キャラ詳細への動線 (null = 通常お知らせ)
                    'link_character': _serialize_link_character(a.link_character),
                    # 【2026-06-27】お知らせ画像 (任意)
                    'image_url':      _build_image_url(request, a.image),
                }
                for a in announcements
            ],
        })


class AnnouncementReadView(PlayerMixin, APIView):
    """POST /api/announcements/<pk>/read/

    指定お知らせを既読化 (popup「確認した」チェック時 + 通知画面タップ時)。
    冪等: 既に既読 (PlayerAnnouncementRead 存在) なら no-op で 200。

    Response:
        200 { status: 'read' }     新規既読化 or 既読済
        404 アナウンス不存在 / 期限切れ / 無効化済
    """
    permission_classes = [IsAuthenticated]

    def post(self, request, pk):
        player = self.get_player(request)
        now = timezone.now()

        # 存在 + 有効 + 期限内 のみ既読化可能 (古いお知らせの既読化は無意味)。
        # 【2026-06-27】公開予約機能: published_at__lte=now を追加 (未公開のお知らせを
        # 直接 API 攻撃で既読化される事故を防ぐ、信頼境界)。Unread/List view と同条件。
        try:
            announcement = (
                Announcement.objects
                .filter(is_active=True, published_at__lte=now)
                .exclude(expires_at__lt=now)
                .get(pk=pk)
            )
        except Announcement.DoesNotExist:
            return error_response(
                       code='announcement_detail_not_found',
                       message='お知らせが見つかりません 🪶',
                       status=status.HTTP_404_NOT_FOUND,
                   )

        # get_or_create で冪等性確保。同時 2 リクエストの race も UniqueConstraint
        # + IntegrityError catch で安全に no-op に倒す。
        try:
            PlayerAnnouncementRead.objects.get_or_create(
                player=player,
                announcement=announcement,
            )
        except IntegrityError:
            # 既読化済 (race) - 冪等 OK
            pass

        return Response({'status': 'read'})
