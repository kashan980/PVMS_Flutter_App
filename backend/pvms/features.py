"""Window feature extraction — the single source of truth for training AND inference.

A *window* is ~30 consecutive OBD readings (≈30–40 s of driving at the 1 Hz an
ELM327 manages when polling ~10 PIDs). Looking at a window instead of a single
reading lets the model see behaviour over time (is the coolant climbing? is the
O2 sensor switching?) and makes it robust to one bad Bluetooth packet.

All rate/slope features are expressed *per minute* so they do not depend on how
fast a particular adapter can poll.
"""
from __future__ import annotations

import numpy as np

from .signals import CORE_SIGNALS

WINDOW_SIZE = 30          # samples per window during training
WINDOW_STEP = 15          # 50 % overlap during training
MIN_WINDOW_SAMPLES = 15   # the API accepts shorter windows (e.g. right after connect)

WARM_COOLANT_C = 75.0     # below this the engine is still warming up
RUNNING_RPM = 400.0
O2_MIDPOINT_V = 0.45      # narrowband O2 sensor rich/lean switching point

# Operating-condition features: tell the model *how* the car is being driven.
CONTEXT_FEATURES = [
    "rpm_mean", "rpm_std", "speed_mean", "load_mean", "throttle_mean", "intake_temp_mean",
]
# Health features: the ones that move when a component degrades.
HEALTH_FEATURES = [
    "coolant_mean", "coolant_slope", "stft_mean", "stft_std", "ltft_mean",
    "trim_total_mean", "o2_mean", "o2_std", "o2_cross_rate", "volt_mean", "volt_min",
]
MODEL_FEATURES = CONTEXT_FEATURES + HEALTH_FEATURES


def _fill(x: np.ndarray) -> np.ndarray:
    """Forward/back-fill NaNs inside one window (dropped Bluetooth packets)."""
    x = np.asarray(x, dtype=float)
    mask = np.isnan(x)
    if not mask.any():
        return x
    if mask.all():
        return x
    idx = np.where(~mask, np.arange(len(x)), 0)
    np.maximum.accumulate(idx, out=idx)
    out = x[idx]
    first = np.argmax(~mask)
    out[:first] = x[first]
    return out


def _slope_per_min(t_s: np.ndarray, y: np.ndarray) -> float:
    if len(y) < 3 or np.isnan(y).all():
        return np.nan
    dt = t_s - t_s[0]
    if dt[-1] <= 0:
        return 0.0
    a = np.polyfit(dt / 60.0, y, 1)[0]
    return float(a)


def window_features(window: dict[str, np.ndarray], t_s: np.ndarray) -> dict[str, float]:
    """Compute one feature vector from one window.

    window: {signal_name: 1-D array} using names from signals.CORE_SIGNALS (missing
            signals may be absent or all-NaN).
    t_s:    timestamps in seconds (same length).
    """
    n = len(t_s)
    get = {s: _fill(window.get(s, np.full(n, np.nan))) for s in CORE_SIGNALS}

    def m(s):
        v = get[s]
        return float(np.nanmean(v)) if not np.isnan(v).all() else np.nan

    def sd(s):
        v = get[s]
        return float(np.nanstd(v)) if not np.isnan(v).all() else np.nan

    duration_min = max((t_s[-1] - t_s[0]) / 60.0, 1e-6)
    o2 = get["o2_b1s1"]
    if np.isnan(o2).all():
        o2_cross = np.nan
    else:
        sign = np.sign(o2 - O2_MIDPOINT_V)
        o2_cross = float(np.sum(sign[1:] * sign[:-1] < 0) / duration_min)

    volt = get["battery_voltage"]
    stft, ltft = get["short_fuel_trim_1"], get["long_fuel_trim_1"]
    return {
        "rpm_mean": m("rpm"),
        "rpm_std": sd("rpm"),
        "speed_mean": m("speed"),
        "load_mean": m("engine_load"),
        "throttle_mean": m("throttle_pos"),
        "intake_temp_mean": m("intake_temp"),
        "coolant_mean": m("coolant_temp"),
        "coolant_max": float(np.nanmax(get["coolant_temp"])) if not np.isnan(get["coolant_temp"]).all() else np.nan,
        "coolant_slope": _slope_per_min(t_s, get["coolant_temp"]),
        "stft_mean": m("short_fuel_trim_1"),
        "stft_std": sd("short_fuel_trim_1"),
        "ltft_mean": m("long_fuel_trim_1"),
        "trim_total_mean": float(np.nanmean(stft + ltft)) if not (np.isnan(stft).all() or np.isnan(ltft).all()) else np.nan,
        "o2_mean": m("o2_b1s1"),
        "o2_std": sd("o2_b1s1"),
        "o2_cross_rate": o2_cross,
        "volt_mean": m("battery_voltage"),
        "volt_min": float(np.nanmin(volt)) if not np.isnan(volt).all() else np.nan,
        "rpm_median": float(np.nanmedian(get["rpm"])) if not np.isnan(get["rpm"]).all() else np.nan,
        "coolant_median": float(np.nanmedian(get["coolant_temp"])) if not np.isnan(get["coolant_temp"]).all() else np.nan,
        "duration_s": float(t_s[-1] - t_s[0]),
        "n_samples": float(n),
    }


def regime(feats: dict[str, float]) -> str:
    """engine_off / warming_up / warm. The ML model is only applied to 'warm'."""
    rpm = feats.get("rpm_median", np.nan)
    if np.isnan(rpm) or rpm < RUNNING_RPM:
        return "engine_off"
    cool = feats.get("coolant_median", np.nan)
    if np.isnan(cool) or cool < WARM_COOLANT_C:
        return "warming_up"
    return "warm"


def to_vector(feats: dict[str, float], medians: dict[str, float]) -> tuple[np.ndarray, list[str]]:
    """Order features for the model; impute unavailable ones with training medians."""
    vec, imputed = [], []
    for f in MODEL_FEATURES:
        v = feats.get(f, np.nan)
        if v is None or np.isnan(v):
            v = medians[f]
            imputed.append(f)
        vec.append(v)
    return np.asarray(vec, dtype=float).reshape(1, -1), imputed
