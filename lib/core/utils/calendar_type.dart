/// Which calendar every user-facing date (display + date pickers) is rendered
/// on. Persisted by `SettingsBloc` and mirrored into [DateFormatter.calendar]
/// so the static formatter helpers can stay call-site-free.
enum CalendarType { jalali, gregorian }
