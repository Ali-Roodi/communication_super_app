import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'core/navigation/app_route_observer.dart';
import 'core/navigation/call_ui_coordinator.dart';
import 'core/theme/app_theme.dart';
import 'core/theme/theme_bloc.dart';
import 'core/bloc_providers/app_bloc_providers.dart';
import 'core/widgets/app_lock_wrapper.dart';
import 'features/authentication/screens/auth_wrapper_screen.dart';
import 'features/messages/services/notification_service.dart';
import 'features/settings/bloc/settings_bloc.dart';
import 'features/settings/bloc/settings_state.dart';

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
      // BlocBuilder داخل AppBlocProviders است تا به ThemeBloc دسترسی داشته باشد
      child: BlocBuilder<ThemeBloc, ThemeState>(
        builder: (context, themeState) {
          // Rebuild the whole app when the calendar changes so every already-
          // built screen re-formats its dates through DateFormatter.
          return BlocBuilder<SettingsBloc, SettingsState>(
            buildWhen: (a, b) => a.calendarType != b.calendarType,
            builder: (context, _) {
              return MaterialApp(
                title: 'قاسم',
                debugShowCheckedModeBanner: false,
                navigatorKey: appNavigatorKey,
                navigatorObservers: [appRouteObserver],
                theme: AppTheme.light,
                darkTheme: AppTheme.dark,
                themeMode: themeState.themeMode,
                builder: (context, child) {
                  return AppLockWrapper(
                    child: child ?? const AuthWrapperScreen(),
                  );
                },
                // CallUiCoordinator sits ABOVE the auth flow: an incoming call
                // must surface its UI even on the PIN screen (default-dialer
                // duty) — the rest of the app stays locked.
                home: const CallUiCoordinator(child: AuthWrapperScreen()),
              );
            },
          );
        },
      ),
    );
  }
}
