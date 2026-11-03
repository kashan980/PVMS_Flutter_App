import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/prediction.dart';
import '../models/telemetry_sample.dart';

class ApiException implements Exception {
  final String message;
  ApiException(this.message);
  @override
  String toString() => message;
}

/// HTTP client for the FastAPI backend.
///
/// Latency (WBS: "Latency Measurement"): the phone stamps the time just before
/// sending and just after the response arrives → round-trip time (RTT). The
/// server separately reports its own processing time, so
///   network time ≈ RTT − server_processing_ms.
class ApiService {
  String baseUrl;
  final http.Client _client = http.Client();
  ApiService(this.baseUrl);

  Uri _u(String path) => Uri.parse('$baseUrl$path');
  static const _json = {'Content-Type': 'application/json'};

  Future<Map<String, dynamic>> _post(String path, Map<String, dynamic> body, Duration timeout) async {
    final http.Response r;
    try {
      r = await _client.post(_u(path), headers: _json, body: jsonEncode(body)).timeout(timeout);
    } catch (_) {
      throw ApiException('Server unreachable ($baseUrl)');
    }
    if (r.statusCode != 200) {
      String detail = r.body;
      try {
        detail = (jsonDecode(r.body) as Map<String, dynamic>)['detail'].toString();
      } catch (_) {
        // keep raw body
      }
      throw ApiException('Server error ${r.statusCode}: $detail');
    }
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  /// Returns (ok, round-trip ms, model version).
  Future<(bool, int, String?)> ping() async {
    final t0 = DateTime.now().millisecondsSinceEpoch;
    try {
      final r = await _client.get(_u('/')).timeout(const Duration(seconds: 4));
      final rtt = DateTime.now().millisecondsSinceEpoch - t0;
      if (r.statusCode != 200) return (false, rtt, null);
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      return ((j['model_loaded'] as bool?) ?? false, rtt, j['model_version'] as String?);
    } catch (_) {
      return (false, DateTime.now().millisecondsSinceEpoch - t0, null);
    }
  }

  Future<PredictionResult> predict(
    List<TelemetrySample> window, {
    String? vehicleId,
    bool useBaseModel = true,
    double? tripElapsedS,
    List<bool>? recentModelFlags,
  }) async {
    final sent = DateTime.now().millisecondsSinceEpoch;
    final j = await _post('/predict', {
      'samples': window.map((s) => s.toJson()).toList(),
      'vehicle_id': vehicleId,
      'use_base_model': useBaseModel,
      'trip_elapsed_s': tripElapsedS,
      'recent_model_flags': recentModelFlags,
      'client_sent_ms': sent,
    }, const Duration(seconds: 8));
    final res = PredictionResult.fromJson(j);
    res.roundTripMs = DateTime.now().millisecondsSinceEpoch - sent;
    return res;
  }

  /// Raw JSON variant used when re-sending windows that were stored offline.
  Future<PredictionResult> predictRaw(Map<String, dynamic> payload) async {
    final j = await _post('/predict', payload, const Duration(seconds: 8));
    return PredictionResult.fromJson(j);
  }

  /// (calibrated, learning windows collected, windows needed) or null if unreachable.
  Future<(bool, int, int)?> vehicleStatus(String vehicleId) async {
    try {
      final r = await _client.get(_u('/vehicles/${Uri.encodeComponent(vehicleId)}')).timeout(const Duration(seconds: 4));
      if (r.statusCode != 200) return null;
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      return (
        j['calibrated'] as bool? ?? false,
        (j['learning_windows'] as num?)?.toInt() ?? 0,
        (j['windows_needed'] as num?)?.toInt() ?? 60,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> resetCalibration(String vehicleId) async {
    await _client.delete(_u('/vehicles/${Uri.encodeComponent(vehicleId)}')).timeout(const Duration(seconds: 4));
  }

  Future<ForecastResult> forecast(List<Map<String, dynamic>> trips) async {
    final j = await _post('/forecast', {'trips': trips}, const Duration(seconds: 8));
    return ForecastResult.fromJson(j, trips.length);
  }
}
