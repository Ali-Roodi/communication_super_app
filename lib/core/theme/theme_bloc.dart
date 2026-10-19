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

  static const system = ThemeState(AppThemeMode.system);
}

// ── Bloc ────────────────────────────────────────────────────────────────────

class ThemeBloc extends Bloc<ThemeEvent, ThemeState> {
  static const _modeKey = 'theme_mode';

  /// The phone's own light/dark setting until the user picks one: that is
  /// also what the first frame paints with, before the stored choice is read.
  ThemeBloc() : super(ThemeState.system) {
    on<LoadTheme>(_onLoad);
    // Only these two: the theme is set from Settings, which always names the
    // mode it wants. The old toggle/set-dark/set-light trio was never
    // dispatched from anywhere.
    on<SetThemeMode>((e, emit) => _persist(emit, e.mode));
  }

  Future<void> _onLoad(LoadTheme event, Emitter<ThemeState> emit) async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_modeKey);
    emit(
      ThemeState(
        AppThemeMode.values.firstWhere(
          (m) => m.name == stored,
          orElse: () => AppThemeMode.system,
        ),
      ),
    );
  }

  Future<void> _persist(Emitter<ThemeState> emit, AppThemeMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_modeKey, mode.name);
    emit(ThemeState(mode));
  }
}
