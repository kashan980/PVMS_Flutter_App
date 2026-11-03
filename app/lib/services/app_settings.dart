import 'package:shared_preferences/shared_preferences.dart';

import 'obd/fault_scenarios.dart';

enum DataSourceKind { simulator, obdScanner }

/// Persistent user settings.
class AppSettings {
  final SharedPreferences _p;
  AppSettings._(this._p);

  static Future<AppSettings> load() async => AppSettings._(await SharedPreferences.getInstance());

  /// Laptop running FastAPI on the same Wi-Fi / hotspot as the phone.
  /// Android emulator → http://10.0.2.2:8000
  String get serverUrl => _p.getString('server_url') ?? 'http://192.168.1.100:8000';
  set serverUrl(String v) => _p.setString('server_url', v.trim().replaceAll(RegExp(r'/+$'), ''));

  DataSourceKind get source => DataSourceKind.values[_p.getInt('source') ?? 0];
  set source(DataSourceKind v) => _p.setInt('source', v.index);

  FaultScenario get scenario => FaultScenario.values[_p.getInt('scenario') ?? 0];
  set scenario(FaultScenario v) => _p.setInt('scenario', v.index);

  double get simSpeed => _p.getDouble('sim_speed') ?? 4;
  set simSpeed(double v) => _p.setDouble('sim_speed', v);

  String get vehicleId => _p.getString('vehicle_id') ?? 'my-car';
  set vehicleId(String v) => _p.setString('vehicle_id', v.trim());

  /// Demo of the new-car flow: treat the simulator's Opel trip as an unknown car, so the
  /// server starts in rules-only learning mode instead of using the Opel base model.
  bool get simulatorAsNewCar => _p.getBool('sim_as_new_car') ?? false;
  set simulatorAsNewCar(bool v) => _p.setBool('sim_as_new_car', v);

  /// A real car is identified by its vehicle id; the Opel base model is only for the simulator.
  bool get useBaseModel => source == DataSourceKind.simulator && !simulatorAsNewCar;
  String? get activeVehicleId => useBaseModel ? null : vehicleId;

  String? get lastDeviceId => _p.getString('last_device_id');
  set lastDeviceId(String? v) => v == null ? _p.remove('last_device_id') : _p.setString('last_device_id', v);

  String? get lastDeviceName => _p.getString('last_device_name');
  set lastDeviceName(String? v) => v == null ? _p.remove('last_device_name') : _p.setString('last_device_name', v);
}
