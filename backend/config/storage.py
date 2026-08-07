"""【2026-06-29 hotfix】WhiteNoise の staticfiles storage を manifest_strict=False で wrap。

【背景】
本番 Django admin の `/admin/api/gachareward/` 等で 500 エラーが発生していた。
真因は `ValueError: Missing staticfiles manifest entry for 'admin/css/base.css'` -
DEBUG=False + `CompressedManifestStaticFilesStorage` (manifest_strict=True デフォルト)
の組み合わせで、manifest に entry が無いファイルを `{% static %}` テンプレート
タグ経由で参照したときに ValueError を投げる仕様。

【再現条件】
- `python manage.py collectstatic --no-input` が **部分失敗** している
  (build log で admin app の static が collect されない / 古い manifest が残る等)
- ローカルでは `collectstatic` 実行後は 200 で動作、未実行 + DEBUG=False で 500 再現

【本ファイルの役割】
- `WhiteNoiseStaticFilesStorage(CompressedManifestStaticFilesStorage)` で
  `manifest_strict = False` を上書き。
- manifest entry が無いファイルを `{% static %}` で参照しても 500 を投げず、
  hash 化されていない素の URL (`/static/admin/css/base.css` 等) を返してフォールバック。
- ブラウザは 404 を取得するが、admin の HTML 自体は描画されるため操作可能 (CSS なし)。
- collectstatic が完全成功している通常運用では本フォールバックは発動せず、
  manifest 経由の hash 化 URL がそのまま使われる (挙動・パフォーマンス変化なし)。

【本来の根本対処】
- build.sh の `collectstatic --no-input` ステップが本番でも完全に成功する状態を保証する
  (本ファイルはあくまで「失敗時の安全弁」)。
- Render の deploy log で `static files copied` の件数を確認し、ローカルと一致するか
  チェックすると collectstatic 部分失敗の早期検出が可能。
"""
from whitenoise.storage import CompressedManifestStaticFilesStorage


class WhiteNoiseStaticFilesStorage(CompressedManifestStaticFilesStorage):
    """manifest entry 不在を 500 ではなく素 URL フォールバックで処理する storage。

    `CompressedManifestStaticFilesStorage` (WhiteNoise 公式) を継承し、
    `manifest_strict = False` を上書きするだけのシンプルな wrapper。
    gzip / brotli 圧縮や長期キャッシュ等の WhiteNoise 機能は維持される。
    """
    manifest_strict = False
