import 'package:equatable/equatable.dart';

abstract class ContactEvent extends Equatable {
  const ContactEvent();

  @override
  List<Object?> get props => [];
}

class LoadContacts extends ContactEvent {
  const LoadContacts();
}

/// Force a reload from the device (bypassing the in-memory cache) — dispatched
/// when the device address book changes or the app resumes.
class RefreshContacts extends ContactEvent {
  const RefreshContacts();
}

class SearchContacts extends ContactEvent {
  final String query;

  const SearchContacts(this.query);

  @override
  List<Object?> get props => [query];
}

// NOTE: contact create/update/delete intentionally have NO bloc events.
// All writes go straight to the device address book via flutter_contacts
// (see AddEditContactScreen._save), and the FlutterContacts.addListener in
// MainNavigation triggers a RefreshContacts to re-read them. A local-table
// CRUD path used to exist here but nothing read from that table — it only
// desynced lookups.
