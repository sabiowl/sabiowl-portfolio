# Runbook — 緊急メンテナンスモード

> 作成日: 2026-08-29（FEAT-536 Phase 3）
> 対象: 障害発生時 / 計画停止時に、全ユーザーへ告知を出す
> 関連: FEAT-463（本体）/ FEAT-471（60 秒 cache）/ FEAT-536（英語対応 + 本書）

**1 画面に収める。障害の最中に読むものなので、長いと読まれない。**

---

## ON にする

1. admin を開く → **緊急メンテナンス設定**
   - URL は `ADMIN_URL` 環境変数のパス（Render の環境変数で確認）。
     🔴 **本書にハードコードしない** —— 予測困難にしてある意味が消える
2. 行が無ければ新規作成（**pk=1 の 1 行だけ**作れる）
3. 埋める:

| 欄 | 入れるもの |
|---|---|
| メンテナンスモード有効 | ✅ |
| **自動失効時刻** | 🔴 **必ず入れる**。**JST で入力**（`TIME_ZONE = 'Asia/Tokyo'`）。解除忘れの唯一の保険 |
| タイトル / 本文 | 日本語。サビ口調（丁寧体 + 🪶） |
| **English（title_en / body_en）** | 🔴 **埋める**。空だと英語ユーザーには**汎用の英文**が出る（日本語は出ない） |

4. 保存 → **即時反映**（admin 保存は cache を invalidate する）

### 反映されたことの確認

```bash
curl -s -D- https://sabiowl-backend.onrender.com/api/maintenance/ -o /dev/null | grep -i x-maintenance
curl -s https://sabiowl-backend.onrender.com/api/maintenance/
curl -s -H 'Accept-Language: en' https://sabiowl-backend.onrender.com/api/maintenance/
```

**3 つとも確認すること。** ユーザーには 3 経路で届く:

| 層 | 届く相手 |
|---|---|
| BootGate probe（`/api/maintenance/`） | **これから起動する**人 |
| `X-Maintenance` header（全 API レスポンス） | **今アプリを開いている**人 |
| 5xx sentinel | 上 2 つが死んだとき |

🔴 **`X-Maintenance` が付かないときは `DEBUG` を疑う。** middleware は
`if settings.DEBUG: return response` で丸ごと bypass する。
2026-08-28 に dev がこの状態で、**probe 層だけ動いて header 層が死んでいた**。
「メンテにしたのに、開いている人の画面が切り替わらない」はこの形。

---

## OFF にする

admin で **メンテナンスモード有効** のチェックを外して保存 → **即時**。

- DB を直接書き換えた場合は **最大 60 秒**（`maintenance_cache` の TTL）
- `expires_at` を過ぎた場合も自動で解除される（`is_enabled` の DB 値は True のまま。
  **落ち着いてから手で OFF に戻すこと**）

---

## 知っておくこと

- 🔴 **`/admin/` は bypass される。** メンテ中でも admin は開ける ——
  **自分が締め出されることはない**
- **API は止まらない。** header を付けるだけで、書き込みも通る。
  DB を触る計画停止で本当に止めたいときは **Render 側を止める**ほうが確実
  （FEAT-536 §6 で意図的にスコープ外にした）
- **アプリはバックグラウンド復帰では再 probe しない。** 起動中のセッションに
  対しては **header が唯一の受け皿**。header 層が死ぬと、そのセッションは
  二度とメンテに気付かない
- **解除忘れの通知は無い。** だから `expires_at` を必ず入れる（v1.3+ で Slack 通知）

---

## 🔴 文言を変えるときは 2 箇所

英語の**汎用**文言（`_en` が空のときに出るもの）は **2 箇所に同じ文字列**がある:

| 場所 | 何 |
|---|---|
| `backend/api/views/maintenance.py` | `_EN_FALLBACK` |
| `mobile/lib/l10n/app_en.arb` | `coreMaintenancePlaceholderTitle` / `coreMaintenancePlaceholderBodySabi_message` |

⚠️ **テストで縛っていない。** ARB は Flutter 側、定数は Django 側で、
揃っているかを見るには CI をまたぐ機構が要る。割に合わないと判断して
**ここに書いて残している**（FEAT-536 Pre-mortem #2）。

片方だけ直すと、overlay が「仮の英文 → 別の英文」に化ける。
（日本語に化けるよりマシなだけで、質は同じ）

---

## admin が開けないときの緊急 ON

Render Shell から:

```bash
python manage.py shell
```

```python
from api.models import MaintenanceConfig
from api.services.maintenance_cache import invalidate_maintenance_cache
from django.utils import timezone
from datetime import timedelta

c = MaintenanceConfig.get_solo()          # pk=1 が無ければ作る
c.is_enabled = True
c.expires_at = timezone.now() + timedelta(hours=2)   # 🔴 必ず入れる
c.title_en = 'We are currently performing emergency maintenance.'
c.body_en  = 'We will be back shortly. Thank you for your patience.'
c.save()
invalidate_maintenance_cache()            # admin 経由でないので手で呼ぶ
```

🔴 **`invalidate_maintenance_cache()` を忘れないこと。** admin の保存は自動で
呼ぶが、shell からの変更は呼ばれないので **最大 60 秒**遅れる。

🔵 `get_maintenance_config()`（middleware / view が使う読み取り側）は
**行を作らない**（`.filter(pk=1).first()`）。行が無い状態で ON にできるのは
`get_solo()` だけである。

---

## 平時にやっておくこと

🔴 **行を先に作っておく（`is_enabled=False` のまま）。**

行が無いと、**障害時に運営が最初にやる操作が「この行を新規作成すること」**に
なる。落ち着いて英文を書ける時間があるかどうかが本質で、
2026-08-29 の検証では実際に **既定値のまま ON にされ、英語端末に日本語が出た**。

日英とも埋めて OFF で保存しておけば、当日は **チェックを入れるだけ**になる。
