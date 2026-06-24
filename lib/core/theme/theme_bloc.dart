import 'package:flutter/material.dart';
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

/// Set an explicit theme mode (light / dark / system).
class SetThemeMode extends ThemeEvent {
  final AppThemeMode mode;
  const SetThemeMode(this.mode);
}

// ── State ───────────────────────────────────────────────────────────────────

enum AppThemeMode { light, dark, system }

class ThemeState {
  final AppThemeMode mode;

  const ThemeState(this.mode);

  bool get isDark => mode == AppThemeMode.dark;

  /// Flutter [ThemeMode] for MaterialApp.
  ThemeMode get themeMode {
    switch (mode) {
      case AppThemeMode.light:
        return ThemeMode.light;
      case AppThemeMode.dark:
        return ThemeMode.dark;
      case AppThemeMode.system:
        return ThemeMode.system;
    }
  }

  static const light = ThemeState(AppThemeMode.light);
  static const dark = ThemeState(AppThemeMode.dark);
  static const system = ThemeState(AppThemeMode.system);
}

// ── Bloc ────────────────────────────────────────────────────────────────────

class ThemeBloc extends Bloc<ThemeEvent, ThemeState> {
  // Legacy bool key (pre-system support) — read once for migration.
  static const _legacyKey = 'theme_mode_is_dark';
  static const _modeKey = 'theme_mode';

  ThemeBloc() : super(ThemeState.light) {
    on<LoadTheme>(_onLoad);
    on<ToggleTheme>(_onToggle);
    on<SetDarkTheme>((_, emit) => _persist(emit, AppThemeMode.dark));
    on<SetLightTheme>((_, emit) => _persist(emit, AppThemeMode.light));
    on<SetThemeMode>((e, emit) => _persist(emit, e.mode));
  }

  Future<void> _onLoad(LoadTheme event, Emitter<ThemeState> emit) async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_modeKey);
    if (stored != null) {
      emit(
        ThemeState(
          AppThemeMode.values.firstWhere(
            (m) => m.name == stored,
            orElse: () => AppThemeMode.light,
          ),
        ),
      );
      return;
    }
    // Migrate from the legacy bool key.
    final isDark = prefs.getBool(_legacyKey) ?? false;
    emit(ThemeState(isDark ? AppThemeMode.dark : AppThemeMode.light));
  }

  Future<void> _onToggle(ToggleTheme event, Emitter<ThemeState> emit) async {
    final next = state.isDark ? AppThemeMode.light : AppThemeMode.dark;
    await _persist(emit, next);
  }

  Future<void> _persist(Emitter<ThemeState> emit, AppThemeMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_modeKey, mode.name);
    emit(ThemeState(mode));
  }
}
