"""【BUG-67 followup】SocialAccount を持たない孤立 User の一括クリーンアップ。

BUG-67 修正後も、過去の中途半端な削除残骸 / 旧 magic-link 経路 (FEAT-178 で撤去
済) / 開発初期データ等で作られた User が DB に残置しており、新規 Google/Apple
連携時に以下のシナリオで 409 を返してしまう:

  1. Firebase で新規 uid 発行
  2. Backend `_create_user_only(email)` → `username` unique 制約違反 IntegrityError
     （別 User が同 email で残置していたため）
  3. `SocialAccount.objects.filter(provider_uid=uid)` → 該当なし（新 uid なので当然）
  4. → 409「認証処理が競合しました」

Render Shell が使えない構成のため、`build.sh` の `migrate` ステップで自動実行
される一回限りのデータマイグレーションでクリーンアップする。

開発中（リリース前）かつユーザーは「削除して問題ない」と確認済みのため、
SocialAccount を持たない一般 User を CASCADE で全削除する。Django admin
superuser / staff は念のため除外（運用上の管理者アカウント保護）。

冪等性: 2 回目以降の実行では孤立 User は 0 件なので no-op。安全に何度走っても OK。

関連:
  - BUG-67: `@transaction.atomic` 配下の IntegrityError 補足が broken transaction を
    起こす問題（既に commit `cfd52c6` で構造修正済み）
  - FEAT-245: アカウント削除パイプラインの 3 段階完全化（既に commit `f0ca9de` で実装済み）
    本マイグレーションは FEAT-245 以前の残置データを掃除する役割
"""
from django.db import migrations
from django.db.models import Count


def cleanup_orphan_users(apps, schema_editor):
    """SocialAccount を持たない非管理者 User を CASCADE 削除する。"""
    User = apps.get_model('auth', 'User')
    # SocialAccount モデルは参照解決のみ目的（apps.get_model で確認）
    apps.get_model('api', 'SocialAccount')

    # 孤立 User を抽出: SocialAccount を持たない、かつ superuser/staff ではない。
    # related_name='social_accounts' は SocialAccount.user FK で定義済み
    # （backend/api/models/auth.py:35 参照）。
    orphan_qs = (
        User.objects
        .annotate(sa_count=Count('social_accounts'))
        .filter(sa_count=0, is_superuser=False, is_staff=False)
    )
    orphan_ids = list(orphan_qs.values_list('id', flat=True))

    if not orphan_ids:
        # 既に cleanup 済 or 孤立 User なし → no-op で完了
        print('[migration 0072] No orphan users found. Skipping cleanup.')
        return

    # User.delete() で CASCADE 連鎖:
    # - PlayerProfile (api.PlayerProfile.user OneToOne)
    # - Habit / HabitLog / HabitRewardLog / ChecklistItem
    # - TimelineEvent / RestDay
    # - PlayerItem / PlayerAchievement / PlayerGachaStatus / GachaHistory
    # - Friendship / Message / Notification / OwnedCharacter
    # - GuestPromotePending (target_user 参照経由)
    # - Token (authtoken.Token.user OneToOne)
    # AccountDeletionFeedback は IntegerField で FK でないため CASCADE 対象外（統計用に維持）
    deleted_count, deleted_by_model = User.objects.filter(id__in=orphan_ids).delete()
    print(
        f'[migration 0072] Cleaned up {len(orphan_ids)} orphan users '
        f'(total {deleted_count} rows): {deleted_by_model}'
    )


def reverse_noop(apps, schema_editor):
    """ロールバック不可（削除済み User は復元不能）。

    本マイグレーションは「不要データ削除」のためのものなので、`backwards` で
    User を再生成する意味はない。no-op として保持し、ロールバック時はマイグ
    レーション履歴のみが戻る。
    """
    pass


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0071_timelineevent_google_event_id'),
    ]

    operations = [
        migrations.RunPython(cleanup_orphan_users, reverse_noop),
    ]
