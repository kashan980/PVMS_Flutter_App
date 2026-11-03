"""Export one real trip (cold start → warm) from the Opel dataset for the app simulator and tests.

    python export_sim_trace.py
writes  ../app/assets/sim/opel_trip.csv  and  tests/fixtures/opel_trip.csv
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from pvms.dataset import load  # noqa: E402
from pvms.signals import CORE_SIGNALS  # noqa: E402


def main():
    df = load(os.path.join(HERE, "dataset.csv"))
    df = df[df.segment_id >= 19]                       # a trip the model never trained on
    best = None
    for f, g in df.groupby("segment_file"):
        if len(g) < 1400 or g.coolant_temp.iloc[:5].mean() > 40:
            continue
        if g[CORE_SIGNALS].isna().mean().max() > 0.05:
            continue
        score = abs(len(g) - 1700) + (0 if g.speed.max() > 80 else 500)
        if best is None or score < best[0]:
            best = (score, f, g)
    _, f, g = best
    out = g[["t_s"] + CORE_SIGNALS].copy()
    out["t_s"] = (out["t_s"] - out["t_s"].iloc[0]).round(3)
    out = out.round(3)
    for path in (os.path.join(HERE, "..", "app", "assets", "sim", "opel_trip.csv"),
                 os.path.join(HERE, "tests", "fixtures", "opel_trip.csv")):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        out.to_csv(path, index=False)
    print(f"trip {f}: {len(out)} rows, {out.t_s.iloc[-1] / 60:.1f} min, "
          f"coolant {out.coolant_temp.min():.0f}->{out.coolant_temp.max():.0f}°C, max speed {out.speed.max():.0f}")


if __name__ == "__main__":
    main()
