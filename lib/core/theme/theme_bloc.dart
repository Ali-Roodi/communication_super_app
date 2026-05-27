import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ── Events ──────────────────────────────────────────────────────────────────

abstract class ThemeEvent {
  const ThemeEvent();
}

class LoadTheme extends ThemeEvent {
  const LoadTheme();
}

class ToggleTheme extends ThemeEvent {
  const ToggleTheme();
}

class SetDarkTheme extends ThemeEvent {
  const SetDarkTheme();
}

class SetLightTheme extends ThemeEvent {
  const SetLightTheme();
}

// ── State ───────────────────────────────────────────────────────────────────

enum AppThemeMode { light, dark }

class ThemeState {
  final AppThemeMode mode;

  const ThemeState(this.mode);

  bool get isDark => mode == AppThemeMode.dark;

  static const light = ThemeState(AppThemeMode.light);
  static const dark  = ThemeState(AppThemeMode.dark);
}

// ── Bloc ────────────────────────────────────────────────────────────────────

class ThemeBloc extends Bloc<ThemeEvent, ThemeState> {
  static const _prefKey = 'theme_mode_is_dark';

  ThemeBloc() : super(ThemeState.light) {
    on<LoadTheme>(_onLoad);
    on<ToggleTheme>(_onToggle);
    on<SetDarkTheme>((_, emit) => _persist(emit, AppThemeMode.dark));
    on<SetLightTheme>((_, emit) => _persist(emit, AppThemeMode.light));
  }

  Future<void> _onLoad(LoadTheme event, Emitter<ThemeState> emit) async {
    final prefs = await SharedPreferences.getInstance();
    final isDark = prefs.getBool(_prefKey) ?? false;
    emit(ThemeState(isDark ? AppThemeMode.dark : AppThemeMode.light));
  }

  Future<void> _onToggle(ToggleTheme event, Emitter<ThemeState> emit) async {
    final next = state.isDark ? AppThemeMode.light : AppThemeMode.dark;
    await _persist(emit, next);
  }

  Future<void> _persist(Emitter<ThemeState> emit, AppThemeMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefKey, mode == AppThemeMode.dark);
    emit(ThemeState(mode));
  }
}
