# PVMS: Predictive Vehicle Maintenance System

Final Year Project (BSCS), Faculty of Computing, Riphah International University, Islamabad.
Supervisor: Sir Muhammad Akmal.

PVMS warns a driver about a developing engine fault **before the check-engine light comes on**.
An ELM327 Bluetooth LE scanner reads the car's standard OBD-II data, the Flutter app sends
30-reading windows to a FastAPI server, and a hybrid model (universal OBD-II rules plus a learned
normal-behaviour model with an Isolation Forest) returns a 0-100 health index, plain-English
findings and a Time-To-Failure estimate.

Scope: a proof of concept for everyday petrol cars in Pakistan (for example Suzuki Alto, Honda Civic).
PVMS only reads from the car. It never writes to the ECU and never clears fault codes.
The model advises; the driver and the mechanic decide.

---

## How it works

```
 ELM327 BLE scanner --BLE--> Flutter app (phone) --HTTP/JSON over Wi-Fi--> FastAPI server (laptop)
   or Simulator               windowing, UI, sqflite,                       features -> rules -> ML
                              offline queue                                 per-car learning, TTF
                     <------- health index, findings, explanations, latency --------
```

1. **Data source.** The ELM327 scanner polls standard Mode 01 PIDs plus `ATRV` battery voltage,
   about one reading per second. The simulator replays a real recorded Opel trip with optional
   injected faults. It is used for development, testing and demos only.
2. **Windows.** The app keeps the last 30 readings and sends them every 15 readings (50 % overlap),
   exactly like the training data. A window never crosses a trip or a gap of more than 5 s.
3. **Features and rules.** The server computes 17 window features (`backend/pvms/features.py`, the
   same code for training and live use) and runs the universal OBD-II rules (`backend/pvms/rules.py`).
4. **ML on a warm engine only** (RPM >= 400 and coolant >= 75 °C). Gradient-boosting regressors predict
   what each health signal should be for the current driving conditions; the residuals go into an
   Isolation Forest plus learned per-signal limits.
5. **Scoring.** Anomaly ratio `u = max(Isolation Forest ratio, worst signal ratio)`. `u >= 1` is an
   anomaly. Health = 100 at `u <= 0.6`, 50 at `u = 1`, 0 at `u = 2`. An ML alert needs 2 of the last
   3 windows. Rules cap the health index (critical <= 20, warning <= 45, info <= 85).
   The score is a **health index, not a probability**.
6. **New cars.** A real car is never judged by the Opel base model. It starts with rules only,
   learns from 60 healthy warm-engine windows (about 18 min, any number of trips) and then uses the
   base model re-centred on that car.
7. **Offline first.** If the server is unreachable the window is queued in sqflite, the phone runs
   its own overheating and charging checks, the queue syncs automatically every 30 s, and trip
   summaries are rebuilt from the stored predictions.
8. **Time-To-Failure.** Linear trend of per-trip indicators extrapolated to their fault limits
   (needs at least 5 trips and R² >= 0.3). It is an estimate, never a guaranteed failure date.
9. **Privacy.** No GPS or location tracking. Real-car recordings stay on the laptop
   (`backend/recordings/`, excluded from git).

---

## Tech stack

| Layer | Technology |
|---|---|
| Mobile app | Flutter 3.35 / Dart 3.9, Android (iOS needs a Mac and is not built) |
| App packages | flutter_blue_plus 1.x (kept below 2.0), sqflite, path, http, shared_preferences, wakelock_plus |
| State management | ChangeNotifier (`MonitoringController`) + ListenableBuilder |
| Local database | SQLite on the phone via sqflite (trips, predictions, offline queue) |
| Backend | Python 3.14, FastAPI, Pydantic v2, uvicorn |
| Machine learning | scikit-learn: HistGradientBoostingRegressor normal-behaviour models, Isolation Forest on robust-scaled residuals, learned per-signal limits (joblib bundle) |
| Hardware | ELM327-compatible Bluetooth LE OBD-II scanner (Vgate iCar Pro 2S recommended) |
| Dataset | OBD2_panel_opel_2012: one 2012 Opel, 789,373 readings, 22 refuelling segments |
| CI | GitHub Actions on pull requests: `flutter analyze` + `flutter test`, backend import check + `pytest` |

---

## Repository structure

```
PVMS_Flutter_App/
|-- .github/                  pull request template, issue forms, CI workflows
|-- lib/                      Flutter app
|   |-- main.dart             app shell: Dashboard, History, Settings
|   |-- models/               TelemetrySample, PredictionResult (JSON contract with the API)
|   |-- screens/              dashboard, history + trip detail, settings, scanner pairing
|   |-- services/             MonitoringController, ApiService, DatabaseHelper, AppSettings
|   |   `-- obd/              ELM327 BLE reader, PID decoding, simulator, fault scenarios
|   `-- widgets/              shared UI: health gauge, finding cards, trend chart
|-- test/                     Flutter unit and widget tests
|-- assets/sim/               recorded Opel trip + per-segment history for the simulator demo
|-- backend/
|   |-- main.py               FastAPI app
|   |-- train_model.py        training + full evaluation report
|   |-- export_sim_trace.py   exports the simulator trip from the dataset
|   |-- pvms/                 shared engine: signals, features, rules, engine, faults, forecast, dataset
|   |-- tests/                API tests on a real trip the model never saw
|   |-- reports/              evaluation report, JSON and charts
|   |-- requirements.txt
|   |-- setup_backend.bat     one-time setup
|   |-- run_server.bat        starts the server
|   `-- (local only)          dataset.csv, saved_models/, recordings/, .venv/
|-- docs/                     final report, user guide, API/model guide, deployment guide
`-- android/ ios/ ...         Flutter platform folders
```

### API endpoints (`backend/main.py`)

| Endpoint | Purpose |
|---|---|
| `GET /` | server status, model loaded, model version |
| `GET /model` | model information and evaluation metrics |
| `POST /predict` | one window of readings -> health index, status, findings, explanations, latency |
| `POST /calibrate` | learn a car from one recorded healthy drive (manual alternative to automatic learning) |
| `GET /vehicles/{id}` | learning status of a car |
| `DELETE /vehicles/{id}` | forget a car's profile and learn again ("Re-learn") |
| `POST /forecast` | per-trip summaries -> Time-To-Failure estimate |

Interactive docs: `http://localhost:8000/docs` while the server is running.

---

## Getting started (Windows, PowerShell)

### Prerequisites

- Git
- Flutter 3.35 (stable channel) with the Android SDK (Android Studio), and an Android phone with
  USB debugging or an emulator
- Python 3.14
- The dataset file `dataset.csv` from OBD2_panel_opel_2012 (about 187 MB, not stored in the repo)
- For real-car use: an ELM327-compatible Bluetooth LE scanner

### 1. Clone

```powershell
git clone https://github.com/kashan980/PVMS_Flutter_App.git
cd PVMS_Flutter_App
git switch develop
```

### 2. Backend (laptop)

Copy `dataset.csv` into `backend\`, then:

```powershell
cd backend
.\setup_backend.bat    # once: virtual environment, packages, trains the model, runs the tests
.\run_server.bat       # every time: prints the laptop's IPv4 address, starts the server on port 8000
```

If Windows Firewall asks, allow Python on **private** networks. Keep the server window open.

### 3. App

```powershell
flutter pub get
flutter run
```

In the app: **Settings -> Prediction server** -> `http://<laptop-IPv4>:8000` -> **Save & test**.

- Phone and laptop must be on the same Wi-Fi or phone hotspot. Campus Wi-Fi may block
  device-to-device traffic; use a hotspot.
- Android emulator: `http://10.0.2.2:8000`
- Over USB: `adb reverse tcp:8000 tcp:8000`, then `http://127.0.0.1:8000`

After any change to `pubspec.yaml`: run `flutter pub get`, then stop the app and run `flutter run`
again (a hot restart cannot add plugins).

### Demo without a car

- **Settings -> Data source -> Simulator**, replay speed 1x, 4x or 10x.
- **Dashboard -> Simulator fault**: overheating, vacuum leak, leaking injector (subtle, only the
  ML model catches it), alternator failure, dead O2 sensor, thermostat stuck open.
- **Settings -> Load Opel demo history** imports the dataset's 22 refuelling segments so the
  Time-To-Failure card shows the real fuel-trim trend.
- **Settings -> Demo: treat simulator as a new car** shows the rules-only -> learning -> ML flow.

### Real car

1. **Settings -> Data source -> OBD-II scanner -> Pair**, then set a **Vehicle ID** (for example `alto-2022`).
2. Engine on, **Start trip**. Stored and pending fault codes (Mode 03/07) are read on connection.
3. After about 18 minutes of warm-engine driving the "Learning this car" bar completes and the
   ML model switches on automatically.
4. The server saves the raw readings to `backend/recordings/<vehicle>/<date>.csv` on the laptop.

---

## Running the tests

```powershell
# Flutter (repository root)
flutter analyze        # must report "No issues found!"
flutter test

# Backend (needs the trained model: run setup_backend.bat or train_model.py first)
cd backend
.\.venv\Scripts\python.exe -m pytest -q
```

After any change to the features or the model code:

```powershell
cd backend
.\.venv\Scripts\python.exe train_model.py    # retrains and rewrites reports/evaluation_report.md
.\run_server.bat                              # restart the server with the new model
```

**Continuous integration.** Every pull request into `develop` or `main` runs the Flutter job
(`flutter analyze`, `flutter test`) when app files change and the backend job (import check,
`pytest`) when backend files change. The dataset and the trained model are not in the repository,
so in CI the API tests that need the model are skipped. The reviewer therefore runs the full
backend test suite locally before merging.

---

## Model results (v2.0.0)

Time-based split: trained on refuelling segments 1-15, thresholds set on validation segments 16-18,
tested on segments 19-22 (months the model never saw). The dataset has no labelled failures, so
faults are injected into held-out real driving.

| Detector | Precision | Recall | F1 |
|---|---|---|---|
| Rules only | 0.915 | 0.553 | 0.689 |
| ML model only | 0.962 | 0.671 | 0.790 |
| **Hybrid PVMS** | **0.912** | **0.775** | **0.838** |

- False alarms on real, unseen driving: 3.3 % of windows (hybrid).
- The two layers cover each other's blind spots: a mild leaking injector is caught 0 % by rules and
  73 % by the ML model; a mild lazy O2 sensor is caught 4 % by the ML model and 45 % by rules.
- A different healthy car judged by the un-adapted Opel model: 97.4 % false alarms. After automatic
  learning: 3.1 % (simulated by shifting the Opel's normal levels).

Full report: [`backend/reports/evaluation_report.md`](backend/reports/evaluation_report.md)

### Limitations

- All training data comes from one car (a 2012 Opel).
- Faults are injected into real data; no recorded breakdowns exist in the dataset.
- The "other car" test is simulated by level shifts. Validation on a real Pakistani car with the
  scanner is still pending.
- Time-To-Failure is trend extrapolation, not a learned failure date. Sudden failures cannot be predicted.
- Learning assumes the car is healthy during its first ~18 minutes of warm driving, so the first
  drive should be in a serviced car.

---

## Branching and commit rules

| Branch | Purpose |
|---|---|
| `main` | Stable. Receives `develop` only at the end of a milestone (v0.1, v0.2, v1.0) through a pull request. Protected. |
| `develop` | Integration branch. All work merges here through pull requests. Protected. |
| `feature/<name>-<module>` | One module, always branched from the latest `develop`, e.g. `feature/kashan-backend-engine`, `feature/sinwan-local-storage` |
| `fix/<name>-<bug>` | One bug fix, branched from `develop`, e.g. `fix/sinwan-offline-sync` |

**Commits** follow [Conventional Commits](https://www.conventionalcommits.org/):
`type(scope): short imperative summary`, under 72 characters.

- Types: `feat`, `fix`, `test`, `refactor`, `docs`, `chore`, `style`
- Scopes: `app`, `dashboard`, `history`, `settings`, `obd`, `db`, `api`, `backend`, `engine`,
  `rules`, `features`, `forecast`, `ci`, `repo`, `readme`
- Example: `feat(db): rebuild trip summary from stored predictions`
- One small, working change per commit, with its test where possible.
- Commit on the day the work is done. Never force-push and never rewrite pushed history.

**Pull requests**

- One pull request per module or fix, into `develop`, using the pull request template.
- Link the issue (`Closes #12`) so it closes automatically when merged.
- The other team member reviews, checks out the branch, runs the tests locally and then merges.

---

## Team

| Member | Role | WBS responsibilities (approved proposal) |
|---|---|---|
| Kashan Shahid | Mobile lead, ML and backend lead | 2 Presentation layer (Flutter UI) · 3 Business logic (FastAPI, preprocessing, ML) · 5 API routes and latency (with Sinwan) · 1 Documentation (shared) |
| Sinwan Haider | Local data and hardware | 4 Local data management (sqflite) · 6 Physical layer (ELM327, Bluetooth, road testing) · 5 API routes and latency (with Kashan) · 1 Documentation (shared) |

Supervisor: Sir Muhammad Akmal, Lecturer, Riphah International University.
