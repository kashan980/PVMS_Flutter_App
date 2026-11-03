# PVMS model evaluation (v2.0.0)

Dataset: OBD2_panel_opel_2012 — 789,373 readings → 51,873 windows of 30 samples (~36 s each).
Warm-engine windows: train 28,637 (segments 1–15) · validation 5,856 (16–18, sets thresholds) · test 8,863 (19–22, never seen in training).

Model: gradient-boosting *normal behaviour* regressors (expected value of each health signal given the
driving context) → residual z-scores → Isolation Forest + learned per-signal limits. An ML alert needs
the anomaly in 2 of the last 3 windows. Rules = universal OBD-II limits (pvms/rules.py).

## 1. False alarms on real, unseen driving (share of windows that raise an alert)

| Detector | False-alarm rate |
|---|---|
| Rules only | 1.9% |
| ML, single window (no persistence) | 3.4% |
| ML with persistence | 1.4% |
| Hybrid PVMS (rules + ML) | 3.3% |

## 2. Detection rate per fault (fault events of 3 consecutive windows ≈ 1 min)

| Fault | Severity | Rules | ML model | Hybrid PVMS |
|---|---|---|---|---|
| overheating | mild | 30% | 17% | 34% |
| overheating | severe | 98% | 98% | 98% |
| vacuum_leak | mild | 66% | 38% | 78% |
| vacuum_leak | severe | 81% | 99% | 99% |
| injector_leak | mild | 0% | 73% | 73% |
| injector_leak | severe | 45% | 100% | 100% |
| alternator_failure | mild | 7% | 43% | 44% |
| alternator_failure | severe | 100% | 100% | 100% |
| o2_sensor_degraded | mild | 45% | 4% | 49% |
| o2_sensor_degraded | severe | 81% | 100% | 100% |

## 3. Overall Precision / Recall / F1 (event level)

Negatives: 2,882 real clean 3-window sequences from the test segments. Positives: every injected fault event.

| Detector | Precision | Recall | F1 |
|---|---|---|---|
| Rules only | 0.915 | 0.553 | 0.689 |
| ML model only | 0.962 | 0.671 | 0.790 |
| Hybrid PVMS | 0.912 | 0.775 | 0.838 |

Window level (each window judged alone, no persistence):

| Detector | Precision | Recall | F1 |
|---|---|---|---|
| Rules only | 0.960 | 0.459 | 0.621 |
| ML model only | 0.953 | 0.675 | 0.790 |
| Hybrid PVMS | 0.936 | 0.733 | 0.822 |

## 4. Real-data degradation trend (Time-To-Failure demonstration)

Long-term fuel trim (warm engine) per refuelling segment:

| Segment | km (cumulative) | LTFT median % | Lean at low speed | ML anomaly windows |
|---|---|---|---|---|
| 1 | 604 | 11.7 | 13.5% | 4.5% |
| 2 | 1274 | 14.2 | 14.3% | 2.4% |
| 3 | 1964 | 14.2 | 18.5% | 3.9% |
| 4 | 2647 | 13.2 | 12.7% | 2.1% |
| 5 | 3060 | 12.6 | 13.8% | 2.2% |
| 6 | 3723 | 12.3 | 14.1% | 2.1% |
| 7 | 4426 | 14.0 | 15.1% | 1.6% |
| 8 | 5123 | 14.4 | 12.2% | 1.0% |
| 9 | 5745 | 13.6 | 12.8% | 1.0% |
| 10 | 6391 | 14.4 | 12.3% | 0.6% |
| 11 | 7060 | 13.4 | 10.7% | 0.6% |
| 12 | 7672 | 14.5 | 16.4% | 1.7% |
| 13 | 8265 | 14.0 | 12.1% | 0.9% |
| 14 | 8873 | 15.7 | 15.5% | 0.6% |
| 15 | 9522 | 15.8 | 15.4% | 0.9% |
| 16 | 10206 | 15.3 | 14.5% | 1.6% |
| 17 | 10846 | 14.5 | 14.3% | 1.8% |
| 18 | 11501 | 15.4 | 14.4% | 1.3% |
| 19 | 12175 | 14.6 | 12.9% | 2.4% |
| 20 | 12810 | 17.7 | 25.7% | 5.9% |
| 21 | 13541 | 14.6 | 12.8% | 2.6% |
| 22 | 14185 | 16.2 | 19.6% | 2.4% |

Linear trend: 0.2423 % per 1000 km (R² = 0.562), status **degrading**: projected to reach the +25 % lean-fault limit in ≈ 37,023 km.

Observation: this car's fuel trim is ~+30 % at idle and falls as speed/airflow rises — the classic
signature of an intake vacuum leak. PVMS reports it as an advisory (LEAN_LOW_LOAD), not a fault.

## 5. A different car (e.g. Suzuki Alto / Honda Civic) — why PVMS learns each car

Simulated by shifting the Opel's normal fuel-trim and voltage levels (same driving physics,
different 'normal'). Profile learned automatically from the first 60 healthy warm windows
(≈18 min) of one drive; tested on later months of driving.

| Healthy 'other car' | Rules false alarms | Opel model, not adapted | After automatic learning |
|---|---|---|---|
| trims -14 %, 13.6 V (e.g. Japanese car with smart charging) | 0.4% | 97.4% | 3.1% |
| trims -20 %, 14.4 V | 0.2% | 100.0% | 3.1% |

Fault detection after learning (window level, first car): overheating/mild 17%, overheating/severe 95%, vacuum_leak/mild 35%, vacuum_leak/severe 98%, injector_leak/mild 73%, injector_leak/severe 100%, alternator_failure/mild 9%, alternator_failure/severe 100%, o2_sensor_degraded/mild 2%, o2_sensor_degraded/severe 100%.

Conclusion: judging another car by the Opel's normal is unusable (almost every window flagged), so
PVMS runs **rules only** on a new car, learns its normal levels in the background, then switches
the AI on. A fully car-specific model trained from scratch on 25–60 min was also tested and
false-alarmed on 17–88 % of later drives — too little data — which is why only the offsets are learned.

## Method notes and limitations

* The dataset has no labelled failures, so faults are injected into held-out real windows using
  physically-motivated signatures (pvms/faults.py). Mild cases sit inside universal 'normal' limits on
  purpose: they measure what the learned, car-specific model adds on top of rules.
* Thresholds are fixed on validation segments before the test segments are touched.
* Rule recall on severe faults is high by construction (rules encode those limits); this is expected.
* All data comes from one car. The 'other car' test shifts levels but keeps the Opel's dynamics; a
  real Pakistani car (different engine size, gearing) must be validated with the scanner.
* Learning assumes the car is healthy during its first ~18 min of warm driving. Windows where a
  rule fires are excluded, and stored fault codes are read at connection, but a fault that already
  existed quietly would be learned as normal — so the first drive should be in a serviced car.
* Real-vehicle validation (Physical Layer WBS) is still required once the ELM327 scanner is available.
