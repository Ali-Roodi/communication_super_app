class AppConstants {
  static const String appName = 'Communication Super App';
  static const String appNamePersian = 'قاسم';
  
  // Database
  static const String databaseName = 'communication_app.db';
  static const int databaseVersion = 1;
  
  // Tables
  static const String contactsTable = 'contacts';
  static const String messagesTable = 'messages';
  static const String notesTable = 'notes';
  static const String callLogsTable = 'call_logs';
  
  // Storage Keys
  static const String pinKey = 'app_pin';
  static const String patternKey = 'app_pattern';
  static const String authTypeKey = 'auth_type';
  static const String isAuthenticatedKey = 'is_authenticated';
  static const String themeModeKey = 'theme_mode';
  
  // Auth Types
  static const String authTypePin = 'pin';
  static const String authTypePattern = 'pattern';
  
  // Persian Numbers
  static const Map<String, String> persianNumbers = {
    '0': '۰',
    '1': '۱',
    '2': '۲',
    '3': '۳',
    '4': '۴',
    '5': '۵',
    '6': '۶',
    '7': '۷',
    '8': '۸',
    '9': '۹',
  };
  
  // Persian Letters for Avatar Colors
  static const List<int> avatarColors = [
    0xFFE91E63, // Pink
    0xFF8BC34A, // Olive Green
    0xFF2196F3, // Blue
    0xFFFF9800, // Orange
    0xFF9C27B0, // Purple
    0xFF009688, // Teal
  ];
}




















