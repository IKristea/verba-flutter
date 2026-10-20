import 'dart:convert';

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

  group('arbDescriptions', () {
    test('plain message and every plural form get the description', () {
      final arb = <String, dynamic>{
        'title': 'Home',
        '@title': {'description': 'Screen title'},
        'items': '{count, plural, one{{count} item} other{{count} items}}',
        '@items': {'description': 'Cart items'},
        'plain': 'x',
        '@plain': {},
      };
      expect(arbDescriptions(arb), {'title': 'Screen title', 'items__one': 'Cart items', 'items__other': 'Cart items'});
    });
  });

  group('mergeLocalMetadata', () {
    String remote(Map<String, dynamic> arb) => jsonEncode(arb);
    Map<String, dynamic> merged(Map<String, dynamic> fetched, Map<String, dynamic> template) =>
        jsonDecode(mergeLocalMetadata(remote(fetched), template)) as Map<String, dynamic>;

    test('keeps local description, types and placeholder order', () {
      final out = merged({
        '@@locale': 'ro',
        'range': 'Între {min} și {max} cifre.',
        '@range': {
          'placeholders': {
            'max': {'type': 'String'},
            'min': {'type': 'String'}
          }
        },
      }, {
        'range': 'Between {min} and {max} digits.',
        '@range': {
          'description': 'Phone length',
          'placeholders': {
            'min': {'type': 'int', 'example': '8'},
            'max': {'type': 'int'}
          },
        },
      });
      expect(out['range'], 'Între {min} și {max} cifre.');
      expect(out['@range']['description'], 'Phone length');
      expect((out['@range']['placeholders'] as Map).keys.toList(), ['min', 'max']);
      expect(out['@range']['placeholders']['min'], {'type': 'int', 'example': '8'});
    });

    test('plural argument goes back to its local name', () {
      final out = merged({
        'days': '{count, plural, one{{count} day / {traffic}} other{{count} days / {traffic}}}',
        '@days': {
          'placeholders': {
            'count': {'type': 'int'},
            'traffic': {'type': 'String'}
          }
        },
      }, {
        'days': '{days, plural, one{{days} day / {traffic}} other{{days} days / {traffic}}}',
        '@days': {
          'placeholders': {
            'days': {'type': 'int'},
            'traffic': {'type': 'String', 'example': '3 GB'}
          }
        },
      });
      expect(out['days'], '{days, plural, one{{days} day / {traffic}} other{{days} days / {traffic}}}');
      expect((out['@days']['placeholders'] as Map).keys.toList(), ['days', 'traffic']);
    });

    test('placeholder new in Verba is added, unused local one is dropped', () {
      final out = merged({
        'hi': 'Hi {name}, {city}',
        '@hi': {
          'placeholders': {
            'city': {'type': 'String'},
            'name': {'type': 'String'}
          }
        },
      }, {
        'hi': 'Hi {name}, {age}',
        '@hi': {
          'placeholders': {
            'name': {'type': 'String'},
            'age': {'type': 'int'}
          }
        },
      });
      expect(out['@hi']['placeholders'], {
        'name': {'type': 'String'},
        'city': {'type': 'String'}
      });
    });

    test('keys without local metadata keep what Verba sent', () {
      final out = merged({
        'title': 'Acasă',
        '@title': {'description': 'From Verba'},
        'other': 'x',
      }, {
        'title': 'Home'
      });
      expect(out['@title'], {'description': 'From Verba'});
      expect(out.containsKey('@other'), isFalse);
    });

    test('inner placeholders of select/plural messages are kept', () {
      final out = merged({
        'sent': '{email, select, NONE{Sent} other{Sent to {email}}}',
        '@sent': {
          'placeholders': {
            'email': {'type': 'String'}
          }
        },
      }, {
        'sent': '{email, select, NONE{Sent} other{Sent to {email}}}',
        '@sent': {
          'placeholders': {
            'email': {'type': 'String', 'example': 'a@b.c'}
          }
        },
      });
      expect(out['@sent']['placeholders']['email']['example'], 'a@b.c');
    });
  });
}
