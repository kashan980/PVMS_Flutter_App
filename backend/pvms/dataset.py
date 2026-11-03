"""Load the OBD2_panel_opel_2012 dataset (or real-car recordings) and cut it into windows."""
from __future__ import annotations

import os

import numpy as np
import pandas as pd

from .features import WINDOW_SIZE, WINDOW_STEP
from .signals import ALL_SIGNALS, SIGNALS

MAX_GAP_S = 5.0


def load(path: str) -> pd.DataFrame:
    cols = ["timestamp", "segment_id", "segment_file"] + [SIGNALS[s][0] for s in ALL_SIGNALS]
    df = pd.read_csv(path, usecols=cols, low_memory=False)
    df = df.rename(columns={SIGNALS[s][0]: s for s in ALL_SIGNALS})
    df["timestamp"] = pd.to_datetime(df["timestamp"])
    df = df.sort_values(["segment_file", "timestamp"]).reset_index(drop=True)
    df["t_s"] = (df["timestamp"] - df["timestamp"].min()).dt.total_seconds()
    # SPEED 255 km/h is the OBD "invalid" marker on this car, not real speed.
    df.loc[df["speed"] >= 250, "speed"] = np.nan
    return df


def iter_windows(df: pd.DataFrame, size: int = WINDOW_SIZE, step: int = WINDOW_STEP):
    """Yield (segment_id, segment_file, window_dict, t_s) never crossing a trip or a time gap."""
    for (seg, f), g in df.groupby(["segment_id", "segment_file"], sort=False):
        t = g["t_s"].to_numpy()
        gaps = np.where(np.diff(t) > MAX_GAP_S)[0] + 1
        for block in np.split(np.arange(len(g)), gaps):
            if len(block) < size:
                continue
            arrs = {s: g[s].to_numpy()[block] for s in ALL_SIGNALS}
            tb = t[block]
            for i in range(0, len(block) - size + 1, step):
                yield int(seg), f, {s: a[i:i + size] for s, a in arrs.items()}, tb[i:i + size]


def load_recordings(folder: str) -> pd.DataFrame:
    """Load real-car data recorded by the server (backend/recordings/<vehicle>/*.csv)."""
    import glob
    files = sorted(glob.glob(os.path.join(folder, "*.csv")))
    if not files:
        return pd.DataFrame()
    df = pd.concat([pd.read_csv(f) for f in files], ignore_index=True)
    df = df.drop_duplicates("timestamp_ms").sort_values("timestamp_ms").reset_index(drop=True)
    df["t_s"] = (df["timestamp_ms"] - df["timestamp_ms"].iloc[0]) / 1000.0
    # a new trip starts after a pause of more than 5 minutes
    df["segment_file"] = (df["t_s"].diff().fillna(0) > 300).cumsum().astype(str)
    df["segment_id"] = 1
    return df
