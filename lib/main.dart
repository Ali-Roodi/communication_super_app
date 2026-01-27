import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'core/theme/app_theme.dart';
import 'core/bloc_providers/app_bloc_providers.dart';
import 'core/widgets/app_lock_wrapper.dart';
import 'features/authentication/screens/auth_wrapper_screen.dart';
import 'features/messages/services/notification_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Initialize notification service (with error handling)
  try {
    await NotificationService().initialize();
  } catch (e) {
    // Log error but don't crash - notifications can be initialized later
    debugPrint('Failed to initialize notifications: $e');
  }
  
  // Set preferred orientations
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return AppBlocProviders(
      child: MaterialApp(
        title: 'Communication Super App',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.lightTheme,
        darkTheme: AppTheme.darkTheme,
        themeMode: ThemeMode.system,
        builder: (context, child) {
          return AppLockWrapper(
            child: child ?? const AuthWrapperScreen(),
          );
        },
        home: const AuthWrapperScreen(),
      ),
    );
  }
}
