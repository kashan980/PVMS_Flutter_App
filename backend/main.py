"""PVMS Predictive Engine API.

Run (from the backend folder):
    python -m uvicorn main:app --host 0.0.0.0 --port 8000
Docs: http://localhost:8000/docs

The phone sends a *window* of ~30 raw OBD-II readings; the server computes the same
features used in training, runs the universal rules + the learned model, and returns
a 0–100 health score with plain-English findings.

Which model judges a window?
  * Simulator / Opel demo (use_base_model=true) → the base model trained on the Opel.
  * A real car (vehicle_id given, use_base_model=false):
      1. LEARNING  — no profile yet: universal rules only (they hold for every car). Healthy
                     warm windows are stored; nothing car-specific is judged yet.
      2. AUTOMATIC — after AUTO_CALIBRATION_WINDOWS healthy warm windows (~18 min of warm
                     driving, can span several trips) the base model is re-centred on
                     this car (pvms.engine.recenter_bundle) and saved.
      3. VEHICLE   — rules + the car's own adapted model.
"""
from __future__ import annotations

import csv
import datetime as dt
import os
import re
import sys
import time
from typing import Optional

import joblib
import numpy as np
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from pvms import MODEL_VERSION  # noqa: E402
from pvms.engine import analyse_window, recenter_bundle  # noqa: E402
from pvms.features import MIN_WINDOW_SAMPLES, MODEL_FEATURES, WINDOW_SIZE, regime, window_features  # noqa: E402
from pvms.forecast import forecast_trips  # noqa: E402
from pvms.signals import ALL_SIGNALS  # noqa: E402

MODEL_PATH = os.path.join(HERE, "saved_models", "pvms_model.joblib")
VEHICLE_DIR = os.path.join(HERE, "saved_models", "vehicles")
MIN_CALIBRATION_WINDOWS = 40       # manual /calibrate: ≈ 12 min of warm-engine driving
AUTO_CALIBRATION_WINDOWS = 60      # automatic learning: ≈ 18 min of warm-engine driving
RECORDINGS_DIR = os.path.join(HERE, "recordings")   # raw real-car data for the report / future training

app = FastAPI(title="PVMS Predictive Engine API", version=MODEL_VERSION)

try:
    BASE = joblib.load(MODEL_PATH)
    print(f"[PVMS] Model v{BASE['version']} loaded ({BASE['n_train_windows']} training windows).")
except Exception as e:  # pragma: no cover
    BASE = None
    print(f"[PVMS] Could not load {MODEL_PATH}: {e}\n       Run:  python train_model.py")

_vehicle_cache: dict[str, dict] = {}


# ----------------------------------------------------------------- schemas --
class Sample(BaseModel):
    timestamp_ms: int = Field(..., description="Unix epoch milliseconds when the reading was taken")
    rpm: Optional[float] = None
    speed: Optional[float] = None
    throttle_pos: Optional[float] = None
    engine_load: Optional[float] = None
    coolant_temp: Optional[float] = None
    intake_temp: Optional[float] = None
    short_fuel_trim_1: Optional[float] = None
    long_fuel_trim_1: Optional[float] = None
    o2_b1s1: Optional[float] = None
    battery_voltage: Optional[float] = None
    maf: Optional[float] = None
    intake_pressure: Optional[float] = None


class PredictRequest(BaseModel):
    samples: list[Sample] = Field(..., min_length=MIN_WINDOW_SAMPLES)
    vehicle_id: Optional[str] = None
    use_base_model: bool = Field(True, description="True only for the Opel dataset / simulator. A real car "
                                                    "should send false so it is never judged by the Opel's normal.")
    auto_learn: bool = Field(True, description="Learn this vehicle's profile automatically while driving")
    record: bool = Field(True, description="Save raw readings of real cars to backend/recordings/")
    trip_elapsed_s: Optional[float] = Field(None, description="Seconds since engine start (thermostat check)")
    recent_model_flags: Optional[list[bool]] = Field(None, description="model_anomaly of previous windows this trip")
    client_sent_ms: Optional[int] = Field(None, description="Phone clock when the request was sent (latency)")


class CalibrateRequest(BaseModel):
    vehicle_id: str
    samples: list[Sample] = Field(..., min_length=WINDOW_SIZE * 10)


class TripSummary(BaseModel):
    km: float = Field(..., description="Odometer / cumulative km at end of trip")
    health: Optional[float] = None
    ltft_mean: Optional[float] = None
    volt_mean: Optional[float] = None
    coolant_mean: Optional[float] = None


class ForecastRequest(BaseModel):
    trips: list[TripSummary]


# ----------------------------------------------------------------- helpers --
def _safe_id(vehicle_id: str) -> str:
    vid = re.sub(r"[^A-Za-z0-9_-]", "_", vehicle_id.strip())[:64]
    if not vid:
        raise HTTPException(400, "vehicle_id is empty")
    return vid


def _profile_path(vid: str) -> str:
    return os.path.join(VEHICLE_DIR, f"{vid}.joblib")


def _learning_path(vid: str) -> str:
    return os.path.join(VEHICLE_DIR, f"{vid}_learning.npy")


def _save_profile(vid: str, b: dict) -> None:
    """Only the per-car offsets are stored; the heavy estimators come from the base model."""
    os.makedirs(VEHICLE_DIR, exist_ok=True)
    joblib.dump({"base_model_id": BASE.get("model_id"), "resid_loc": b["resid_loc"],
                 "resid_scale": b["resid_scale"], "n_calibration_windows": b["n_calibration_windows"],
                 "created_ms": int(time.time() * 1000)}, _profile_path(vid))
    _vehicle_cache[vid] = b


def _vehicle_bundle(vid: Optional[str]):
    if not vid or BASE is None:
        return None
    if vid in _vehicle_cache:
        return _vehicle_cache[vid]
    path = _profile_path(vid)
    if not os.path.exists(path):
        return None
    prof = joblib.load(path)
    if prof.get("base_model_id") != BASE.get("model_id"):   # base was retrained → re-learn
        return None
    b = dict(BASE)
    b.update(resid_loc=prof["resid_loc"], resid_scale=prof["resid_scale"], kind="recentred",
             n_calibration_windows=prof["n_calibration_windows"], source=f"vehicle:{vid}")
    _vehicle_cache[vid] = b
    return b


def _learning_count(vid: str) -> int:
    p = _learning_path(vid)
    return int(np.load(p).shape[0]) if os.path.exists(p) else 0


def _learn(vid: str, feats: dict) -> tuple[int, bool]:
    """Store one healthy warm window; calibrate automatically when enough are collected."""
    p = _learning_path(vid)
    row = np.array([[feats.get(f, np.nan) for f in MODEL_FEATURES]], dtype=float)
    F = np.vstack([np.load(p), row]) if os.path.exists(p) else row
    os.makedirs(VEHICLE_DIR, exist_ok=True)
    np.save(p, F)
    if len(F) >= AUTO_CALIBRATION_WINDOWS:
        _save_profile(vid, recenter_bundle(BASE, F, source=f"vehicle:{vid}"))
        return len(F), True
    return len(F), False


RECORD_FIELDS = ["timestamp_ms"] + ALL_SIGNALS


def _record(vid: str, samples: list[Sample]) -> None:
    """Append raw readings to recordings/<vehicle>/<date>.csv.

    Windows overlap by 50 % and offline windows arrive late, so rows can repeat or be out of
    order: de-duplicate and sort by timestamp_ms when loading (pvms.dataset.load_recordings).
    """
    day = dt.datetime.fromtimestamp(samples[0].timestamp_ms / 1000).strftime("%Y-%m-%d")
    folder = os.path.join(RECORDINGS_DIR, vid)
    os.makedirs(folder, exist_ok=True)
    path = os.path.join(folder, f"{day}.csv")
    new = not os.path.exists(path)
    with open(path, "a", newline="") as fh:
        w = csv.writer(fh)
        if new:
            w.writerow(RECORD_FIELDS)
        for s in samples:
            w.writerow([getattr(s, f) if getattr(s, f) is not None else "" for f in RECORD_FIELDS])


def _to_arrays(samples: list[Sample]):
    samples = sorted(samples, key=lambda s: s.timestamp_ms)
    t = np.array([s.timestamp_ms for s in samples], dtype=float) / 1000.0
    w = {sig: np.array([np.nan if getattr(s, sig) is None else getattr(s, sig) for s in samples], dtype=float)
         for sig in ALL_SIGNALS}
    return w, t


def _clean(o):
    """Make numpy / NaN values JSON-safe."""
    if isinstance(o, dict):
        return {k: _clean(v) for k, v in o.items()}
    if isinstance(o, list):
        return [_clean(v) for v in o]
    if isinstance(o, (np.floating, float)):
        return None if np.isnan(o) else float(o)
    if isinstance(o, np.integer):
        return int(o)
    if isinstance(o, np.bool_):
        return bool(o)
    return o


# --------------------------------------------------------------- endpoints --
@app.get("/")
def root():
    return {"status": "PVMS Backend Online", "model_loaded": BASE is not None, "model_version": MODEL_VERSION,
            "server_time_ms": int(time.time() * 1000)}


@app.get("/model")
def model_info():
    if BASE is None:
        raise HTTPException(503, "Model not trained. Run: python train_model.py")
    return _clean({"version": BASE["version"], "source": BASE["source"], "n_train_windows": BASE["n_train_windows"],
                   "features": BASE["features"], "metrics": BASE.get("metrics")})


@app.post("/predict")
def predict(req: PredictRequest):
    received_ms = int(time.time() * 1000)
    t0 = time.perf_counter()
    if BASE is None:
        raise HTTPException(503, "Model not trained. Run: python train_model.py")
    vid = _safe_id(req.vehicle_id) if req.vehicle_id else None
    vb = _vehicle_bundle(vid)
    if vb is not None:
        bundle, mode = vb, "vehicle"
    elif req.use_base_model or vid is None:
        bundle, mode = BASE, "base"
    else:
        bundle, mode = None, "learning"          # rules only until this car's profile exists

    w, t = _to_arrays(req.samples)
    res = analyse_window(bundle, w, t, req.trip_elapsed_s, req.recent_model_flags)
    if req.record and vid and not req.use_base_model:        # real cars only, never the Opel replay
        try:
            _record(vid, req.samples)
        except OSError as e:  # recording must never break predictions
            print(f"[PVMS] could not record: {e}")

    learning = None
    if mode == "learning":
        n, done = _learning_count(vid), False
        rule_alert = any(f["severity"] in ("warning", "critical") for f in res["findings"])
        if req.auto_learn and res["regime"] == "warm" and not rule_alert:   # only learn healthy-looking driving
            n, done = _learn(vid, {k: (np.nan if v is None else v) for k, v in res["features"].items()})
        learning = {"windows_collected": n, "windows_needed": AUTO_CALIBRATION_WINDOWS, "calibrated_now": done,
                    "minutes_remaining": round(max(0, AUTO_CALIBRATION_WINDOWS - n) * 18 / 60, 1)}
    res["model_used"] = mode
    res["learning"] = learning
    res["model_version"] = MODEL_VERSION
    res["latency"] = {
        "server_received_ms": received_ms,
        "server_processing_ms": round((time.perf_counter() - t0) * 1000, 2),
        "uplink_ms": (received_ms - req.client_sent_ms) if req.client_sent_ms else None,  # needs synced clocks
    }
    return _clean(res)


@app.post("/calibrate")
def calibrate(req: CalibrateRequest):
    """Manual alternative to automatic learning: learn a car's profile from one recorded healthy drive."""
    if BASE is None:
        raise HTTPException(503, "Model not trained. Run: python train_model.py")
    vid = _safe_id(req.vehicle_id)
    w, t = _to_arrays(req.samples)
    feats = []
    for i in range(0, len(t) - WINDOW_SIZE + 1, WINDOW_SIZE // 2):
        sl = slice(i, i + WINDOW_SIZE)
        if t[sl][-1] - t[sl][0] > WINDOW_SIZE * 5:       # skip windows spanning a pause
            continue
        f = window_features({k: v[sl] for k, v in w.items()}, t[sl])
        if regime(f) == "warm":
            feats.append([f[k] for k in MODEL_FEATURES])
    if len(feats) < MIN_CALIBRATION_WINDOWS:
        raise HTTPException(422, f"Only {len(feats)} warm-engine windows; need {MIN_CALIBRATION_WINDOWS}. "
                                 "Drive longer after the engine has warmed up.")
    _save_profile(vid, recenter_bundle(BASE, np.array(feats, dtype=float), source=f"vehicle:{vid}"))
    return {"vehicle_id": vid, "calibrated": True, "windows_used": len(feats),
            "message": "This car's normal behaviour has been learned. The AI model is now active for it."}


@app.get("/vehicles/{vehicle_id}")
def vehicle_status(vehicle_id: str):
    vid = _safe_id(vehicle_id)
    vb = _vehicle_bundle(vid)
    return {"vehicle_id": vid, "calibrated": vb is not None,
            "windows_used": vb["n_calibration_windows"] if vb else None,
            "learning_windows": _learning_count(vid), "windows_needed": AUTO_CALIBRATION_WINDOWS}


@app.delete("/vehicles/{vehicle_id}")
def vehicle_reset(vehicle_id: str):
    vid = _safe_id(vehicle_id)
    _vehicle_cache.pop(vid, None)
    for p in (_profile_path(vid), _learning_path(vid)):
        if os.path.exists(p):
            os.remove(p)
    return {"vehicle_id": vid, "calibrated": False}


@app.post("/forecast")
def forecast(req: ForecastRequest):
    """Time-To-Failure estimate from per-trip summaries (trend extrapolation)."""
    return _clean(forecast_trips([t.model_dump() for t in req.trips]))
