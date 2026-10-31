@echo off
setlocal EnableExtensions DisableDelayedExpansion
chcp 65001 >nul
cd /d "%~dp0"

where python >nul 2>nul
if errorlevel 1 (
  echo 未找到 Python。请安装 Python 3.10 或更高版本后重试。
  pause
  exit /b 1
)

python -c "import flask,pymysql,dotenv" >nul 2>nul
if errorlevel 1 (
  echo 正在安装 Python 依赖...
  python -m pip install -r requirements.txt
  if errorlevel 1 goto :failed
)

python scripts\check_db.py
if errorlevel 1 (
  echo MySQL 未启动或 retail_marketing_codex 不可用。请先启动 127.0.0.1:3308 的 MySQL。
  pause
  exit /b 1
)

python scripts\setup_demo_accounts.py
if errorlevel 1 goto :failed

echo 正在启动 Web 服务并预热经营统计，请稍候...
start "RetailMarketingWeb" /b python run.py
python scripts\wait_for_warmup.py
if errorlevel 1 goto :failed

start "" "http://127.0.0.1:5000"
echo 预热完成，浏览器已打开：http://127.0.0.1:5000
echo 如需停止服务，请关闭本窗口或结束 python run.py 进程。
pause
exit /b 0

:failed
echo 启动或统计预热失败，请查看上方中文提示。
pause
exit /b 1
