"""【FEAT-317 (2026-08-04)】ガチャの dead reward `title` を無効化し weight を再配分する。

## 何が問題だったか

`reward_type='title'` は **付与処理が存在しない**。`_apply_reward` の分岐は
character / weapon / exp / diamond / character_ticket / xp_boost の 6 種だけで、
title に来ると **何も起きずに終わる** (`value=0` なので exp/diamond の条件にも
掛からない)。`PlayerProfile` に称号 field も無く、UI も無い。

実測 (2026-08-04、開発 DB):

| ticket | title の weight | 全体比 |
|---|---:|---:|
| daily  | 15 + 5 + 1 = 21 | **20.2%** |
| weekly | 17 + 8 = 25     | **14.3%** |

**デイリーは 5 回に 1 回、引いても何も起きない**。SEC-12 が Shop の dead UX を
「ユーザーへの嘘」として撲滅した方針を、ガチャにも適用する。

## なぜ weight をハードコードせず動的に計算するのか

`GachaReward` は **migration と `_ensure_gacha_rewards()` の両方**で作られる。
後者は `get_or_create` の seed 専用で、**過去の定数バージョンで作られた行を
消さない**。そのため DB の中身は「いつからそのインストールが稼働しているか」で
変わり、prod に daily title が 3 行あるのか 0 行なのかを**コードから断定できない**。

そこで **migration 実行時点の DB を読んで按分する**。どちらの状態でも正しく動く。

## 再配分の規則

1. `title` の weight を、**同じ (ticket_type, rarity) の他の active 報酬**へ
   現行 weight 比で按分する (最大剰余法で端数を配り、合計を厳密に保つ)
2. rarity を越えて配らない —— CLAUDE.md「取得頻度が下がるほど排出が厚くなる傾斜」
   を崩さないため
3. **同 rarity に他の報酬が 1 つも無い場合**は代替報酬を作る。
   実測で daily SSR が title 1 件のみだった。ここを単に消すと
   **デイリーから最高レアが消滅**し、引く動機が一段弱くなる。
   ユーザー判断 (2026-08-04) により「ダイヤ ×150」を新設する
   (daily SR = ×100 と weekly SSR = ×200 の中間)

## 削除ではなく無効化する理由

`GachaHistory.reward` は `on_delete=CASCADE` の FK。**行を削除すると
ユーザーのガチャ履歴が消える**。`is_active=False` に留めれば履歴は保たれ、
`_ensure_gacha_rewards()` は `get_or_create` なので復活もしない。

CLAUDE.md「master/seed data 例外条項 (FEAT-391)」の 3 条件を満たす:
master data のみ / FK 影響を確認済 (CASCADE を避けるため無効化) / 冪等。

## 冪等性

active な title が無くなれば以降は no-op。二度流しても weight は動かない。
"""
from django.db import migrations

_RARITY_ORDER = ('N', 'R', 'SR', 'SSR')

# 同 rarity に按分先が 1 つも無かったときの代替報酬 (ユーザー判断 2026-08-04)。
_REPLACEMENTS = {
    ('daily', 'SSR'): dict(
        reward_type='diamond', container='stone', name='ダイヤ',
        detail='× 150', icon='💎', value=150,
    ),
}


def _distribute(freed: int, siblings: list) -> dict:
    """`freed` を siblings の現行 weight 比で按分する (最大剰余法)。

    Returns: {pk: 加算する weight}。合計は必ず `freed` に一致する。
    """
    base = sum(s.weight for s in siblings)
    if base <= 0:
        # 全部 weight=0 の異常系。均等割りに落とす。
        share, rem = divmod(freed, len(siblings))
        out = {s.pk: share for s in siblings}
        for s in siblings[:rem]:
            out[s.pk] += 1
        return out

    exact = [(s, freed * s.weight / base) for s in siblings]
    out = {s.pk: int(v) for s, v in exact}
    rem = freed - sum(out.values())
    # 端数が大きい順に 1 ずつ配る
    for s, v in sorted(exact, key=lambda t: -(t[1] - int(t[1])))[:rem]:
        out[s.pk] += 1
    return out


def purge_title(apps, schema_editor):
    GachaReward = apps.get_model('api', 'GachaReward')

    for ticket_type in ('daily', 'weekly', 'monthly'):
        for rarity in _RARITY_ORDER:
            titles = list(GachaReward.objects.filter(
                ticket_type=ticket_type, rarity=rarity,
                reward_type='title', is_active=True,
            ))
            if not titles:
                continue

            freed = sum(t.weight for t in titles)
            siblings = list(GachaReward.objects.filter(
                ticket_type=ticket_type, rarity=rarity, is_active=True,
            ).exclude(reward_type='title'))

            if siblings:
                for pk, add in _distribute(freed, siblings).items():
                    if add:
                        GachaReward.objects.filter(pk=pk).update(
                            weight=models_F_add(GachaReward, pk, add))
                print(f'[0199 FEAT-317] {ticket_type}/{rarity}: title {freed} を'
                      f' {len(siblings)} 件に按分')
            else:
                spec = _REPLACEMENTS.get((ticket_type, rarity))
                if spec is None:
                    # 按分先も代替も無い = weight が消える。rarity 配分が変わるので
                    # 黙って進めない。
                    raise RuntimeError(
                        f'{ticket_type}/{rarity} に按分先が無く代替報酬も未定義 '
                        f'(freed={freed})。_REPLACEMENTS に追加すること。'
                    )
                GachaReward.objects.get_or_create(
                    ticket_type=ticket_type, name=spec['name'],
                    detail=spec['detail'],
                    defaults=dict(spec, ticket_type=ticket_type, rarity=rarity,
                                  weight=freed, is_active=True),
                )
                print(f'[0199 FEAT-317] {ticket_type}/{rarity}: 按分先が無いため'
                      f' 代替報酬 "{spec["name"]} {spec["detail"]}" を weight={freed} で新設')

            GachaReward.objects.filter(
                pk__in=[t.pk for t in titles],
            ).update(is_active=False)
            print(f'[0199 FEAT-317] {ticket_type}/{rarity}: title {len(titles)} 件を無効化')


def models_F_add(model, pk, add):
    """`F('weight') + add` を返す小ヘルパー (import を 1 箇所に閉じる)。"""
    from django.db.models import F
    return F('weight') + add


def noop_reverse(apps, schema_editor):
    """巻き戻しは行わない。

    無効化した title を復活させると **dead reward が戻る**だけであり、
    按分した weight を正確に戻す手段も無い (按分は実行時の DB 状態に依存する)。
    forward only とする。
    """


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0198_job_name_en'),
    ]

    operations = [
        migrations.RunPython(purge_title, noop_reverse),
    ]
