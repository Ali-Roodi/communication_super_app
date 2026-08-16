import 'dart:async';

/// How a contact's name is written and ordered, mirrored out of `SettingsBloc`.
///
/// A static mirror for the same reason `DateFormatter.calendar` is one: the
/// name is assembled in `ContactRepository`, which is a plain service with no
/// `BuildContext` to read a BLoC from, and every screen in the app then renders
/// whatever string it produced. Keeping the choice in one place is also what
/// guarantees the contacts list, the search results, the dialer suggestions and
/// the fast-scroll index all agree on the same name.
///
/// The formatted name and the sort order are baked into `ContactRepository`'s
/// cache, so changing either flag has to force a re-read — that is what
/// [onChanged] is for.
class ContactNameStyle {
  ContactNameStyle._();

  /// Render «نام خانوادگی، نام» instead of the provider's display name.
  static bool lastNameFirst = false;

  /// Order the address book by family name.
  static bool sortByLastName = false;

  static final StreamController<void> _changes =
      StreamController<void>.broadcast();

  /// Fires after a change has been applied to the statics above.
  ///
  /// `ContactBloc` listens and re-reads the address book — the formatted name
  /// and the ordering are baked into `ContactRepository`'s cache, so the flags
  /// alone would not move a single row until the next cold start. Emitting it
  /// only from [apply] is what guarantees the statics are already correct by
  /// the time the reload runs.
  static Stream<void> get onChanged => _changes.stream;

  /// Applies a new style and announces it when something actually changed.
  static void apply({
    required bool lastNameFirst,
    required bool sortByLastName,
  }) {
    if (ContactNameStyle.lastNameFirst == lastNameFirst &&
        ContactNameStyle.sortByLastName == sortByLastName) {
      return;
    }
    ContactNameStyle.lastNameFirst = lastNameFirst;
    ContactNameStyle.sortByLastName = sortByLastName;
    _changes.add(null);
  }

  /// The name to display for a contact whose parts the provider gave us.
  ///
  /// Falls back to [displayName] whenever either half is missing — a one-word
  /// name, a SIM (ADN) record or a company row has nothing to swap around, and
  /// «، » with an empty side reads as a typo.
  static String format({
    required String displayName,
    String? first,
    String? last,
  }) {
    if (!lastNameFirst) return displayName;
    final f = first?.trim() ?? '';
    final l = last?.trim() ?? '';
    if (f.isEmpty || l.isEmpty) return displayName;
    return '$l، $f';
  }

  /// The string the address book is ordered by — the family name first when the
  /// user asked for that, otherwise the name exactly as it is displayed.
  ///
  /// [displayName] is the **already formatted** name (what [format] returned),
  /// so ordering and rows can never disagree about which string they are about.
  static String sortSource({
    required String displayName,
    String? first,
    String? last,
  }) {
    if (!sortByLastName) return displayName;
    final f = first?.trim() ?? '';
    final l = last?.trim() ?? '';
    if (l.isEmpty) return displayName;
    return f.isEmpty ? l : '$l $f';
  }
}
