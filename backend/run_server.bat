@echo off
REM Starts the PVMS prediction server so the phone can reach it on the local network.
cd /d "%~dp0"
if not exist .venv\Scripts\activate.bat (
  echo Run setup_backend.bat first.
  pause
  exit /b 1
)
call .venv\Scripts\activate.bat
if not exist saved_models\pvms_model.joblib python train_model.py
echo.
echo ===============================================================
echo  In the PVMS app go to Settings and enter   http://YOUR-IP:8000
echo  using one of these addresses (phone on the same Wi-Fi/hotspot):
ipconfig | findstr /R /C:"IPv4"
echo  If Windows Firewall asks, allow Python on PRIVATE networks.
echo  API docs: http://localhost:8000/docs
echo ===============================================================
echo.
python -m uvicorn main:app --host 0.0.0.0 --port 8000
pause
