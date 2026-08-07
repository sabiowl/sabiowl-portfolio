#!/usr/bin/env bash
# コミットメッセージ先頭の UTF-8 BOM (EF BB BF) を自動除去する commit-msg フック。
#
# 【背景】
# Windows PowerShell 5.1 の Set-Content / Out-File は UTF-8 出力時に BOM を付ける。
# 5.1 には -Encoding utf8NoBOM が存在しないため、`git commit -F <file>` 方式で
# コミットすると件名が "﻿feat(...): ..." となり、GitHub 上で不可視文字が混入する。
# 実際に直近 200 コミット中 162 件が BOM 付きで記録されていた。
#
# 【方針】
# 拒否 (exit 1) ではなく自動除去にする。BOM はユーザーの意図ではなく
# シェルの実装都合なので、コミットを止める価値がない。
#
# 【有効化】
#   pre-commit install --hook-type commit-msg
set -euo pipefail

# commit-msg ステージ以外 (例: CI の `pre-commit run --all-files`) から
# 引数なしで呼ばれた場合は何もせず正常終了する。CI を落とす価値がない。
if [ "$#" -eq 0 ] || [ ! -f "${1:-}" ]; then
  exit 0
fi

msg_file="$1"

# 先頭 3 バイトが EF BB BF かを判定
if [ "$(head -c 3 "$msg_file" | od -An -tx1 | tr -d ' \n')" = "efbbbf" ]; then
  tail -c +4 "$msg_file" > "$msg_file.nobom"
  mv "$msg_file.nobom" "$msg_file"
  echo "commit-msg: 先頭の UTF-8 BOM を除去しました。"
fi
