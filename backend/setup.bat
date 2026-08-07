@echo off
cd /d %~dp0

echo ============================================
echo  HabitGrow Django Backend セットアップ
echo ============================================
echo.

echo [1/6] 仮想環境を作成しています...
python -m venv venv
echo       OK

echo [2/6] 仮想環境をアクティベートしています...
call venv\Scripts\activate
echo       OK

echo [3/6] パッケージをインストールしています...
pip install -r requirements.txt
echo       OK

echo [4/6] .env ファイルを確認しています...
if not exist .env (
    echo       .env が見つかりません。.env.example からコピーします...
    copy .env.example .env
    echo       .env を作成しました。必要に応じて編集してください。
) else (
    echo       .env が存在します。スキップします。
)
echo       OK

echo [5/6] データベースをセットアップしています...
python manage.py makemigrations
python manage.py migrate
echo       OK

echo [6/6] 初期データを投入しています...
python manage.py seed

echo.
echo ============================================
echo  セットアップ完了！
echo ============================================
echo.
echo 開発サーバーを起動するには run.bat を実行してください。
echo.
pause
