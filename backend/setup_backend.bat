@echo off
REM One-time setup: creates a virtual environment, installs packages, trains the model, runs tests.
cd /d "%~dp0"
echo === PVMS backend setup ===
if not exist .venv\Scripts\activate.bat (
  py -3 -m venv .venv 2>nul || python -m venv .venv
)
call .venv\Scripts\activate.bat || (echo Could not create virtual environment. Is Python installed? & pause & exit /b 1)
python -m pip install --upgrade pip
python -m pip install -r requirements.txt || (echo Package install failed. & pause & exit /b 1)
if not exist dataset.csv (
  echo.
  echo dataset.csv not found. Copy OBD2_panel_opel_2012.csv\dataset.csv into this backend folder.
  pause
  exit /b 1
)
python train_model.py || (echo Training failed. & pause & exit /b 1)
python -m pytest -q
echo.
echo Setup complete. Start the server with run_server.bat
pause
