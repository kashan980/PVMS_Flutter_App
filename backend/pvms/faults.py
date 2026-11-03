"""Synthetic fault injection for evaluation.

The Opel dataset contains no labelled breakdowns, so Precision / Recall / F1 cannot
be computed on it directly. The standard way around this (used widely in the
predictive-maintenance literature) is to take *held-out* real driving windows and
inject the physical signature of known failure modes at two severities. A
detector is then scored on whether it flags the injected windows while leaving
the untouched ones alone.

The same fault signatures are mirrored in the Flutter app's simulator so the demo
and the evaluation are consistent.
"""
from __future__ import annotations

import numpy as np

FAULTS = {
    "overheating": "Cooling fault: coolant climbs above normal",
    "vacuum_leak": "Vacuum leak: ECU adds extra fuel (positive trims)",
    "injector_leak": "Leaking injector: ECU removes fuel (negative trims)",
    "alternator_failure": "Charging fault: system voltage drops",
    "o2_sensor_degraded": "O2 sensor: slow / flat switching",
}
SEVERITIES = ("mild", "severe")


def inject(window: dict[str, np.ndarray], fault: str, severity: str, rng: np.random.Generator) -> dict[str, np.ndarray]:
    w = {k: np.array(v, dtype=float, copy=True) for k, v in window.items()}
    n = len(next(iter(w.values())))
    ramp = np.linspace(0, 1, n)
    mild = severity == "mild"

    if fault == "overheating":
        base = rng.uniform(6, 10) if mild else rng.uniform(13, 20)
        w["coolant_temp"] = w["coolant_temp"] + base + ramp * (2 if mild else 5)
    elif fault == "vacuum_leak":
        st = rng.uniform(5, 9) if mild else rng.uniform(10, 16)
        lt = rng.uniform(4, 7) if mild else rng.uniform(8, 14)
        w["short_fuel_trim_1"] = w["short_fuel_trim_1"] + st + rng.normal(0, 1.5, n)
        w["long_fuel_trim_1"] = w["long_fuel_trim_1"] + lt
    elif fault == "injector_leak":
        st = rng.uniform(6, 10) if mild else rng.uniform(12, 18)
        lt = rng.uniform(8, 12) if mild else rng.uniform(15, 22)
        w["short_fuel_trim_1"] = w["short_fuel_trim_1"] - st + rng.normal(0, 1.5, n)
        w["long_fuel_trim_1"] = w["long_fuel_trim_1"] - lt
    elif fault == "alternator_failure":
        if mild:   # weakening regulator: ~13.3 V instead of ~14.1 V
            w["battery_voltage"] = rng.uniform(13.2, 13.5) + rng.normal(0, 0.05, n)
        else:      # not charging: battery discharging from ~12.5 V
            w["battery_voltage"] = rng.uniform(12.2, 12.6) - ramp * 0.15 + rng.normal(0, 0.03, n)
    elif fault == "o2_sensor_degraded":
        o2 = w["o2_b1s1"]
        if mild:   # lazy sensor: sluggish, reduced amplitude
            k = 5
            sm = np.convolve(np.pad(o2, (k, k), mode="edge"), np.ones(k) / k, mode="same")[k:-k]
            w["o2_b1s1"] = 0.45 + (sm - 0.45) * 0.35
        else:      # dead sensor: flat ~0.45 V
            w["o2_b1s1"] = 0.45 + rng.normal(0, 0.008, n)
    else:
        raise ValueError(fault)
    return w
