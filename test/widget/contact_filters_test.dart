import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:communication_super_app/features/contacts/models/contact_model.dart';
import 'package:communication_super_app/features/contacts/services/contact_extras_service.dart';
import 'package:communication_super_app/features/contacts/services/contact_filters.dart';
import 'package:communication_super_app/features/contacts/services/contact_groups_service.dart';
import 'package:communication_super_app/features/contacts/widgets/contact_filter_bar.dart';

/// Matrix row 36: labels and messengers as filters of the contacts tab (labels
/// of the inbox too), each one hideable, and «رمز» only while the secure
/// section is open.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final filters = ContactFilters.instance;
  final eitaa = MessengerAccount(
    key: 'org.eitaa.messenger',
    label: 'ایتا',
    contactIds: const {'1', '3'},
  );

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    filters.debugSet(
      labels: const [
        ContactLabel('خانواده', ['g1', 'g2']),
        ContactLabel('همکاران', ['g3']),
      ],
      messengers: [eitaa],
      hidden: const {},
      labelMembers: const {
        'خانواده': {'2'},
      },
    );
  });

  ContactModel contact(String id, List<String> numbers) => ContactModel(
    id: id,
    name: 'c$id',
    phoneNumber: numbers.first,
    phoneNumbers: numbers,
    createdAt: DateTime(2026),
    updatedAt: DateTime(2026),
  );

  group('ContactFilters', () {
    test('labels, then messengers, then «رمز» only while open', () {
      expect(
        [for (final f in filters.all(secureOpen: false)) f.title],
        ['خانواده', 'همکاران', 'ایتا'],
      );
      expect(filters.all(secureOpen: true).last, ContactFilter.secure);
      // The inbox has no messenger chips.
      expect(
        [
          for (final f in filters.all(secureOpen: false, messengers: false))
            f.title,
        ],
        ['خانواده', 'همکاران'],
      );
    });

    test('a hidden filter leaves the row and is remembered', () async {
      final family = ContactFilter.label('خانواده');
      await filters.setHidden(family, true);
      expect(filters.visible(secureOpen: false), isNot(contains(family)));
      expect(filters.all(secureOpen: false), contains(family));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList('contact_filters_hidden'), ['label:خانواده']);
      await filters.setHidden(family, false);
      expect(filters.visible(secureOpen: false), contains(family));
    });

    test('members of a label and of a messenger', () async {
      expect(await filters.contactIds(ContactFilter.label('خانواده')), {'2'});
      expect(await filters.contactIds(ContactFilter.messenger(eitaa)), {
        '1',
        '3',
      });
      expect(await filters.contactIds(ContactFilter.secure), isNull);
    });

    test('«رمز» matches a contact by any of its numbers, in any form', () {
      final contacts = [
        contact('1', ['+98 912 123 4567']),
        contact('2', ['09351112233', '09121119999']),
        contact('3', ['02188776655']),
      ];
      expect(
        ContactFilters.secureMembers(contacts, ['09121234567', '989121119999']),
        {'1', '2'},
      );
      expect(ContactFilters.secureMembers(contacts, const []), isEmpty);
      expect(ContactFilters.numbersOf(contacts[0]), {'09121234567'});
    });
  });

  group('ContactFilterBar', () {
    Future<void> pump(
      WidgetTester tester, {
      required List<ContactFilter> all,
      ContactFilter? selected,
      ValueChanged<ContactFilter?>? onSelected,
    }) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ContactFilterBar(
            filters: filters.visible(secureOpen: true),
            all: all,
            selected: selected,
            onSelected: onSelected ?? (_) {},
          ),
        ),
      ),
    );

    testWidgets('draws nothing without a single filter', (tester) async {
      await pump(tester, all: const []);
      expect(find.byType(ChoiceChip), findsNothing);
    });

    testWidgets('a chip selects, a second tap goes back to «همه»', (
      tester,
    ) async {
      ContactFilter? picked = ContactFilter.secure;
      await pump(
        tester,
        all: filters.all(secureOpen: true),
        onSelected: (f) => picked = f,
      );
      expect(find.text('همه'), findsOneWidget);
      expect(find.text('رمز'), findsOneWidget);
      await tester.tap(find.text('خانواده'));
      expect(picked, ContactFilter.label('خانواده'));

      await pump(
        tester,
        all: filters.all(secureOpen: true),
        selected: ContactFilter.label('خانواده'),
        onSelected: (f) => picked = f,
      );
      await tester.tap(find.text('خانواده'));
      expect(picked, isNull);
    });

    testWidgets('the editor hides a filter', (tester) async {
      await pump(tester, all: filters.all(secureOpen: false));
      await tester.tap(find.byIcon(Icons.tune));
      await tester.pumpAndSettle();
      expect(find.text('نمایش گروه‌ها'), findsOneWidget);
      await tester.tap(find.widgetWithText(SwitchListTile, 'همکاران'));
      await tester.pumpAndSettle();
      expect(filters.isHidden(ContactFilter.label('همکاران')), isTrue);
    });
  });
}
