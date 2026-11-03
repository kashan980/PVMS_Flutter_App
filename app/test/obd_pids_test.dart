import 'package:flutter_test/flutter_test.dart';
import 'package:pvms_flutter_app/services/obd/obd_pids.dart';

ObdPid pid(String code) => kPolledPids.firstWhere((p) => p.code == code);

void main() {
  group('Mode 01 decoding (SAE J1979 formulas)', () {
    test('RPM 410C1AF8 -> 1726 rpm', () => expect(decodePid('410C1AF8\r\r>', pid('0C')), 1726));
    test('RPM with spaces + echo/searching noise', () {
      expect(decodePid('SEARCHING...\r41 0C 0F A0 \r', pid('0C')), 1000);
    });
    test('speed 410D3C -> 60 km/h', () => expect(decodePid('410D3C', pid('0D')), 60));
    test('coolant 41057B -> 83 °C', () => expect(decodePid('41057B', pid('05')), 83));
    test('fuel trim 410680 -> 0 %, 41069A -> +20.3 %', () {
      expect(decodePid('410680', pid('06')), 0);
      expect(decodePid('41069A', pid('06')), closeTo(20.3, 0.1));
    });
    test('load 4104FF -> 100 %', () => expect(decodePid('4104FF', pid('04')), closeTo(100, 0.01)));
    test('O2 41145AFF -> 0.45 V', () => expect(decodePid('41145AFF', pid('14')), closeTo(0.45, 1e-9)));
    test('multi-ECU reply takes first matching line', () {
      expect(decodePid('7E8 03 41 0D 32\r410D32\r410D33', pid('0D')), 50);
    });
    test('NO DATA -> null', () => expect(decodePid('NO DATA\r>', pid('10')), isNull));
    test('truncated -> null', () => expect(decodePid('410C1A', pid('0C')), isNull));
  });

  test('ATRV voltage', () {
    expect(parseVoltage('14.2V\r>'), 14.2);
    expect(parseVoltage('12.6 V'), 12.6);
    expect(parseVoltage('?'), isNull);
  });

  test('supported PIDs bitmask', () {
    // BE 1F A8 13: classic example → 01,03,04,05,06,07,0C,0D,0F,10,11,13,15,1C,1F,20
    final s = parseSupportedPids('4100BE1FA813');
    expect(s, containsAll(['01', '04', '05', '06', '07', '0C', '0D', '0F', '10', '11']));
    expect(s.contains('02'), isFalse);
    expect(s.contains('0B'), isFalse);
  });

  group('trouble codes', () {
    test('CAN: count byte then codes', () {
      expect(parseDtcs('43020171030000', isCan: true), ['P0171', 'P0300']);
    });
    test('K-line / ISO: pairs padded with zeros', () {
      expect(parseDtcs('43017101330000', isCan: false), ['P0171', 'P0133']);
    });
    test('C/B/U letters', () {
      expect(parseDtcs('4301C123', isCan: true), ['U0123']);
    });
    test('none', () => expect(parseDtcs('NO DATA'), isEmpty));
  });
}
