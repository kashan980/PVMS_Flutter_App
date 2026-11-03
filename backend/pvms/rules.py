"""Layer 1: universal, manufacturer-independent diagnostic rules.

These encode automotive domain knowledge that holds for practically every petrol
car with OBD-II (a Suzuki Cultus, a Toyota Corolla or a 2012 Opel). They catch
*absolute* problems from day one, before the ML model has learned a new car.
The ML layer (Isolation Forest) catches *relative* deviations from this specific
car's own normal behaviour.
"""
from __future__ import annotations

from dataclasses import asdict, dataclass

import numpy as np

SEVERITY_RANK = {"info": 1, "warning": 2, "critical": 3}


@dataclass
class Finding:
    code: str
    severity: str          # info | warning | critical
    title: str
    message: str           # plain English for a non-technical driver
    recommendation: str
    source: str = "rule"   # rule | model

    def to_dict(self):
        return asdict(self)


def _ok(x) -> bool:
    return x is not None and not (isinstance(x, float) and np.isnan(x))


def evaluate_rules(f: dict[str, float], regime: str, trip_elapsed_s: float | None = None) -> list[Finding]:
    out: list[Finding] = []
    if regime == "engine_off":
        return out

    # --- Cooling system -------------------------------------------------------
    cmax, cmean = f.get("coolant_max"), f.get("coolant_mean")
    if _ok(cmax) and cmax >= 112:
        out.append(Finding(
            "COOLANT_OVERHEAT", "critical", "Engine overheating",
            f"Coolant temperature reached {cmax:.0f}°C. Normal is roughly 85–105°C.",
            "Pull over safely and switch the engine off. Do not open the radiator cap while hot. "
            "Check coolant level, radiator fan and for leaks before driving again."))
    elif _ok(cmean) and cmean >= 106:
        out.append(Finding(
            "COOLANT_HIGH", "warning", "Engine running hot",
            f"Coolant is averaging {cmean:.0f}°C, above the normal range.",
            "Check the coolant level and that the radiator fan switches on. Avoid heavy load until checked."))

    if (trip_elapsed_s is not None and trip_elapsed_s >= 900 and _ok(cmax) and cmax < 70
            and _ok(f.get("speed_mean")) and f["speed_mean"] > 20):
        out.append(Finding(
            "THERMOSTAT_STUCK_OPEN", "warning", "Engine not reaching operating temperature",
            f"After {trip_elapsed_s/60:.0f} minutes of driving the coolant is only {cmax:.0f}°C.",
            "The thermostat may be stuck open. This raises fuel use and engine wear — have it inspected."))

    # --- Charging system ------------------------------------------------------
    v = f.get("volt_mean")
    if _ok(v):
        if v < 12.6:
            out.append(Finding(
                "CHARGING_FAILURE", "critical", "Battery is not being charged",
                f"System voltage is {v:.1f} V with the engine running (expected 13.5–14.7 V).",
                "The alternator or its belt may have failed. The car can stall when the battery runs down — "
                "drive straight to a mechanic and avoid using A/C and lights unnecessarily."))
        elif v < 13.2:
            out.append(Finding(
                "CHARGING_LOW", "warning", "Low charging voltage",
                f"System voltage is {v:.1f} V with the engine running.",
                "Some cars with 'smart' charging (e.g. many Hondas) run this low on purpose. "
                "Otherwise, have the alternator and battery tested."))
        elif v > 15.0:
            out.append(Finding(
                "CHARGING_HIGH", "warning", "Over-charging",
                f"System voltage is {v:.1f} V — above the safe 14.7 V limit.",
                "The voltage regulator may be faulty. Over-charging can damage the battery and electronics."))

    # --- Fuel mixture (only meaningful once warm / closed loop) ---------------
    if regime == "warm":
        tt = f.get("trim_total_mean")
        # A vacuum leak lets in unmetered air that matters most at low airflow (idle, slow traffic)
        # and fades at speed. Lean only at low speed → advisory; lean at speed → real fault.
        low_airflow = _ok(f.get("speed_mean")) and f["speed_mean"] < 40
        if _ok(tt) and tt > 25:
            if low_airflow:
                out.append(Finding(
                    "LEAN_LOW_LOAD", "info", "Engine runs lean at idle / low speed",
                    f"The ECU is adding {tt:.0f}% extra fuel at low speed. A small vacuum leak is the usual cause.",
                    "Not urgent. At the next service ask the mechanic to check intake hoses for vacuum leaks."))
            else:
                out.append(Finding(
                    "LEAN_CONDITION", "warning", "Engine running lean",
                    f"The ECU is adding {tt:.0f}% extra fuel while driving (fault code P0171 risk).",
                    "Possible causes: vacuum leak, dirty MAF sensor, weak fuel pump or clogged filter. Get it checked."))
        elif _ok(tt) and tt < -20:
            out.append(Finding(
                "RICH_CONDITION", "warning", "Engine running rich",
                f"The ECU is removing {-tt:.0f}% fuel (fault code P0172 risk).",
                "Possible causes: leaking injector, high fuel pressure or faulty sensor. Get it checked."))

        # O2 sensor activity: a dead narrowband sensor sits flat near its 0.45 V bias voltage.
        # (A flat signal near 0 V is normal during fuel cut-off on deceleration, so it is excluded.)
        o2s, o2m = f.get("o2_std"), f.get("o2_mean")
        cruising = _ok(f.get("speed_mean")) and f["speed_mean"] > 30 and _ok(f.get("load_mean")) and f["load_mean"] > 12
        if cruising and _ok(o2s) and _ok(o2m) and o2s < 0.03 and 0.3 < o2m < 0.6:
            out.append(Finding(
                "O2_SENSOR_INACTIVE", "warning", "Oxygen sensor not responding",
                "The upstream O2 sensor signal is flat while cruising.",
                "The sensor may be worn or contaminated. A failed O2 sensor increases fuel use and emissions."))
    return out


def worst_severity(findings: list[Finding]) -> str | None:
    if not findings:
        return None
    return max(findings, key=lambda x: SEVERITY_RANK[x.severity]).severity
