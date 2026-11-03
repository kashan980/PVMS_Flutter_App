"""API tests on a real Opel trip the model never trained on.   Run:  python -m pytest -q"""
import os
import sys

import numpy as np
import pandas as pd
import pytest
from fastapi.testclient import TestClient

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))

import main  # noqa: E402

TRIP = pd.read_csv(os.path.join(HERE, "fixtures", "opel_trip.csv"))
client = TestClient(main.app)
pytestmark = pytest.mark.skipif(main.BASE is None, reason="train the model first: python train_model.py")


def samples(df):
    out = []
    for r in df.to_dict("records"):
        s = {k: (None if pd.isna(v) else float(v)) for k, v in r.items() if k != "t_s"}
        s["timestamp_ms"] = int(1_760_000_000_000 + r["t_s"] * 1000)
        out.append(s)
    return out


def window(start, n=30):
    return TRIP.iloc[start:start + n].copy()


def test_root():
    r = client.get("/")
    assert r.status_code == 200 and r.json()["model_loaded"] is True


def test_warming_up_window_is_not_scored_by_model():
    r = client.post("/predict", json={"samples": samples(window(5))}).json()
    assert r["regime"] == "warming_up" and r["model_applied"] is False


def test_healthy_warm_window():
    r = client.post("/predict", json={"samples": samples(window(1200)), "client_sent_ms": 1}).json()
    assert r["regime"] == "warm" and r["model_applied"]
    assert r["status"] in ("healthy", "monitor")
    assert r["latency"]["server_processing_ms"] < 500


def test_alternator_failure_is_critical():
    w = window(1200)
    w["battery_voltage"] = np.linspace(12.4, 12.2, len(w))
    r = client.post("/predict", json={"samples": samples(w)}).json()
    assert r["status"] == "critical"
    assert "CHARGING_FAILURE" in [f["code"] for f in r["findings"]]


def test_overheating_is_critical():
    w = window(1200)
    w["coolant_temp"] = np.linspace(108, 116, len(w))
    r = client.post("/predict", json={"samples": samples(w)}).json()
    assert r["status"] == "critical" and r["findings"][0]["code"] == "COOLANT_OVERHEAT"


def test_mild_injector_leak_caught_by_model_not_rules():
    """Total fuel trim ~0 % is 'normal' by universal limits, but this car normally runs at ~+15 %.
    Only the learned per-car model can notice the shift (rules: 0 % recall in the evaluation)."""
    flags, last = [], None
    for start in (1100, 1130, 1160):
        w = window(start)
        w["short_fuel_trim_1"] = w["short_fuel_trim_1"] - 8
        w["long_fuel_trim_1"] = w["long_fuel_trim_1"] - 10
        last = client.post("/predict", json={"samples": samples(w), "recent_model_flags": flags}).json()
        flags.append(last["model_anomaly"])
    assert last["persistent"] is True
    codes = [f["code"] for f in last["findings"]]
    assert "ML_ANOMALY" in codes and "RICH_CONDITION" not in codes
    assert any("trim" in c["feature"] or "ft" in c["feature"] for c in last["contributors"])


def test_full_trip_replay_mostly_healthy():
    statuses, flags = [], []
    for start in range(0, len(TRIP) - 30, 30):
        w = window(start)
        r = client.post("/predict", json={"samples": samples(w), "trip_elapsed_s": float(w.t_s.iloc[-1]),
                                          "recent_model_flags": flags}).json()
        flags.append(bool(r["model_anomaly"]))
        statuses.append(r["status"])
    bad = sum(s in ("warning", "critical") for s in statuses) / len(statuses)
    assert bad < 0.1, statuses


def test_missing_signals_are_tolerated():
    w = window(1200).drop(columns=["o2_b1s1", "battery_voltage"])
    r = client.post("/predict", json={"samples": samples(w)}).json()
    assert r["model_applied"] and "volt_mean" in r["imputed_features"]


def test_calibrate_new_vehicle(tmp_path, monkeypatch):
    monkeypatch.setattr(main, "VEHICLE_DIR", str(tmp_path))
    r = client.post("/calibrate", json={"vehicle_id": "test-car", "samples": samples(TRIP)})
    assert r.status_code == 200, r.text
    assert client.get("/vehicles/test-car").json()["calibrated"]
    p = client.post("/predict", json={"samples": samples(window(1200)), "vehicle_id": "test-car"}).json()
    assert p["model_used"] == "vehicle"
    client.delete("/vehicles/test-car")
    assert not client.get("/vehicles/test-car").json()["calibrated"]


def test_forecast_detects_degrading_trend():
    trips = [{"km": 1000 + i * 600, "health": 95 - i * 2.5, "ltft_mean": 12 + i * 0.4, "volt_mean": 14.1}
             for i in range(12)]
    r = client.post("/forecast", json={"trips": trips}).json()
    assert r["ttf"] is not None and r["ttf"]["km_remaining"] > 0


def test_forecast_stable_trend_has_no_ttf():
    rng = np.random.default_rng(0)
    trips = [{"km": 1000 + i * 600, "health": float(95 + rng.normal(0, 1)), "volt_mean": 14.1} for i in range(12)]
    r = client.post("/forecast", json={"trips": trips}).json()
    assert r["ttf"] is None


def test_new_car_learns_automatically_then_uses_its_own_profile(tmp_path, monkeypatch):
    """A real car is never judged by the Opel's normal: rules only while learning, then its own profile."""
    monkeypatch.setattr(main, "VEHICLE_DIR", str(tmp_path))
    monkeypatch.setattr(main, "RECORDINGS_DIR", str(tmp_path / "rec"))
    main._vehicle_cache.clear()
    other = TRIP.copy()
    other["long_fuel_trim_1"] -= 14          # a healthy car whose normal fuel trim is ~0 % (not the Opel's +15 %)
    other["battery_voltage"] -= 0.5

    def post(start):
        w = other.iloc[start:start + 30]
        return client.post("/predict", json={"samples": samples(w), "vehicle_id": "alto-2022",
                                             "use_base_model": False}).json()

    first = post(1200)
    assert first["model_used"] == "learning" and first["model_applied"] is False
    assert first["learning"]["windows_collected"] == 1
    assert first["status"] in ("healthy", "monitor")          # no false ML alarm while learning
    calibrated = False
    for _ in range(3):                                          # replay the trip until enough warm windows
        for start in range(0, len(other) - 30, 15):
            r = post(start)
            if r["learning"] and r["learning"]["calibrated_now"]:
                calibrated = True
                break
        if calibrated:
            break
    assert calibrated
    assert client.get("/vehicles/alto-2022").json()["calibrated"]
    after = post(1200)
    assert after["model_used"] == "vehicle" and after["model_applied"]
    assert after["status"] in ("healthy", "monitor")


def test_opel_model_would_false_alarm_on_other_car():
    """Documents WHY the base model is not used on real cars."""
    flags = []
    for start in (1100, 1130, 1160):
        w = window(start)
        w["long_fuel_trim_1"] -= 14
        w["battery_voltage"] -= 0.5
        r = client.post("/predict", json={"samples": samples(w), "use_base_model": True,
                                          "recent_model_flags": flags}).json()
        flags.append(r["model_anomaly"])
    assert all(flags)


def test_real_car_readings_are_recorded_and_reloadable(tmp_path, monkeypatch):
    monkeypatch.setattr(main, "VEHICLE_DIR", str(tmp_path / "veh"))
    monkeypatch.setattr(main, "RECORDINGS_DIR", str(tmp_path / "rec"))
    main._vehicle_cache.clear()
    for start in (0, 15, 30):   # overlapping windows → duplicates on disk
        client.post("/predict", json={"samples": samples(window(start)), "vehicle_id": "city-2020",
                                      "use_base_model": False})
    client.post("/predict", json={"samples": samples(window(100)), "use_base_model": True})  # simulator: not recorded
    from pvms.dataset import load_recordings
    df = load_recordings(str(tmp_path / "rec" / "city-2020"))
    assert len(df) == 60 and df.timestamp_ms.is_monotonic_increasing
    assert not (tmp_path / "rec" / "None").exists()
