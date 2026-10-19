import 'package:communication_super_app/core/theme/theme_bloc.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  Future<ThemeState> loaded() async {
    final bloc = ThemeBloc()..add(const LoadTheme());
    final state = await bloc.stream.first;
    await bloc.close();
    return state;
  }

  test('the phone setting is followed until the user picks a theme', () async {
    SharedPreferences.setMockInitialValues({});
    expect(ThemeBloc().state.themeMode, ThemeMode.system);
    expect((await loaded()).themeMode, ThemeMode.system);
  });

  test('a picked theme is kept', () async {
    SharedPreferences.setMockInitialValues({'theme_mode': 'dark'});
    expect((await loaded()).themeMode, ThemeMode.dark);

    final bloc = ThemeBloc()..add(const SetThemeMode(AppThemeMode.light));
    await bloc.stream.first;
    await bloc.close();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('theme_mode'), 'light');
  });
}
