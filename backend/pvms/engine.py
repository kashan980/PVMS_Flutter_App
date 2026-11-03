"""Layer 2: learned "normal behaviour" model + Isolation Forest, and the hybrid decision.

Why not Isolation Forest on raw readings?
  Raw readings mix *how the car is driven* (idle vs motorway) with *how healthy it
  is*. A plain Isolation Forest on raw features caught only ~5 % of injected faults
  in our evaluation, because a faulty value (e.g. 13.3 V) can still sit inside the
  wide range seen across all driving conditions.

What PVMS does instead (Normal Behaviour Modelling, NBM):
  1. For every health signal (coolant, fuel trims, O2, voltage) a gradient-boosting
     regressor learns its *expected* value from the driving context
     (rpm, speed, load, throttle, intake temperature).
  2. The residual  actual − expected  is robust-scaled to a z-score.
  3. An Isolation Forest is trained on the residual z-scores (multivariate anomalies),
     and each residual also gets learned upper / lower limits (single-signal anomalies).
  4. anomaly ratio u = max(IF ratio, signal ratios);  u ≥ 1 → anomaly;  health 0–100 from u (u_to_health).

A *bundle* is a dict saved with joblib. The same `fit_bundle` builds the base model
(Opel dataset) and per-vehicle models during calibration of a new car.
"""
from __future__ import annotations

import numpy as np
from sklearn.ensemble import HistGradientBoostingRegressor, IsolationForest
from sklearn.model_selection import GroupKFold, cross_val_predict

from . import MODEL_VERSION
from .features import CONTEXT_FEATURES, HEALTH_FEATURES, MODEL_FEATURES, regime, window_features
from .rules import Finding, SEVERITY_RANK, evaluate_rules, worst_severity

IF_QUANTILE = 0.99        # Isolation Forest alert at 99th pct of validation anomaly score
TAIL_QUANTILE = 0.0005    # per-signal limits at 0.05 % / 99.95 % of validation residuals
PERSIST_K, PERSIST_N = 2, 3   # an ML alert needs 2 of the last 3 windows anomalous


def _regressor(n: int) -> HistGradientBoostingRegressor:
    return HistGradientBoostingRegressor(max_iter=200, learning_rate=0.08,
                                         min_samples_leaf=max(10, min(40, n // 200)), random_state=0)


def _fill(X: np.ndarray, med: np.ndarray) -> np.ndarray:
    X = np.array(X, dtype=float, copy=True)
    idx = np.where(np.isnan(X))
    X[idx] = np.take(med, idx[1])
    return X


def fit_bundle(F_train: np.ndarray, F_val: np.ndarray, groups: np.ndarray | None = None,
               source: str = "", random_state: int = 42) -> dict:
    """F_*: (n_windows, len(MODEL_FEATURES)) healthy warm-engine windows.

    F_val (a later, disjoint time period) sets the thresholds so they reflect unseen data.
    """
    nc = len(CONTEXT_FEATURES)
    med = np.nanmedian(F_train, axis=0)
    F_train, F_val = _fill(F_train, med), _fill(F_val, med)
    C, H = F_train[:, :nc], F_train[:, nc:]
    if groups is None:   # contiguous blocks keep neighbouring (overlapping) windows together
        groups = np.arange(len(F_train)) * 5 // len(F_train)
    n_folds = int(min(5, len(np.unique(groups))))

    regs, oof = [], np.zeros_like(H)
    for j in range(H.shape[1]):
        r = _regressor(len(C))
        oof[:, j] = cross_val_predict(r, C, H[:, j], groups=groups, cv=GroupKFold(n_folds))
        regs.append(r.fit(C, H[:, j]))

    R = H - oof                                   # honest (out-of-fold) residuals
    loc = np.median(R, axis=0)
    scale = np.median(np.abs(R - loc), axis=0) * 1.4826 + 1e-6
    Z = (R - loc) / scale
    iso = IsolationForest(n_estimators=300, max_samples=min(512, len(Z)), random_state=random_state, n_jobs=-1).fit(Z)

    bundle = {
        "version": MODEL_VERSION, "features": list(MODEL_FEATURES), "regressors": regs,
        "resid_loc": loc, "resid_scale": scale, "iso": iso, "medians": dict(zip(MODEL_FEATURES, med.tolist())),
        "n_train_windows": int(len(F_train)), "source": source,
    }
    Zv = _residual_z(bundle, F_val)[0]
    a_val = -iso.decision_function(Zv)
    bundle["iso_p50"] = float(np.median(a_val))
    bundle["iso_thr"] = float(np.quantile(a_val, IF_QUANTILE))
    bundle["z_hi"] = np.maximum(np.quantile(Zv, 1 - TAIL_QUANTILE, axis=0), 2.0)
    bundle["z_lo"] = np.minimum(np.quantile(Zv, TAIL_QUANTILE, axis=0), -2.0)
    return bundle


def recenter_bundle(base: dict, F_cal: np.ndarray, source: str = "") -> dict:
    """Adapt the base model to a NEW car from a short healthy drive (transfer calibration).

    The base model's regressors already know how engine signals respond to driving
    context (load, rpm, speed...). What differs between an Opel and a Suzuki Alto is
    mostly each car's *normal level*: its fuel-trim offset, charging voltage, thermostat
    temperature. So only the residual centre (median) and spread are re-estimated from
    the new car; the Isolation Forest and limits are reused.

    Evaluation (reports/evaluation_report.md §5): a healthy 'other car' judged by the
    un-adapted Opel model -> ~97 % false alarms; after re-centring on ~40-80 windows
    (12-24 min warm driving) -> ~3 %, with the same fault detection as on the Opel.
    """
    F_cal = np.atleast_2d(np.asarray(F_cal, dtype=float))
    _, E, H = _residual_z(base, F_cal)
    R = H - E
    loc = np.nanmedian(R, axis=0)
    mad = np.nanmedian(np.abs(R - loc), axis=0) * 1.4826
    b = dict(base)                                   # shallow copy: shares the fitted estimators
    b["resid_loc"] = loc
    b["resid_scale"] = np.maximum(base["resid_scale"], mad)   # never tighter than the base model
    b["source"] = source or "recentred"
    b["kind"] = "recentred"
    b["n_calibration_windows"] = int(len(F_cal))
    return b


def _residual_z(bundle: dict, F: np.ndarray):
    nc = len(CONTEXT_FEATURES)
    F = _fill(np.atleast_2d(F), np.array([bundle["medians"][f] for f in MODEL_FEATURES]))
    C, H = F[:, :nc], F[:, nc:]
    E = np.column_stack([r.predict(C) for r in bundle["regressors"]])
    Z = (H - E - bundle["resid_loc"]) / bundle["resid_scale"]
    return Z, E, H


def anomaly_ratio(bundle: dict, F: np.ndarray):
    """Returns (u, u_iso, u_signals, expected, actual). u ≥ 1 means anomalous."""
    Z, E, H = _residual_z(bundle, F)
    a = -bundle["iso"].decision_function(Z)
    u_iso = (a - bundle["iso_p50"]) / max(bundle["iso_thr"] - bundle["iso_p50"], 1e-6)
    u_sig = np.where(Z >= 0, Z / bundle["z_hi"], Z / bundle["z_lo"])
    u = np.maximum(u_iso, u_sig.max(axis=1))
    return u, u_iso, u_sig, E, H


HEALTHY_U = 0.6   # typical normal windows sit around u ≈ 0.5


def u_to_health(u: float) -> float:
    """u ≤ 0.6 → 100 · u = 1 (threshold) → 50 · u ≥ 2 → 0."""
    if u <= HEALTHY_U:
        return 100.0
    if u <= 1.0:
        return float(100 - 50 * (u - HEALTHY_U) / (1.0 - HEALTHY_U))
    return float(np.clip(50 - 50 * (u - 1.0), 0, 50))


# ---------- plain-English explanation of *why* the model is suspicious ----------
_EXPLAIN = {
    "coolant_mean": ("Engine temperature", "°C", "higher", "lower"),
    "coolant_slope": ("Engine temperature trend", "°C/min", "rising faster", "falling faster"),
    "stft_mean": ("Short-term fuel correction", "%", "higher", "lower"),
    "stft_std": ("Fuel correction stability", "%", "more unstable", "unusually flat"),
    "ltft_mean": ("Long-term fuel correction", "%", "higher", "lower"),
    "trim_total_mean": ("Total fuel correction", "%", "higher", "lower"),
    "o2_mean": ("Oxygen sensor average", "V", "higher", "lower"),
    "o2_std": ("Oxygen sensor activity", "V", "more erratic", "lower"),
    "o2_cross_rate": ("Oxygen sensor switching", "/min", "faster", "slower"),
    "volt_mean": ("Charging voltage", "V", "higher", "lower"),
    "volt_min": ("Minimum voltage", "V", "higher", "lower"),
}


def explain(u_sig: np.ndarray, E: np.ndarray, H: np.ndarray, top: int = 3, min_ratio: float = 0.7) -> list[dict]:
    out = []
    for j, f in enumerate(HEALTH_FEATURES):
        r = float(u_sig[j])
        if r < min_ratio:
            continue
        label, unit, up, down = _EXPLAIN[f]
        actual, expected = float(H[j]), float(E[j])
        out.append({"feature": f, "label": label, "value": round(actual, 2), "expected": round(expected, 2),
                    "unit": unit, "ratio": round(r, 2),
                    "text": f"{label} is {up if actual > expected else down} than expected for these driving "
                            f"conditions ({actual:.2f} {unit} vs {expected:.2f} {unit} normally)."})
    out.sort(key=lambda d: -d["ratio"])
    return out[:top]


def analyse_window(bundle: dict | None, window: dict[str, np.ndarray], t_s: np.ndarray,
                   trip_elapsed_s: float | None = None, recent_flags: list[bool] | None = None) -> dict:
    """Full hybrid analysis of one window.

    bundle=None → rules only (a new car whose normal behaviour is still being learned).

    recent_flags: model-anomaly flags of the previous windows in this trip (oldest first),
                  used for the persistence rule. Pass None to disable persistence.
    """
    feats = window_features(window, t_s)
    reg = regime(feats)
    findings: list[Finding] = evaluate_rules(feats, reg, trip_elapsed_s)
    result = {"regime": reg,
              "features": {k: (None if v is None or np.isnan(v) else round(float(v), 4)) for k, v in feats.items()},
              "model_applied": False, "model_ratio": None, "model_anomaly": False, "persistent": False,
              "contributors": [], "imputed_features": []}
    health = 100.0
    if reg == "warm" and bundle is not None:
        F = np.array([[feats.get(f, np.nan) for f in MODEL_FEATURES]], dtype=float)
        imputed = [f for f, v in zip(MODEL_FEATURES, F[0]) if np.isnan(v)]
        u, _, u_sig, E, H = anomaly_ratio(bundle, F)
        u0 = float(u[0])
        is_anom = u0 >= 1.0
        flags = (recent_flags or [])[-(PERSIST_N - 1):] + [is_anom]
        persistent = is_anom and (recent_flags is None or sum(flags) >= PERSIST_K)
        contrib = explain(u_sig[0], E[0], H[0])
        health = u_to_health(u0)
        result.update(model_applied=True, model_ratio=round(u0, 3), model_anomaly=bool(is_anom),
                      persistent=bool(persistent), contributors=contrib, imputed_features=imputed)
        if not persistent:
            health = max(health, 55.0) if is_anom else health   # single blip → "monitor", not an alarm
        else:
            detail = " ".join(c["text"] for c in contrib) or \
                "The combination of readings is unusual for this car, although no single value is out of range."
            findings.append(Finding(
                "ML_ANOMALY", "warning" if u0 < 2 else "critical", "Unusual engine behaviour detected", detail,
                "If this keeps appearing on several trips, book an inspection and show the mechanic the PVMS history.",
                source="model"))

    worst = worst_severity([f for f in findings if f.source == "rule"])
    caps = {"critical": 20.0, "warning": 45.0, "info": 85.0}
    if worst:
        health = min(health, caps[worst])
    status = "healthy" if health >= 70 else "monitor" if health >= 50 else "warning" if health >= 25 else "critical"
    findings.sort(key=lambda f: -SEVERITY_RANK[f.severity])
    result.update(health_score=round(health, 1), status=status, is_anomaly=status in ("warning", "critical"),
                  findings=[f.to_dict() for f in findings])
    return result
