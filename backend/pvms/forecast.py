"""Time-To-Failure (TTF) estimation by trend extrapolation.

Honest framing for the report: the dataset contains no recorded failures, so a
learned "time until breakdown" regressor is impossible. What *is* possible — and
what commercial fleet tools do — is to track a degradation indicator across trips
and extrapolate its trend to a known fault threshold:

    km_remaining = (threshold - current_value) / slope_per_km

Only reported when the trend is clearly heading towards the threshold
(slope in the bad direction and R² above a minimum), otherwise "no degradation
trend detected".
"""
from __future__ import annotations

import numpy as np

# indicator -> (threshold, direction of failure, human label)
INDICATORS = {
    "health": (40.0, "down", "Overall engine health"),
    "ltft_mean": (25.0, "up", "Fuel trim (lean condition)"),
    "volt_mean": (13.2, "down", "Charging voltage"),
    "coolant_mean": (106.0, "up", "Engine temperature"),
}
MIN_POINTS = 5
MIN_R2 = 0.3
MAX_HORIZON_KM = 100_000


def _fit(km: np.ndarray, y: np.ndarray):
    a, b = np.polyfit(km, y, 1)
    pred = a * km + b
    ss_res = float(np.sum((y - pred) ** 2))
    ss_tot = float(np.sum((y - y.mean()) ** 2)) or 1e-9
    return float(a), float(b), max(0.0, 1 - ss_res / ss_tot)


def forecast_indicator(km, values, name: str) -> dict:
    threshold, direction, label = INDICATORS[name]
    km = np.asarray(km, float)
    y = np.asarray(values, float)
    ok = ~np.isnan(y) & ~np.isnan(km)
    km, y = km[ok], y[ok]
    res = {"indicator": name, "label": label, "threshold": threshold, "direction": direction,
           "points": int(len(y)), "km_remaining": None, "slope_per_1000km": None, "r2": None,
           "current": float(y[-1]) if len(y) else None, "status": "insufficient_data"}
    if len(y) < MIN_POINTS or np.ptp(km) < 50:
        return res
    if np.ptp(y) < 1e-6:                          # perfectly flat signal
        res.update(status="stable", slope_per_1000km=0.0, r2=0.0)
        return res
    a, b, r2 = _fit(km, y)
    current = a * km[-1] + b  # smoothed current value
    res.update(slope_per_1000km=round(a * 1000, 4), r2=round(r2, 3), current=round(float(current), 2))
    worsening = (a > 0) if direction == "up" else (a < 0)
    already = (current >= threshold) if direction == "up" else (current <= threshold)
    if already:
        res.update(status="threshold_reached", km_remaining=0)
    elif worsening and r2 >= MIN_R2:
        rem = (threshold - current) / a
        if rem <= MAX_HORIZON_KM:
            res.update(status="degrading", km_remaining=int(rem))
        else:
            res["status"] = "stable"                  # trend too slow to matter
    else:
        res["status"] = "stable"
    return res


def forecast_trips(trips: list[dict]) -> dict:
    """trips: [{km (odometer at trip end), health, ltft_mean, volt_mean, coolant_mean}, ...]"""
    trips = sorted(trips, key=lambda t: t["km"])
    km = [t["km"] for t in trips]
    results = []
    for name in INDICATORS:
        vals = [t.get(name) if t.get(name) is not None else np.nan for t in trips]
        results.append(forecast_indicator(km, vals, name))
    soonest = [r for r in results if r["km_remaining"] is not None]
    soonest.sort(key=lambda r: r["km_remaining"])
    return {"ttf": soonest[0] if soonest else None, "indicators": results}
