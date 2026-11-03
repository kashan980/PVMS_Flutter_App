import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pvms_flutter_app/models/prediction.dart';
import 'package:pvms_flutter_app/models/telemetry_sample.dart';
import 'package:pvms_flutter_app/services/obd/fault_scenarios.dart';
import 'package:pvms_flutter_app/widgets/common.dart';

void main() {
  testWidgets('HealthGauge shows the score', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: Center(child: HealthGauge(value: 87)))));
    await tester.pumpAndSettle();
    expect(find.text('87'), findsOneWidget);
  });

  testWidgets('FindingCard shows plain-English title, message and recommendation', (tester) async {
    const f = Finding(
      code: 'CHARGING_FAILURE',
      severity: 'critical',
      title: 'Battery is not being charged',
      message: 'System voltage is 12.3 V with the engine running.',
      recommendation: 'Drive straight to a mechanic.',
    );
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: FindingCard(f))));
    expect(find.text('Battery is not being charged'), findsOneWidget);
    await tester.tap(find.text('Battery is not being charged'));
    await tester.pumpAndSettle();
    expect(find.text('Drive straight to a mechanic.'), findsOneWidget);
  });

  test('PredictionResult parses the /predict JSON contract', () {
    final r = PredictionResult.fromJson({
      'health_score': 42.5,
      'status': 'warning',
      'regime': 'warm',
      'model_applied': true,
      'model_anomaly': true,
      'persistent': true,
      'model_used': 'base',
      'findings': [
        {'code': 'ML_ANOMALY', 'severity': 'warning', 'title': 't', 'message': 'm', 'recommendation': 'r', 'source': 'model'}
      ],
      'contributors': [
        {'feature': 'volt_mean', 'label': 'Charging voltage', 'value': 13.3, 'expected': 14.1, 'unit': 'V', 'text': 'x', 'ratio': 1.2}
      ],
      'features': {'ltft_mean': 15.2, 'volt_mean': null},
      'latency': {'server_processing_ms': 6.1},
    });
    expect(r.healthScore, 42.5);
    expect(r.findings.single.source, 'model');
    expect(r.contributors.single.expected, 14.1);
    expect(r.feature('ltft_mean'), 15.2);
    expect(r.feature('volt_mean'), isNull);
    expect(r.serverProcessingMs, 6.1);
  });

  test('fault injector: alternator failure pulls voltage to ~12.4 V', () {
    final inj = FaultInjector()..setScenario(FaultScenario.alternatorFailure);
    var s = const TelemetrySample(timestampMs: 0, rpm: 2000, batteryVoltage: 14.1);
    TelemetrySample out = s;
    for (var i = 0; i < 200; i++) {
      out = inj.apply(s, 1.0);
    }
    expect(out.batteryVoltage!, lessThan(12.6));
    s = const TelemetrySample(timestampMs: 0, coolantTemp: 96);
    inj.setScenario(FaultScenario.overheating);
    for (var i = 0; i < 200; i++) {
      out = inj.apply(s, 1.0);
    }
    expect(out.coolantTemp!, greaterThan(112));
  });

  test('TelemetrySample JSON uses backend field names', () {
    const s = TelemetrySample(timestampMs: 5, rpm: 800, shortFuelTrim1: 1.5, longFuelTrim1: 14);
    final j = s.toJson();
    expect(j['rpm'], 800);
    expect(j['short_fuel_trim_1'], 1.5);
    expect(s.totalFuelTrim, 15.5);
    expect(TelemetrySample.fromJson(j).longFuelTrim1, 14);
  });
}
