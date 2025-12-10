# Communication Super App

A Flutter application for managing contacts, messages, call history, and notes.

## Setup Instructions

### Prerequisites
- Flutter SDK (3.10.1 or higher)
- Android Studio / Xcode
- Android SDK / iOS SDK

### Installation

1. Clone the repository
2. Run `flutter pub get`
3. **Important**: Fix the telephony package namespace issue:
   - **Windows**: Run `.\scripts\fix_telephony_namespace.ps1`
   - **Linux/Mac**: Run `chmod +x scripts/fix_telephony_namespace.sh && ./scripts/fix_telephony_namespace.sh`
4. Run `flutter run`

### Known Issues & Fixes

#### Telephony Package Namespace Error
The `telephony` package (0.2.0) is discontinued and missing a required `namespace` declaration in its Android Gradle configuration. This has been fixed by:
- Adding `namespace = "com.shounakmulay.telephony"` to the telephony package's `build.gradle` file
- A script is provided to automatically apply this fix after `flutter pub get`

**Note**: If you clear the Flutter pub cache, you'll need to run the fix script again.

## Features

- **Authentication**: PIN-based authentication
- **Contacts**: Manage contacts with phone numbers and emails
- **Messages**: Send and receive SMS messages
- **Call History**: View and manage call logs
- **Notes**: Create and manage notes
- **Dialer**: Make phone calls directly from the app

## Project Structure

```
lib/
├── core/           # Core utilities, themes, navigation
├── features/       # Feature modules
│   ├── authentication/
│   ├── contacts/
│   ├── messages/
│   ├── call_history/
│   ├── notes/
│   └── dialer/
└── main.dart       # App entry point
```

## Dependencies

- `flutter_bloc`: State management
- `sqflite`: Local database
- `telephony`: SMS functionality (discontinued, patched)
- `permission_handler`: Runtime permissions
- `flutter_secure_storage`: Secure storage for authentication
- `call_log`: Access device call logs