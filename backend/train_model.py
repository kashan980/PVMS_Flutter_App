"""Train and evaluate the PVMS anomaly model.

    python train_model.py                # uses dataset.csv next to this file

Pipeline
  1. Load OBD2_panel_opel_2012 and cut every trip into 30-sample windows (50 % overlap).
  2. Compute window features (pvms/features.py — the exact code the live API uses).
  3. Keep warm-engine windows. Split BY REFUELLING SEGMENT (time-ordered) so the
     test data is from months the model never saw:
         train = segments 1–15, validation = 16–18 (sets the alert threshold), test = 19–22.
  4. Fit StandardScaler + Isolation Forest, set threshold at 2 % false-alarm rate on validation.
  5. Evaluate on the test segments: false-alarm rate on real windows, then Precision /
     Recall / F1 on real windows + fault-injected copies (pvms/faults.py), comparing
     rules-only, model-only and the hybrid PVMS decision.
  6. Trend analysis across all 22 segments (TTF demonstration on real data).
  7. Save saved_models/pvms_model.joblib and reports/evaluation_report.md.
"""
from __future__ import annotations

import json
import os
import sys
import time
import uuid

import joblib
import numpy as np
import pandas as pd

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from pvms import MODEL_VERSION  # noqa: E402
from pvms.dataset import iter_windows, load  # noqa: E402
from pvms.engine import PERSIST_K, PERSIST_N, anomaly_ratio, fit_bundle, recenter_bundle, u_to_health  # noqa: E402
from pvms.faults import FAULTS, SEVERITIES, inject  # noqa: E402
from pvms.features import MODEL_FEATURES, regime, window_features  # noqa: E402
from pvms.forecast import forecast_indicator  # noqa: E402
from pvms.rules import evaluate_rules  # noqa: E402

DATA_FILE = os.path.join(HERE, "dataset.csv")
MODEL_DIR = os.path.join(HERE, "saved_models")
REPORT_DIR = os.path.join(HERE, "reports")
TRAIN_SEGS, VAL_SEGS, TEST_SEGS = range(1, 16), range(16, 19), range(19, 23)
EVENTS_PER_CASE = 300     # injected fault events per fault type x severity
EVENT_LEN = 3             # an event = 3 consecutive windows (~1 minute of driving)


def rule_detects(feats, reg="warm") -> bool:
    return any(f.severity in ("warning", "critical") for f in evaluate_rules(feats, reg))


def persistent(flags: np.ndarray) -> np.ndarray:
    """Alert at window i if it is anomalous and >= K of the last N windows are (same sequence)."""
    out = np.zeros_like(flags, dtype=bool)
    for i in range(len(flags)):
        lo = max(0, i - PERSIST_N + 1)
        out[i] = flags[i] and flags[lo:i + 1].sum() >= PERSIST_K
    return out


def prf(y_true, y_pred):
    y_true, y_pred = np.asarray(y_true, bool), np.asarray(y_pred, bool)
    tp = int(np.sum(y_true & y_pred)); fp = int(np.sum(~y_true & y_pred))
    fn = int(np.sum(y_true & ~y_pred)); tn = int(np.sum(~y_true & ~y_pred))
    p = tp / (tp + fp) if tp + fp else 0.0
    r = tp / (tp + fn) if tp + fn else 0.0
    f1 = 2 * p * r / (p + r) if p + r else 0.0
    return {"precision": round(p, 4), "recall": round(r, 4), "f1": round(f1, 4),
            "tp": tp, "fp": fp, "fn": fn, "tn": tn}


def main():
    t0 = time.time()
    if not os.path.exists(DATA_FILE):
        sys.exit(f"Put the Opel dataset at {DATA_FILE}")
    print("1/7 Loading dataset ...")
    df = load(DATA_FILE)
    print(f"    {len(df):,} readings, {df.segment_file.nunique()} trips, {df.segment_id.nunique()} refuelling segments")

    print("2/7 Windowing + feature extraction ...")
    rows, windows = [], []
    for seg, f, w, t in iter_windows(df):
        feats = window_features(w, t)
        rows.append({"segment_id": seg, "trip": f, "regime": regime(feats), **feats})
        windows.append((w, t))
    feat = pd.DataFrame(rows)
    print(f"    {len(feat):,} windows | regimes: {feat.regime.value_counts().to_dict()}")

    warm = feat[feat.regime == "warm"]
    tr = warm[warm.segment_id.isin(TRAIN_SEGS)]
    va = warm[warm.segment_id.isin(VAL_SEGS)]
    te = warm[warm.segment_id.isin(TEST_SEGS)]
    print(f"    warm windows  train={len(tr):,}  val={len(va):,}  test={len(te):,}")

    print("3/7 Training normal-behaviour regressors + Isolation Forest ...")
    bundle = fit_bundle(tr[MODEL_FEATURES].to_numpy(), va[MODEL_FEATURES].to_numpy(),
                        groups=tr.segment_id.to_numpy(), source="OBD2_panel_opel_2012 segments 1-15")

    print("4/7 False alarms on unseen test segments (real data) ...")
    u_te = anomaly_ratio(bundle, te[MODEL_FEATURES].to_numpy())[0]
    m_flag = pd.Series(u_te >= 1.0, index=te.index)
    r_flag = pd.Series([rule_detects(r) for r in te.to_dict("records")], index=te.index)
    # persistence is applied within each trip, in time order
    m_pers = m_flag.groupby(te.trip, sort=False).transform(lambda s: persistent(s.to_numpy()))
    clean = {
        "windows": int(len(te)),
        "rules_false_alarm_rate": round(float(r_flag.mean()), 4),
        "model_false_alarm_rate_raw": round(float(m_flag.mean()), 4),
        "model_false_alarm_rate": round(float(m_pers.mean()), 4),
        "hybrid_false_alarm_rate": round(float((m_pers | r_flag).mean()), 4),
    }
    print(f"    {clean}")

    print("5/7 Fault-injection evaluation (events of 3 consecutive windows) ...")
    rng = np.random.default_rng(7)
    pos = {t: g.index.to_numpy() for t, g in te.groupby("trip", sort=False)}
    starts = [ix[i] for ix in pos.values() for i in range(len(ix) - EVENT_LEN + 1)
              if ix[i + EVENT_LEN - 1] - ix[i] == EVENT_LEN - 1]
    # Negative events: non-overlapping clean 3-window sequences.
    neg_starts = [s for k, s in enumerate(starts) if k % EVENT_LEN == 0]
    neg_m = np.array([m_pers.loc[s:s + EVENT_LEN - 1].any() for s in neg_starts])
    neg_r = np.array([r_flag.loc[s:s + EVENT_LEN - 1].any() for s in neg_starts])
    per_case = []
    ev_true, ev_m, ev_r = [0] * len(neg_starts), list(neg_m), list(neg_r)
    win_true, win_m, win_r = [0] * len(te), list(m_flag), list(r_flag)
    for fault in FAULTS:
        for sev in SEVERITIES:
            picks = rng.choice(starts, size=min(EVENTS_PER_CASE, len(starts)), replace=False)
            feats_inj = []
            for s in picks:
                seed = int(rng.integers(1 << 31))
                for k in range(EVENT_LEN):   # same fault magnitude across the event
                    w, t = windows[s + k]
                    feats_inj.append(window_features(inject(w, fault, sev, np.random.default_rng(seed)), t))
            Fi = pd.DataFrame(feats_inj)
            u = anomaly_ratio(bundle, Fi[MODEL_FEATURES].to_numpy())[0].reshape(-1, EVENT_LEN)
            rr = np.array([rule_detects(r, regime(r)) for r in feats_inj]).reshape(-1, EVENT_LEN)
            mp = np.array([persistent(row >= 1.0) for row in u])
            e_m, e_r = mp.any(1), rr.any(1)
            per_case.append({"fault": fault, "severity": sev, "events": int(len(picks)),
                             "window_recall_model": round(float((u >= 1).mean()), 3),
                             "recall_rules": round(float(e_r.mean()), 3),
                             "recall_model": round(float(e_m.mean()), 3),
                             "recall_hybrid": round(float((e_m | e_r).mean()), 3)})
            ev_true += [1] * len(picks); ev_m += list(e_m); ev_r += list(e_r)
            win_true += [1] * u.size; win_m += list((u >= 1).ravel()); win_r += list(rr.ravel())
            c = per_case[-1]
            print(f"    {fault:20s} {sev:6s} recall rules={c['recall_rules']:.2f} "
                  f"model={c['recall_model']:.2f} hybrid={c['recall_hybrid']:.2f}")
    ev_m, ev_r, win_m, win_r = map(np.array, (ev_m, ev_r, win_m, win_r))
    overall = {"rules_only": prf(ev_true, ev_r), "model_only": prf(ev_true, ev_m),
               "hybrid": prf(ev_true, ev_m | ev_r)}
    overall_window = {"rules_only": prf(win_true, win_r), "model_only": prf(win_true, win_m),
                      "hybrid": prf(win_true, win_m | win_r)}
    overall["negative_events"] = int(len(neg_starts))
    for k in ("rules_only", "model_only", "hybrid"):
        v = overall[k]
        print(f"    event-level {k:11s} P={v['precision']:.3f} R={v['recall']:.3f} F1={v['f1']:.3f}")

    print("6/7 Trend / drift analysis across all segments ...")
    df["dt"] = df.groupby("segment_file")["t_s"].diff().clip(upper=5).fillna(0)
    km_seg = (df["speed"].fillna(0) * df["dt"] / 3600).groupby(df["segment_id"]).sum()
    seg_tbl = warm.groupby("segment_id").agg(
        ltft_mean=("ltft_mean", "median"), volt_mean=("volt_mean", "median"),
        coolant_mean=("coolant_mean", "median"), windows=("ltft_mean", "size"))
    seg_tbl["km_end"] = km_seg.cumsum().reindex(seg_tbl.index)
    u_all = anomaly_ratio(bundle, warm[MODEL_FEATURES].to_numpy())[0]
    seg_tbl["model_anomaly_rate"] = pd.Series(u_all >= 1, index=warm.index).groupby(warm.segment_id).mean()
    seg_tbl["lean_low_speed_rate"] = ((warm.trim_total_mean > 25) & (warm.speed_mean < 40)).groupby(warm.segment_id).mean()
    seg_tbl["health_mean"] = pd.Series([u_to_health(u) for u in u_all], index=warm.index).groupby(warm.segment_id).mean()
    seg_tbl["km"] = km_seg.reindex(seg_tbl.index)
    hist_path = os.path.join(HERE, "..", "app", "assets", "sim", "opel_history.json")
    if os.path.isdir(os.path.dirname(hist_path)):   # demo history for the app's Time-To-Failure card
        with open(hist_path, "w") as fh:
            json.dump(seg_tbl.reset_index()[["segment_id", "km", "km_end", "health_mean", "ltft_mean", "volt_mean",
                                             "coolant_mean", "windows"]].round(3).to_dict("records"), fh, indent=1)
    ltft_fc = forecast_indicator(seg_tbl["km_end"], seg_tbl["ltft_mean"], "ltft_mean")
    print(f"    LTFT trend: slope={ltft_fc['slope_per_1000km']}%/1000km r2={ltft_fc['r2']} -> {ltft_fc['status']} "
          f"km_remaining={ltft_fc['km_remaining']}")

    print("    New-car adaptation experiment ...")
    new_car = evaluate_new_car(bundle, warm, windows)

    print("7/7 Saving ...")
    os.makedirs(MODEL_DIR, exist_ok=True); os.makedirs(REPORT_DIR, exist_ok=True)
    bundle["metrics"] = {"clean": clean, "event_level": overall, "window_level": overall_window, "new_car": new_car}
    bundle["model_id"] = uuid.uuid4().hex
    joblib.dump(bundle, os.path.join(MODEL_DIR, "pvms_model.joblib"))
    report = {"model_version": MODEL_VERSION, "dataset_rows": int(len(df)), "windows": int(len(feat)),
              "split": {"train": len(tr), "val": len(va), "test": len(te)},
              "clean_test": clean, "fault_injection": per_case, "overall": overall,
              "overall_window": overall_window, "ltft_forecast": ltft_fc, "new_car": new_car,
              "segments": seg_tbl.reset_index().round(4).to_dict("records")}
    with open(os.path.join(REPORT_DIR, "evaluation.json"), "w") as fh:
        json.dump(report, fh, indent=2, default=float)
    write_markdown(report)
    try:
        plot(seg_tbl, u_te, bundle)
    except Exception as e:  # matplotlib optional
        print(f"    (skipped charts: {e})")
    print(f"Done in {time.time() - t0:.0f}s -> saved_models/pvms_model.joblib, reports/evaluation_report.md")


NEW_CARS = {  # healthy "other cars": same driving physics, different normal levels
    "trims -14 %, 13.6 V (e.g. Japanese car with smart charging)": (-14.0, -0.5),
    "trims -20 %, 14.4 V": (-20.0, 0.3),
}
NEW_CAR_CAL_WINDOWS = 60   # = AUTO_CALIBRATION_WINDOWS in main.py (~18 min warm driving)


def evaluate_new_car(bundle, warm, windows):
    """How does PVMS behave on a car that is NOT the Opel? Before vs after automatic re-centring."""
    rng = np.random.default_rng(11)
    cal_idx = warm[warm.segment_id == 19].index[:NEW_CAR_CAL_WINDOWS]
    ev_idx = rng.choice(warm[warm.segment_id >= 20].index.to_numpy(), 1200, replace=False)

    def feats(idx, dl, dv, fault=None, sev=None, r=None):
        rows = []
        for i in idx:
            w, t = windows[i]
            w = {k: np.array(v, float) for k, v in w.items()}
            w["long_fuel_trim_1"] = w["long_fuel_trim_1"] + dl
            w["battery_voltage"] = w["battery_voltage"] + dv
            if fault:
                w = inject(w, fault, sev, r)
            rows.append(window_features(w, t))
        return pd.DataFrame(rows)

    out = []
    for name, (dl, dv) in NEW_CARS.items():
        ev = feats(ev_idx, dl, dv)
        rules_fp = float(np.mean([rule_detects(x) for x in ev.to_dict("records")]))
        base_fp = float(np.mean(anomaly_ratio(bundle, ev[MODEL_FEATURES].to_numpy())[0] >= 1))
        vb = recenter_bundle(bundle, feats(cal_idx, dl, dv)[MODEL_FEATURES].to_numpy())
        adapted_fp = float(np.mean(anomaly_ratio(vb, ev[MODEL_FEATURES].to_numpy())[0] >= 1))
        rec = {}
        r = np.random.default_rng(5)
        for fault in FAULTS:
            for sev in SEVERITIES:
                Fi = feats(r.choice(ev_idx, 150, replace=False), dl, dv, fault, sev, r)
                rec[f"{fault}/{sev}"] = round(float(np.mean(anomaly_ratio(vb, Fi[MODEL_FEATURES].to_numpy())[0] >= 1)), 3)
        out.append({"car": name, "rules_false_alarm": round(rules_fp, 4), "opel_model_false_alarm": round(base_fp, 4),
                    "adapted_false_alarm": round(adapted_fp, 4), "adapted_recall": rec})
        print(f"    {name}: rules FP={rules_fp:.1%}  Opel model FP={base_fp:.1%}  after learning FP={adapted_fp:.1%}")
    return out


def write_markdown(r):
    c = r["clean_test"]
    L = [f"# PVMS model evaluation (v{r['model_version']})", "",
         f"Dataset: OBD2_panel_opel_2012 — {r['dataset_rows']:,} readings → {r['windows']:,} windows of 30 samples (~36 s each).",
         f"Warm-engine windows: train {r['split']['train']:,} (segments 1–15) · validation {r['split']['val']:,} "
         f"(16–18, sets thresholds) · test {r['split']['test']:,} (19–22, never seen in training).", "",
         "Model: gradient-boosting *normal behaviour* regressors (expected value of each health signal given the",
         "driving context) → residual z-scores → Isolation Forest + learned per-signal limits. An ML alert needs",
         f"the anomaly in {PERSIST_K} of the last {PERSIST_N} windows. Rules = universal OBD-II limits (pvms/rules.py).", "",
         "## 1. False alarms on real, unseen driving (share of windows that raise an alert)", "",
         "| Detector | False-alarm rate |", "|---|---|",
         f"| Rules only | {c['rules_false_alarm_rate']:.1%} |",
         f"| ML, single window (no persistence) | {c['model_false_alarm_rate_raw']:.1%} |",
         f"| ML with persistence | {c['model_false_alarm_rate']:.1%} |",
         f"| Hybrid PVMS (rules + ML) | {c['hybrid_false_alarm_rate']:.1%} |", "",
         "## 2. Detection rate per fault (fault events of 3 consecutive windows ≈ 1 min)", "",
         "| Fault | Severity | Rules | ML model | Hybrid PVMS |", "|---|---|---|---|---|"]
    for x in r["fault_injection"]:
        L.append(f"| {x['fault']} | {x['severity']} | {x['recall_rules']:.0%} | {x['recall_model']:.0%} | {x['recall_hybrid']:.0%} |")
    L += ["", "## 3. Overall Precision / Recall / F1 (event level)", "",
          f"Negatives: {r['overall']['negative_events']:,} real clean 3-window sequences from the test segments. "
          "Positives: every injected fault event.", "",
          "| Detector | Precision | Recall | F1 |", "|---|---|---|---|"]
    for k, name in (("rules_only", "Rules only"), ("model_only", "ML model only"), ("hybrid", "Hybrid PVMS")):
        v = r["overall"][k]
        L.append(f"| {name} | {v['precision']:.3f} | {v['recall']:.3f} | {v['f1']:.3f} |")
    L += ["", "Window level (each window judged alone, no persistence):", "",
          "| Detector | Precision | Recall | F1 |", "|---|---|---|---|"]
    for k, name in (("rules_only", "Rules only"), ("model_only", "ML model only"), ("hybrid", "Hybrid PVMS")):
        v = r["overall_window"][k]
        L.append(f"| {name} | {v['precision']:.3f} | {v['recall']:.3f} | {v['f1']:.3f} |")
    fc = r["ltft_forecast"]
    L += ["", "## 4. Real-data degradation trend (Time-To-Failure demonstration)", "",
          "Long-term fuel trim (warm engine) per refuelling segment:", "",
          "| Segment | km (cumulative) | LTFT median % | Lean at low speed | ML anomaly windows |", "|---|---|---|---|---|"]
    for s in r["segments"]:
        L.append(f"| {s['segment_id']} | {s['km_end']:.0f} | {s['ltft_mean']:.1f} | {s['lean_low_speed_rate']:.1%} | {s['model_anomaly_rate']:.1%} |")
    L += ["", f"Linear trend: {fc['slope_per_1000km']} % per 1000 km (R² = {fc['r2']}), status **{fc['status']}**"
          + (f": projected to reach the +25 % lean-fault limit in ≈ {fc['km_remaining']:,} km." if fc['km_remaining'] else "."),
          "", "Observation: this car's fuel trim is ~+30 % at idle and falls as speed/airflow rises — the classic",
          "signature of an intake vacuum leak. PVMS reports it as an advisory (LEAN_LOW_LOAD), not a fault.", "",
          "## 5. A different car (e.g. Suzuki Alto / Honda Civic) — why PVMS learns each car", "",
          "Simulated by shifting the Opel's normal fuel-trim and voltage levels (same driving physics,",
          f"different 'normal'). Profile learned automatically from the first {NEW_CAR_CAL_WINDOWS} healthy warm windows",
          "(≈18 min) of one drive; tested on later months of driving.", "",
          "| Healthy 'other car' | Rules false alarms | Opel model, not adapted | After automatic learning |",
          "|---|---|---|---|"]
    for c in r["new_car"]:
        L.append(f"| {c['car']} | {c['rules_false_alarm']:.1%} | {c['opel_model_false_alarm']:.1%} | "
                 f"{c['adapted_false_alarm']:.1%} |")
    c0 = r["new_car"][0]["adapted_recall"]
    L += ["", "Fault detection after learning (window level, first car): " +
          ", ".join(f"{k} {v:.0%}" for k, v in c0.items()) + ".", "",
          "Conclusion: judging another car by the Opel's normal is unusable (almost every window flagged), so",
          "PVMS runs **rules only** on a new car, learns its normal levels in the background, then switches",
          "the AI on. A fully car-specific model trained from scratch on 25–60 min was also tested and",
          "false-alarmed on 17–88 % of later drives — too little data — which is why only the offsets are learned.", "",
          "## Method notes and limitations", "",
          "* The dataset has no labelled failures, so faults are injected into held-out real windows using",
          "  physically-motivated signatures (pvms/faults.py). Mild cases sit inside universal 'normal' limits on",
          "  purpose: they measure what the learned, car-specific model adds on top of rules.",
          "* Thresholds are fixed on validation segments before the test segments are touched.",
          "* Rule recall on severe faults is high by construction (rules encode those limits); this is expected.",
          "* All data comes from one car. The 'other car' test shifts levels but keeps the Opel's dynamics; a",
          "  real Pakistani car (different engine size, gearing) must be validated with the scanner.",
          "* Learning assumes the car is healthy during its first ~18 min of warm driving. Windows where a",
          "  rule fires are excluded, and stored fault codes are read at connection, but a fault that already",
          "  existed quietly would be learned as normal — so the first drive should be in a serviced car.",
          "* Real-vehicle validation (Physical Layer WBS) is still required once the ELM327 scanner is available."]
    with open(os.path.join(REPORT_DIR, "evaluation_report.md"), "w", encoding="utf-8") as fh:
        fh.write("\n".join(L) + "\n")


def plot(seg_tbl, u_te, bundle):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    fig, ax = plt.subplots(1, 2, figsize=(12, 4.2))
    ax[0].hist(np.clip(u_te, 0, 3), bins=60, color="#3b82f6", alpha=.85)
    ax[0].axvline(1.0, color="#dc2626", ls="--", label="anomaly threshold (u = 1)")
    ax[0].set_title("Anomaly ratio u on real test windows"); ax[0].set_xlabel("u  (u >= 1 = anomaly; health 100 at u <= 0.6, 50 at u = 1)")
    ax[0].legend()
    ax[1].plot(seg_tbl["km_end"], seg_tbl["ltft_mean"], "o-", color="#0f766e", label="LTFT median per segment")
    ax[1].axhline(25, color="#dc2626", ls="--", label="lean fault limit (+25 %)")
    ax[1].set_title("Long-term fuel trim across 14 months"); ax[1].set_xlabel("km driven"); ax[1].set_ylabel("LTFT %")
    ax[1].legend()
    fig.tight_layout(); fig.savefig(os.path.join(REPORT_DIR, "evaluation_charts.png"), dpi=130)


if __name__ == "__main__":
    main()
