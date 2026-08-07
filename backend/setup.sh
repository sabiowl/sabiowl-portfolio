#!/bin/bash
set -e

echo "============================================"
echo " HabitGrow Django Backend セットアップ"
echo "============================================"
echo

# 仮想環境の作成
echo "[1/6] 仮想環境を作成しています..."
python3 -m venv venv
echo "      OK"

# 仮想環境のアクティベート
echo "[2/6] 仮想環境をアクティベートしています..."
source venv/bin/activate
echo "      OK"

# パッケージインストール
echo "[3/6] パッケージをインストールしています..."
pip install -r requirements.txt
echo "      OK"

# .env ファイルの確認
echo "[4/6] .env ファイルを確認しています..."
if [ ! -f .env ]; then
    echo "      .env が見つかりません。.env.example からコピーします..."
    cp .env.example .env
    echo "      .env を作成しました。必要に応じて編集してください。"
else
    echo "      .env が存在します。スキップします。"
fi
echo "      OK"

# マイグレーション
echo "[5/6] データベースをセットアップしています..."
python manage.py makemigrations
python manage.py migrate
echo "      OK"

# 初期データ投入
echo "[6/6] 初期データを投入しています..."
python manage.py seed

echo
echo "============================================"
echo " セットアップ完了！"
echo "============================================"
echo
echo "開発サーバーを起動するには:"
echo "  source venv/bin/activate"
echo "  python manage.py runserver"
echo
echo "アクセスURL:"
echo "  http://127.0.0.1:8000/api/health/"
echo "  http://127.0.0.1:8000/admin/"
