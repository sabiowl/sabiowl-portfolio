"""【FEAT-489 Phase 4】i18n カバレッジ確認コマンド。

5 モデル × _en フィールドの空欄率を報告する。リリース前の確認・CI チェックとして使用。

使用例:
    python manage.py check_i18n_coverage
    python manage.py check_i18n_coverage --fail-on-empty

--fail-on-empty 指定時、1 件でも空欄があれば exit code 1 で終了 (CI ゲートに使用可)。
"""
from django.core.management.base import BaseCommand

from api.i18n_targets import i18n_targets


class Command(BaseCommand):
    help = 'Check i18n _en field coverage across all master-data models'

    def add_arguments(self, parser):
        parser.add_argument(
            '--fail-on-empty',
            action='store_true',
            default=False,
            help='Exit with code 1 if any _en field is empty',
        )

    def handle(self, *args, **options):
        # 【2026-08-02】Windows の既定コンソール codec (cp932) は ✅/⚠️/❌ を
        # encode できず UnicodeEncodeError で落ちる。開発機が Windows なので
        # 「英訳を投入したら必ず叩くコマンド」がそのままでは動かなかった。
        # 出力先を UTF-8 に張り替える (reconfigure 不可の stream は無視)。
        try:
            self.stdout._out.reconfigure(encoding='utf-8')
        except (AttributeError, ValueError):
            pass

        # 【2026-08-02】手書きの 5 model リストをやめ、model から `_en` を
        # 自動列挙する。手書きだったせいで `Job.job_name_en` が対象から漏れ、
        # 「空欄を検出するコマンドが、一番空欄の field を見ていない」状態に
        # なっていた (api/i18n_targets.py の docstring 参照)。
        checks = i18n_targets()

        total_empty = 0
        total_untranslatable = 0

        for model_name, model_cls, fields in checks:
            total = model_cls.objects.count()
            if total == 0:
                self.stdout.write(f'  {model_name}: (no records)')
                continue

            for field in fields:
                base = field[:-3]  # 'content_en' -> 'content'

                # 【2026-08-03】日本語の原文が空の行は分母から外す。
                #
                # 実測で 427 件の空欄のうち 134 件 (Character.tagline 14 /
                # TaskSuggestion.hint 120) は **ja 側が空**だった。訳す元が無い
                # ので永久に埋まらず、--fail-on-empty が構造的に緑にならない。
                # これでは release gate として使えないため、翻訳可能なものだけを
                # 対象にする。除外件数は下に出して隠さない。
                untranslatable = model_cls.objects.filter(
                    **{f'{base}__exact': ''}
                ).count()
                translatable = total - untranslatable

                empty = model_cls.objects.filter(**{
                    f'{field}__exact': '',
                }).exclude(**{f'{base}__exact': ''}).count()

                if translatable == 0:
                    self.stdout.write(
                        f'  －  {model_name}.{field}: ja 原文が全件空のため対象外'
                    )
                    total_untranslatable += untranslatable
                    continue

                filled = translatable - empty
                pct = int(filled / translatable * 100)
                status = '✅' if empty == 0 else ('⚠️' if pct >= 50 else '❌')
                note = (f'  (ja 空 {untranslatable} 件を除外)'
                        if untranslatable else '')
                self.stdout.write(
                    f'  {status} {model_name}.{field}: '
                    f'{filled}/{translatable} filled ({pct}%){note}'
                )
                total_empty += empty
                total_untranslatable += untranslatable

        if total_empty == 0:
            self.stdout.write(self.style.SUCCESS('\n翻訳可能な _en フィールドは全て埋まっています。'))
        else:
            msg = f'\n空欄 _en フィールド合計: {total_empty} 件 (翻訳可能なもののみ)'
            self.stdout.write(self.style.WARNING(msg))

        if total_untranslatable:
            self.stdout.write(
                f'※ ja 原文が空のため対象外: {total_untranslatable} 件'
            )

        dark_pools = self._check_sabi_pools()

        if options['fail_on_empty'] and (total_empty > 0 or dark_pools):
            raise SystemExit(1)

    # ── 【BUG-145】プール健全性 ────────────────────────────────────────────
    def _check_sabi_pools(self) -> int:
        """`SabiMessage` の全プールに有効な行が 1 件以上あるかを検査する。

        ## なぜ空欄率だけでは足りないか (実際に起きたこと)

        上の `_en` 空欄チェックは **`is_active` を見ていない**。`sabi_loader` は
        DB に active 行が 0 件のプールを YAML の初期値で埋めるため、
        プールを丸ごと無効化すると

          - 日本語: YAML に同じセリフがあるので **見た目が変わらない**
          - 英語:   YAML に `_en` が無いので **日本語に落ちる**

        となる。dev では 2026-06-26 から 2026-08-16 まで `home_none_done` が
        暗転していたが、本コマンドは **SabiMessage 100% filled** と報告し続けた。
        `--fail-on-empty` を release gate に使っている以上、
        **gate が緑のまま英語が壊れる**経路を塞いでおく必要がある。

        戻り値: 問題のあるプール数 (0 なら健全)。
        """
        from api.models import SabiMessage
        from api.sabi_loader import _POOL_TO_YAML_PATH

        if SabiMessage.objects.count() == 0:
            # seed されていない環境 (一部のテスト DB 等) では検査しない。
            # ここで落とすと「レコードが無いだけ」で CI が赤くなる。
            self.stdout.write('  － SabiMessage: (no records) — プール検査はスキップ')
            return 0

        active_pools = set(
            SabiMessage.objects
            .filter(is_active=True)
            .values_list('pool', flat=True)
            .distinct()
        )
        dark = sorted(set(_POOL_TO_YAML_PATH) - active_pools)

        if not dark:
            self.stdout.write(
                f'  ✅ SabiMessage プール: {len(_POOL_TO_YAML_PATH)} プールすべてに有効な行あり'
            )
            return 0

        self.stdout.write(self.style.WARNING(
            f'\n❌ 有効な行が 0 件のプール: {len(dark)} 件'
        ))
        for pool in dark:
            inactive = SabiMessage.objects.filter(pool=pool, is_active=False).count()
            reason = (f'{inactive} 件すべて is_active=False'
                      if inactive else 'レコード自体が存在しない')
            self.stdout.write(f'     - {pool}: {reason}')
        self.stdout.write(
            '   → このプールは YAML の初期値に戻ります。'
            '日本語では気付けず、英語だけが日本語表示になります。'
        )
        return len(dark)
