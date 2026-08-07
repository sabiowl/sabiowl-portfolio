"""【FEAT-489 Phase 4】マスターデータの _en フィールドを一括更新するコマンド。

翻訳済み JSON ファイルを読み込み、5 モデルの _en フィールドを bulk_update する。
CI / 手動リリース作業の一部として使用。

JSON フォーマット (doc/i18n/master_data_en.json):
{
  "SabiMessage":    [{"id": 1, "content": "<翻訳元の日本語>", "content_en": "..."}],
  "Enemy":          [{"key": "goblin", "name": "ゴブリン", "name_en": "Goblin"}],
  "Character":      [{"key": "aria", "name_en": "...", "role_en": "...", ...}],
  "Job":            [{"job_id": "healer", "job_name_en": "..."}]
}

## 行の指定方法 (2026-08-03 / 2026-08-07 更新)

優先順位は **複合キー → 自然キー → `id` (pk)**。

| 方式 | 対象 | 例 |
|---|---|---|
| 複合キー (`_COMPOSITE_KEYS`) | pk が不安定な model | `GachaReward` = `(name, detail)` |
| 自然キー (`_NATURAL_KEYS`) | `key` / `job_id` を持つ model | `Enemy.key` / `Job.job_id` |
| `id` (pk) | 上記が無い model のみ | `SabiMessage` / `TaskSuggestion` |

**pk は最後の手段**。pk は「その行が何であるか」を表さないので、使えるなら
必ず他の方式を選ぶこと。

### pk 依存で実際に踏んだ事故 (2026-08-06)

`GachaReward` を pk で指定していたところ、CI (PostgreSQL) で 13 件が
`not found` になり 4 テストが落ちた。原因は **GachaReward が migration では
なく実行時 (`views/gacha.py` の `_ensure_gacha_rewards()`) に seed される**
こと。migration 直後は 6 行しか無く、残りは lazy seed が作る。

lazy seed 行の pk は DB backend で変わる。SQLite は解放された rowid を
`max+1` で再利用するが、PostgreSQL のシーケンスは再利用しない。結果、
**ローカル (SQLite) は緑、CI (PostgreSQL) は赤**という状態になっていた。

同種の model を足すときは `_COMPOSITE_KEYS` に追加すること。

## なぜ source 検証が要るか

`SabiMessage` と `TaskSuggestion` には自然キーが無く、pk だけが手掛かりになる。
一方この 2 つは **admin から追加・無効化できる設計**なので、
「ローカルで export した時の pk」と「prod の pk」が一致する保証は無い。

pk がずれたまま投入すると、**サビの台詞 A の英訳が台詞 B に入る**。
例外は出ず、英語ユーザーが見るまで誰も気付かない。

そこで entry に **翻訳元の日本語** (`content` / `title` / `name` …) を持たせ、
DB の現在値と一致するときだけ適用する。翻訳は元の文に対して行うものなので、
元が違えば適用してはいけない —— この検証は自己完結している。

不一致が 1 件でもあれば **異常終了する** (黙って件数が減るのを防ぐ)。

使用例:
    python manage.py translate_master_data --file doc/i18n/master_data_en.json
    python manage.py translate_master_data --file doc/i18n/master_data_en.json --dry-run
"""
import json
from pathlib import Path

from django.core.management.base import BaseCommand, CommandError
from django.db import transaction

from api.i18n_targets import i18n_target_map

# 【2026-08-02】手書きの 5 model dict をやめ、model から `_en` を自動列挙する。
# 手書きだったせいで `Job.job_name_en` が対象から漏れ、reviewer から受け取った
# JSON にジョブ名を書いても投入できない状態だった
# (api/i18n_targets.py の docstring 参照)。
#
# 関数呼び出しは handle() 内で行う (import 時点では app registry が
# 準備できていない可能性があるため)。

# 自然キーを持つ model は pk ではなくそちらで引く (docstring 参照)。
_NATURAL_KEYS = ('key', 'job_id')

# 【2026-08-07】単一の自然キー field は無いが、**複数 field の組で行を同定できる**
# model。pk より優先して使う。
#
# ## なぜ GachaReward に必要か
#
# GachaReward の行は migration ではなく **実行時** (`views/gacha.py` の
# `_ensure_gacha_rewards()`) に seed される。migration 直後は 6 行しか無く、
# 残り 13 行は lazy seed が作る。
#
# lazy seed 行の pk は **DB backend によって変わる**。SQLite は解放された
# rowid を `max+1` で再利用するが、PostgreSQL のシーケンスは再利用しない。
# 結果、同じ翻訳ファイルが SQLite では 19 行すべてに当たり、PostgreSQL では
# 6 行にしか当たらない、という状態になっていた (CI が赤になって発覚)。
#
# pk は「この行が何であるか」を表していない。GachaReward の同一性は
# `_ensure_gacha_rewards()` 自身が lookup に使う日本語テキストの組にある。
# ここではそれに合わせる。
#
# ## 複数行にマッチしてよい
#
# `(name, detail)` は `ticket_type` を含まないため、daily と weekly に
# 同じ文言の行があると 2 行に当たる (実際「XPブースト×2 / 30分 ×1.5倍」が該当)。
# 訳は日本語テキストの関数なので、**両方に同じ訳を入れるのが正しい**。
# そのため解決結果は単数ではなくリストで扱う。
_COMPOSITE_KEYS = {
    'GachaReward': ('name', 'detail'),
}


def _natural_key_field(model_cls):
    """model が持つ自然キー field 名を返す。無ければ None。"""
    names = {f.name for f in model_cls._meta.get_fields()}
    for candidate in _NATURAL_KEYS:
        if candidate in names:
            return candidate
    return None


class Command(BaseCommand):
    help = 'Bulk-update _en fields from a translation JSON file'

    def add_arguments(self, parser):
        parser.add_argument(
            '--file',
            required=True,
            help='Path to translation JSON file (relative to repo root or absolute)',
        )
        parser.add_argument(
            '--dry-run',
            action='store_true',
            default=False,
            help='Print what would be updated without writing to DB',
        )

    def handle(self, *args, **options):
        file_path = Path(options['file'])
        if not file_path.is_absolute():
            # resolve relative to cwd
            file_path = Path.cwd() / file_path

        if not file_path.exists():
            raise CommandError(f'File not found: {file_path}')

        try:
            data = json.loads(file_path.read_text(encoding='utf-8'))
        except json.JSONDecodeError as exc:
            raise CommandError(f'Invalid JSON: {exc}') from exc

        dry_run = options['dry_run']
        if dry_run:
            self.stdout.write(self.style.WARNING('[DRY RUN] No changes will be written.'))

        model_map = i18n_target_map()
        total_updated = 0
        skipped = 0

        with transaction.atomic():
            for model_name, entries in data.items():
                if model_name not in model_map:
                    self.stdout.write(self.style.WARNING(
                        f'  Unknown model "{model_name}", skipping. '
                        f'(既知: {", ".join(sorted(model_map))})'
                    ))
                    continue

                model_cls, en_fields = model_map[model_name]

                if not entries:
                    continue

                ids = [e['id'] for e in entries if 'id' in e]
                objs = {obj.pk: obj for obj in model_cls.objects.filter(pk__in=ids)}
                nat_field = _natural_key_field(model_cls)
                nat_objs = {}
                if nat_field:
                    nat_objs = {
                        getattr(o, nat_field): o for o in model_cls.objects.all()
                    }
                comp_fields = _COMPOSITE_KEYS.get(model_name)
                comp_objs = {}
                if comp_fields:
                    for o in model_cls.objects.all():
                        key = tuple(
                            (getattr(o, f, '') or '').strip() for f in comp_fields
                        )
                        comp_objs.setdefault(key, []).append(o)
                to_update = []

                for entry in entries:
                    matched = self._resolve(
                        entry, model_name, objs, nat_objs, nat_field,
                        comp_fields, comp_objs,
                    )
                    if not matched:
                        skipped += 1
                        continue

                    for obj in matched:
                        # 【2026-08-03】source 検証。翻訳の元になった日本語が DB の
                        # 現在値と違うなら、その翻訳は**この行のものではない**。
                        # 上書きせず警告する (§ docstring「なぜ source 検証が要るか」)。
                        if not self._source_matches(entry, obj, en_fields, model_name):
                            skipped += 1
                            continue

                        changed = False
                        for field in en_fields:
                            if field in entry:
                                setattr(obj, field, entry[field])
                                changed = True
                        if changed:
                            to_update.append(obj)

                if to_update and not dry_run:
                    model_cls.objects.bulk_update(to_update, en_fields)

                self.stdout.write(
                    f'  {model_name}: {"(dry-run) would update" if dry_run else "updated"} '
                    f'{len(to_update)} records'
                )
                total_updated += len(to_update)

            if dry_run:
                transaction.set_rollback(True)

        verb = 'Would update' if dry_run else 'Updated'
        self.stdout.write(self.style.SUCCESS(f'\n{verb} {total_updated} records total.'))

        if skipped:
            # 黙って投入件数が減るのが最悪。exit code を立てて CI / 手作業の
            # どちらでも気付けるようにする。
            raise CommandError(
                f'{skipped} 件を適用できなかった (上記の警告を確認すること)。'
                ' 行の取り違えを防ぐため、1 件でも不一致があれば異常終了する。'
            )

    # ── 行の解決 ─────────────────────────────────────────────────────────
    def _resolve(self, entry, model_name, objs, nat_objs, nat_field,
                 comp_fields=None, comp_objs=None):
        """対象行を **リストで** 返す。見つからなければ空リスト。

        優先順位は **複合キー → 自然キー → `id`**。pk を最後に置くのは、
        pk が「その行が何であるか」を表さないため (`_COMPOSITE_KEYS` の
        コメント参照)。複合キーは 1 entry が複数行に当たりうる。
        """
        if comp_fields and all(f in entry for f in comp_fields):
            key = tuple((entry[f] or '').strip() for f in comp_fields)
            found = (comp_objs or {}).get(key)
            if found:
                return found
            shown = ', '.join(f'{f}={entry[f]!r}' for f in comp_fields)
            self.stdout.write(self.style.WARNING(
                f'  {model_name} {shown} not found, skipping.'
            ))
            return []

        if nat_field and nat_field in entry:
            obj = nat_objs.get(entry[nat_field])
            if obj is not None:
                return [obj]
            self.stdout.write(self.style.WARNING(
                f'  {model_name} {nat_field}={entry[nat_field]!r} not found, skipping.'
            ))
            return []

        if 'id' in entry:
            obj = objs.get(entry['id'])
            if obj is not None:
                return [obj]
            self.stdout.write(self.style.WARNING(
                f'  {model_name} id={entry["id"]} not found, skipping.'
            ))
            return []

        self.stdout.write(self.style.WARNING(
            f'  {model_name}: entry に "id" も "{nat_field}" も無い、skipping.'
        ))
        return []

    def _source_matches(self, entry, obj, en_fields, model_name):
        """entry が翻訳元の日本語を持つなら、DB の現在値と一致するか検証する。"""
        for en_field in en_fields:
            base = en_field[:-3]  # 'content_en' -> 'content'
            if base not in entry:
                continue  # source 未指定 = 検証しない (後方互換)
            actual = (getattr(obj, base, '') or '').strip()
            expected = (entry[base] or '').strip()
            if actual != expected:
                self.stdout.write(self.style.ERROR(
                    f'  {model_name} pk={obj.pk} の {base} が翻訳元と違う、skipping.\n'
                    f'      翻訳元: {expected[:60]!r}\n'
                    f'      DB    : {actual[:60]!r}'
                ))
                return False
        return True
