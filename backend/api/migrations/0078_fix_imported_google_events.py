"""BUG-69 hotfix: 取り込み起源 Google イベントの pending_google_push & google_event_id を修復。

【背景】
ExternalCalendarImportView.post の純粋 Google 起源イベント取り込み経路で、`defaults`
辞書に `pending_google_push` と `google_event_id` が含まれていなかったため:

- `pending_google_push` は default=True で挿入される → syncPushLoop で push 対象に混入
- `google_event_id` は未保存 → FEAT-253 reconcile / FEAT-255 双方向取り込みが効かない

結果として「取り込み → Sabiowl が `【Sabiowl】<元タイトル>` で Google に push バック →
次回取り込みで増殖」という構造的ループが発生していた。

【本 migration の役割】
- 既存の `source='google'` イベントを `pending_google_push=False` に修正（push 対象から除外）
- 既存の `source='google'` で `google_event_id` 空のものに `external_id` をコピー
  （Google 側 ID は元々 external_id に入っているため、それを正規の field にも反映）

なお、Google 側に既に作られてしまった `【Sabiowl】<元タイトル>` 重複イベントの削除は
本 migration ではできない（Google API を叩く必要があるため）。ユーザーが Google
カレンダー App / Web で手動削除するか、別途 FEAT-260（Sabiowl 起源イベント一括削除）
で対応する。
"""

from django.db import migrations
from django.db.models import F, Q


def _fix_imported_google_events(apps, schema_editor):
    """source='google' の既存イベントの pending_google_push と google_event_id を修復。"""
    TimelineEvent = apps.get_model('api', 'TimelineEvent')

    # ① source='google' で pending=True のものを False に修正
    pending_fixed = TimelineEvent.objects.filter(
        source='google',
        pending_google_push=True,
    ).update(pending_google_push=False)
    print(
        f'[migration 0078] pending_google_push: {pending_fixed} '
        f'imported Google events fixed to False'
    )

    # ② source='google' で google_event_id 空のものに external_id をコピー
    #    PostgreSQL の F-expression で SQL レベル一括更新
    gid_fixed = TimelineEvent.objects.filter(
        Q(source='google'),
        Q(google_event_id__isnull=True) | Q(google_event_id=''),
    ).update(google_event_id=F('external_id'))
    print(
        f'[migration 0078] google_event_id: {gid_fixed} '
        f'imported Google events filled from external_id'
    )


def _reverse_noop(apps, schema_editor):
    """逆向きは何もしない（修正値を「壊れていた状態」に戻す意味はない）。"""
    pass


class Migration(migrations.Migration):
    dependencies = [
        ('api', '0077_player_gcal_push_enabled_default_off'),
    ]

    operations = [
        migrations.RunPython(_fix_imported_google_events, _reverse_noop),
    ]
