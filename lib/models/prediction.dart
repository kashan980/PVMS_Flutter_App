/// Response of POST /predict.
class Finding {
  final String code;
  final String severity; // info | warning | critical
  final String title;
  final String message;
  final String recommendation;
  final String source; // rule | model | local

  const Finding({
    required this.code,
    required this.severity,
    required this.title,
    required this.message,
    required this.recommendation,
    this.source = 'rule',
  });

  factory Finding.fromJson(Map<String, dynamic> j) => Finding(
        code: j['code'] as String,
        severity: j['severity'] as String,
        title: j['title'] as String,
        message: j['message'] as String,
        recommendation: j['recommendation'] as String,
        source: (j['source'] as String?) ?? 'rule',
      );

  Map<String, dynamic> toJson() => {
        'code': code,
        'severity': severity,
        'title': title,
        'message': message,
        'recommendation': recommendation,
        'source': source,
      };
}

class Contributor {
  final String feature;
  final String label;
  final double value;
  final double expected;
  final String unit;
  final String text;

  const Contributor(this.feature, this.label, this.value, this.expected, this.unit, this.text);

  factory Contributor.fromJson(Map<String, dynamic> j) => Contributor(
        j['feature'] as String,
        j['label'] as String,
        (j['value'] as num).toDouble(),
        (j['expected'] as num).toDouble(),
        j['unit'] as String,
        j['text'] as String,
      );
}

class PredictionResult {
  final double? healthScore; // null = not assessed (offline, no AI)
  final String status; // healthy | monitor | warning | critical
  final String regime; // engine_off | warming_up | warm
  final bool modelApplied;
  final bool modelAnomaly;
  final bool persistent;
  final String modelUsed; // base | vehicle | learning | local
  final int? learningCollected; // new car: healthy warm windows learned so far
  final int? learningNeeded;
  final double? learningMinutesLeft;
  final List<Finding> findings;
  final List<Contributor> contributors;
  final Map<String, dynamic> features;
  final double? serverProcessingMs;
  int? roundTripMs; // filled in by ApiService
  final bool offline; // produced by on-phone safety checks, server unreachable

  PredictionResult({
    required this.healthScore,
    required this.status,
    required this.regime,
    required this.modelApplied,
    required this.modelAnomaly,
    required this.persistent,
    required this.modelUsed,
    this.learningCollected,
    this.learningNeeded,
    this.learningMinutesLeft,
    required this.findings,
    required this.contributors,
    required this.features,
    this.serverProcessingMs,
    this.roundTripMs,
    this.offline = false,
  });

  factory PredictionResult.fromJson(Map<String, dynamic> j) => PredictionResult(
        healthScore: (j['health_score'] as num?)?.toDouble(),
        status: j['status'] as String,
        regime: j['regime'] as String,
        modelApplied: j['model_applied'] as bool? ?? false,
        modelAnomaly: j['model_anomaly'] as bool? ?? false,
        persistent: j['persistent'] as bool? ?? false,
        modelUsed: j['model_used'] as String? ?? 'base',
        learningCollected: ((j['learning'] as Map?)?['windows_collected'] as num?)?.toInt(),
        learningNeeded: ((j['learning'] as Map?)?['windows_needed'] as num?)?.toInt(),
        learningMinutesLeft: ((j['learning'] as Map?)?['minutes_remaining'] as num?)?.toDouble(),
        findings: ((j['findings'] as List?) ?? [])
            .map((e) => Finding.fromJson(e as Map<String, dynamic>))
            .toList(),
        contributors: ((j['contributors'] as List?) ?? [])
            .map((e) => Contributor.fromJson(e as Map<String, dynamic>))
            .toList(),
        features: (j['features'] as Map<String, dynamic>?) ?? {},
        serverProcessingMs: ((j['latency'] as Map?)?['server_processing_ms'] as num?)?.toDouble(),
      );

  double? feature(String k) => (features[k] as num?)?.toDouble();
}

/// Response of POST /forecast (Time-To-Failure).
class ForecastResult {
  final String? indicatorLabel;
  final int? kmRemaining;
  final String status; // degrading | threshold_reached | none | insufficient_data
  final int trips;

  const ForecastResult({this.indicatorLabel, this.kmRemaining, required this.status, required this.trips});

  factory ForecastResult.fromJson(Map<String, dynamic> j, int trips) {
    final ttf = j['ttf'] as Map<String, dynamic>?;
    if (ttf == null) {
      final ind = (j['indicators'] as List?) ?? [];
      final enough = ind.any((e) => (e as Map)['status'] != 'insufficient_data');
      return ForecastResult(status: enough ? 'none' : 'insufficient_data', trips: trips);
    }
    return ForecastResult(
      indicatorLabel: ttf['label'] as String?,
      kmRemaining: (ttf['km_remaining'] as num?)?.toInt(),
      status: ttf['status'] as String,
      trips: trips,
    );
  }
}
