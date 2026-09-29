import 'package:flutter_test/flutter_test.dart';
import 'package:verba_translations/src/arb_convert.dart';
import 'package:verba_translations/src/icu.dart';

void main() {
  group('formatIcu', () {
    test('placeholder-e simple', () {
      expect(formatIcu('Salut, {name}!', {'name': 'Ana'}), 'Salut, Ana!');
      expect(formatIcu('Fără argumente', {}), 'Fără argumente');
    });

    test('plural după regulile limbii', () {
      const m = '{count, plural, =0{niciun fișier} one{{count} fișier} few{{count} fișiere} other{{count} de fișiere}}';
      expect(formatIcu(m, {'count': 0}, locale: 'ro'), 'niciun fișier');
      expect(formatIcu(m, {'count': 1}, locale: 'ro'), '1 fișier');
      expect(formatIcu(m, {'count': 5}, locale: 'ro'), '5 fișiere');
      expect(formatIcu(m, {'count': 25}, locale: 'ro'), '25 de fișiere');
    });

    test('plural rusesc', () {
      const m = '{n, plural, one{# файл} few{# файла} many{# файлов} other{# файла}}';
      expect(formatIcu(m, {'n': 21}, locale: 'ru'), '21 файл');
      expect(formatIcu(m, {'n': 3}, locale: 'ru'), '3 файла');
      expect(formatIcu(m, {'n': 11}, locale: 'ru'), '11 файлов');
    });

    test('select', () {
      const m = '{sex, select, male{El} female{Ea} other{Ei}} a venit';
      expect(formatIcu(m, {'sex': 'female'}), 'Ea a venit');
      expect(formatIcu(m, {'sex': 'x'}), 'Ei a venit');
    });

    test('escaping', () {
      expect(formatIcu("l''app MD-'{'AAAA'}'", {}, escaping: true), "l'app MD-{AAAA}");
      expect(formatIcu("l'app", {}), "l'app");
    });

    test('mesaj stricat sau argument lipsă → null (fallback la textul compilat)', () {
      expect(formatIcu('Salut, {name}', {}), isNull);
      expect(formatIcu('Salut, {name', {'name': 'x'}), isNull);
      expect(formatIcu('a } b', {}), isNull);
    });
  });

  group('arbToVerba', () {
    test('text simplu și {argN}', () {
      expect(arbToVerba('hello', 'Salut, {name}'), {'hello': 'Salut, {name}'});
      expect(arbToVerba('pos', '{arg1} din {arg0}'), {'pos': '{1} din {0}'});
    });

    test('plural întreg → chei plate cu %d', () {
      expect(arbToVerba('files', '{count, plural, =0{niciunul} one{{count} fișier} other{{count} fișiere}}'), {
        'files__zero': 'niciunul',
        'files__one': '%d fișier',
        'files__other': '%d fișiere',
      });
    });

    test('plural în mijlocul textului / select rămân ICU', () {
      const m = 'Ai {count, plural, one{un mesaj} other{{count} mesaje}}';
      expect(arbToVerba('inbox', m), {'inbox': m});
      const s = '{sex, select, male{El} other{Ea}}';
      expect(arbToVerba('who', s), {'who': s});
    });

    test('escaping → acolade dublate în Verba', () {
      expect(arbToVerba('mask', "l''app MD-'{'AAAA'}'", escaping: true), {'mask': "l'app MD-{{AAAA}}"});
      expect(arbToVerba('mask', "l'app"), {'mask': "l'app"});
    });
  });
}
