#!/usr/bin/env bash
# Render.com デプロイ時のビルドスクリプト
# buildCommand: "./build.sh" として render.yaml または Render ダッシュボードに設定する
set -o errexit

echo "=== 依存パッケージをインストール ==="
pip install -r requirements.txt

echo "=== 静的ファイルを収集 ==="
python manage.py collectstatic --no-input

echo "=== データベースマイグレーション ==="
# 【FEAT-394 (2026-05-30)】Neon 移行: migrate は Direct 接続で実行
# PgBouncer transaction mode (Neon Pooled) では DDL (CREATE/ALTER) や
# advisory lock が制約されるため、Direct 接続文字列 (DATABASE_URL_DIRECT) を
# 一時的に DATABASE_URL に上書きして migrate を実行する。
# DATABASE_URL_DIRECT 未設定環境 (Render PostgreSQL 移行前 / ローカル SQLite 等)
# では DATABASE_URL をそのまま使用 (シェルパラメータ展開の default)。
DATABASE_URL="${DATABASE_URL_DIRECT:-$DATABASE_URL}" python manage.py migrate

echo "=== マイグレーション適用状況 ==="
python manage.py showmigrations api

# 【arch_review 20260530 P1-3 (2026-05-30) 解消】
# 旧: mock_login.html / mock_notifications.html を本番デプロイ時に削除する保険
# 新: 該当 2 ファイルを git rm で完全撤去済み、保険の rm 行も不要化
# → build.sh が rm を忘れて dead path が production 配信される回帰リスクを構造解消

echo "=== ビルド完了 ==="
