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

        if options['fail_on_empty'] and total_empty > 0:
            raise SystemExit(1)
