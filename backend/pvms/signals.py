"""Canonical OBD-II signal names used everywhere in PVMS.

The Flutter app, the FastAPI JSON contract and the training code all use these
snake_case names. Only *standard* Mode 01 PIDs that a generic ELM327 can read on
almost any petrol car (Opel, Suzuki, Toyota, Honda, ...) are used, so the model
does not depend on manufacturer-specific data.
"""

# name -> (dataset column in OBD2_panel_opel_2012, OBD-II PID, unit)
SIGNALS = {
    "rpm": ("RPM", "010C", "rpm"),
    "speed": ("SPEED", "010D", "km/h"),
    "throttle_pos": ("THROTTLE_POS", "0111", "%"),
    "engine_load": ("ENGINE_LOAD", "0104", "%"),
    "coolant_temp": ("COOLANT_TEMP", "0105", "°C"),
    "intake_temp": ("INTAKE_TEMP", "010F", "°C"),
    "short_fuel_trim_1": ("SHORT_FUEL_TRIM_1", "0106", "%"),
    "long_fuel_trim_1": ("LONG_FUEL_TRIM_1", "0107", "%"),
    "o2_b1s1": ("O2_B1S1", "0114", "V"),
    "battery_voltage": ("ELM_VOLTAGE", "ATRV", "V"),
    # Optional: many cars report only one of MAF / MAP, so the model never needs them.
    "maf": ("MAF", "0110", "g/s"),
    "intake_pressure": ("INTAKE_PRESSURE", "010B", "kPa"),
}

CORE_SIGNALS = [
    "rpm", "speed", "throttle_pos", "engine_load", "coolant_temp", "intake_temp",
    "short_fuel_trim_1", "long_fuel_trim_1", "o2_b1s1", "battery_voltage",
]
OPTIONAL_SIGNALS = ["maf", "intake_pressure"]
ALL_SIGNALS = CORE_SIGNALS + OPTIONAL_SIGNALS

DATASET_TO_SIGNAL = {v[0]: k for k, v in SIGNALS.items()}
