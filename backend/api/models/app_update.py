"""【FEAT-543 (2026-09-23)】バージョンアップ告知のモデル定義。

Django admin から ON/OFF + しきい値 2 本 + 文面を編集する。
構造は `MaintenanceConfig` (FEAT-463) をそのまま写している。

## 🔴 `expires_at` は作らない

メンテナンスは「いつか終わるもの」だが、**更新告知は次の版が出るまで
出し続けるのが正常**である。自動失効を付けると、逆に
「出したはずが消えている」を作る。止めるのは `is_enabled` の OFF である。

## 🔴 しきい値が 2 本ある理由

| field | 意味 |
|---|---|
| `latest_version` | 「ここまで上げてほしい」= 推奨更新（閉じられる） |
| `min_supported_version` | 「ここより古いと使わせられない」= 必須更新（閉じられない） |

⚠️ **両方を同時に使うと、ユーザーは 3 群に分かれる。**
例: `latest=1.1.6` / `min=1.1.4` のとき、1.1.3 以下は閉じられず、
1.1.4-1.1.5 は閉じられ、1.1.6 は何も出ない。
だから**文面を 1 組で共用してはいけない** —— どちらかに必ず嘘が出る。
**推奨更新と必須更新で 2 組持つ。**

## 🔵 【FEAT-544 (2026-09-23)】必須更新の文面も DB に持つことにした

FEAT-543 §2-7 では「緊急時に文章を書かせない」ためにアプリへ固定したが、
**admin に無い機能は忘れられる**（ユーザー指摘 2026-09-23）。
**入力欄はそれ自体が運用の説明書である。**

🔵 **既定値を日英そろえて入れておけば、元の理由も両立する** ——
緊急時に admin がやることは**数字を入れるだけ**で変わらない。
⚠️ **アプリ内の固定文は残す。** Backend が未デプロイのとき / 通信できないとき /
admin が誤って空にしたときに、**閉じられない画面が無文面になる**のを防ぐ。

## ⚠️ しきい値は全部 OFF / 空で始める

**入れた瞬間に全ユーザーへ出る種類の機能**なので、既定値が空でないと事故になる。
`min_supported_version` は特に、**空のままにしておくのが既定の運用**である。
🔵 文面の既定値は埋めてよい（出る条件はしきい値が握っているため）。
"""
from django.conf import settings
from django.db import models

# ── 【FEAT-544 (2026-09-23)】既定文 ─────────────────────────────────────────
#
# 🔵 **既定値を日英そろえて入れておく。** そうすれば緊急時に書くものが無く、
# admin は**数字を入れるだけ**で済む。
# FEAT-543 §2-7 は「緊急時に文章を書かせない」ために必須更新の文面を
# アプリに固定したが、**admin に無い機能は忘れられる**（ユーザー指摘）。
# 既定値を入れておけば、両方を満たせる。
#
# 🔵 **絵文字は付けない**（ユーザー判断 2026-09-23）。
# 更新告知は**システムの通知であってサビの声ではない**。加えて
# **絵文字の見え方が環境ごとに違う**。
#
# 🔴 **英語の既定文をここに置き、view が import する。**
# 同じ英文を 2 箇所に書くと必ず食い違う ——
# FEAT-536 が「2 箇所に同じ英文がある」と申し送った問題を、ここで構造的に解消する。

#: 推奨更新の既定文。dev の admin で実際に登録された文面をそのまま既定値にした。
DEFAULT_TITLE = '新しいバージョンが届いています'
DEFAULT_BODY = 'App Store からバージョン更新をお願いします'
DEFAULT_TITLE_EN = 'A new version is available.'
DEFAULT_BODY_EN = 'You can update the app from the App Store.'

#: 🔴 必須更新の既定文。**閉じられない画面に出る。**
#:
#: ⚠️ admin が空にすると文面の無い画面になるので、Mobile 側は
#: 空のとき ARB の固定文へ落とす（FEAT-544 §4）。
DEFAULT_MANDATORY_TITLE = '更新をお願いいたします'
DEFAULT_MANDATORY_BODY = (
    '今のバージョンでは、正しくご利用いただけない状態です。'
    'App Store から更新してください。'
    'あなたの記録は残っておりますので、更新後もそのままお使いいただけます'
)
DEFAULT_MANDATORY_TITLE_EN = 'An update is required to continue'
DEFAULT_MANDATORY_BODY_EN = (
    'This version can no longer run correctly. Please update from the '
    'App Store. All of your records are safe and will be waiting for you.'
)

#: view が `_EN_FALLBACK` として使う。**ここが単一の真実値である。**
EN_FALLBACK = {
    'title': DEFAULT_TITLE_EN,
    'body': DEFAULT_BODY_EN,
    'mandatory_title': DEFAULT_MANDATORY_TITLE_EN,
    'mandatory_body': DEFAULT_MANDATORY_BODY_EN,
}


class AppUpdateConfig(models.Model):
    """バージョンアップ告知設定 (Singleton: 常に pk=1 の 1 行のみ)。"""

    is_enabled = models.BooleanField(
        default=False,
        verbose_name='更新告知を有効にする',
        help_text=(
            'OFF のあいだは何も出ません。事故ったらここを OFF にすれば '
            '60 秒で全ユーザーから消えます。'
        ),
    )
    latest_version = models.CharField(
        max_length=20, blank=True, default='',
        verbose_name='最新バージョン (推奨更新のしきい値)',
        help_text=(
            '端末がこれより古ければ「後で」を押せる告知を出します (例: 1.1.4)。'
            '⚠️ 上げるのは、実機でストアから実際に落とせることを確認した後にしてください。'
        ),
    )
    min_supported_version = models.CharField(
        max_length=20, blank=True, default='',
        verbose_name='最低サポートバージョン (必須更新のしきい値)',
        help_text=(
            '端末がこれより古ければ「後で」を押せない告知を出します。'
            '⚠️ 空のままが既定です。入れるのは「その版ではデータが壊れる」ときだけ。'
            '審査中の版を含めないでください (reviewer が古い版で詰みます)。'
        ),
    )
    title = models.CharField(
        max_length=60, blank=True, default=DEFAULT_TITLE,
        verbose_name='タイトル (推奨更新)',
    )
    # 【FEAT-536 の教訓】英語欄が空のまま ON にされることが実際に起きている。
    # 空なら view の `_EN_FALLBACK` が出る (ja は出さない)。
    title_en = models.CharField(
        max_length=60, blank=True, default=DEFAULT_TITLE_EN,
        verbose_name='タイトル(英語版)',
    )
    body = models.TextField(
        max_length=400, blank=True, default=DEFAULT_BODY,
        verbose_name='本文 (推奨更新、サビ口調)',
    )
    body_en = models.TextField(
        blank=True, default=DEFAULT_BODY_EN,
        verbose_name='本文(英語版)',
    )
    # ── 【FEAT-544 (2026-09-23)】必須更新の文面 ─────────────────────────
    #
    # 🔴 **閉じられない画面に出る。** 空にすると文面の無い画面になるので、
    # Mobile 側は空のとき ARB の固定文へ落とす。
    #
    # 🔵 **欄をここに作ったこと自体が運用の説明書である。**
    # 欄が無ければ、半年後に必須更新という仕組みがあること自体を
    # 思い出せない ——**思い出せない機能は、必要なときに使われない**。
    mandatory_title = models.CharField(
        max_length=60, blank=True, default=DEFAULT_MANDATORY_TITLE,
        verbose_name='タイトル (必須更新)',
    )
    mandatory_title_en = models.CharField(
        max_length=60, blank=True, default=DEFAULT_MANDATORY_TITLE_EN,
        verbose_name='タイトル(英語版・必須更新)',
    )
    mandatory_body = models.TextField(
        max_length=400, blank=True, default=DEFAULT_MANDATORY_BODY,
        verbose_name='本文 (必須更新)',
    )
    mandatory_body_en = models.TextField(
        blank=True, default=DEFAULT_MANDATORY_BODY_EN,
        verbose_name='本文(英語版・必須更新)',
    )
    created_by = models.ForeignKey(
        settings.AUTH_USER_MODEL, null=True, blank=True,
        on_delete=models.SET_NULL,
        related_name='app_update_changes',
        verbose_name='最終更新者',
    )
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        app_label = 'api'
        verbose_name = 'バージョンアップ告知設定'
        verbose_name_plural = 'バージョンアップ告知設定'

    def __str__(self):
        status = 'ON' if self.is_enabled else 'OFF'
        return f'AppUpdateConfig({status}, latest={self.latest_version or "-"})'

    @classmethod
    def get_solo(cls):
        """Singleton: pk=1 を get_or_create で取得する。"""
        obj, _ = cls.objects.get_or_create(pk=1)
        return obj
