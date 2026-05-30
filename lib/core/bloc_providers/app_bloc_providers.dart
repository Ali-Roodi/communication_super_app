import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:communication_super_app/features/authentication/bloc/auth_bloc.dart';
import 'package:communication_super_app/features/authentication/bloc/auth_event.dart';
import 'package:communication_super_app/features/authentication/repositories/auth_repository.dart';
import 'package:communication_super_app/features/contacts/bloc/contact_bloc.dart';
import 'package:communication_super_app/features/contacts/repositories/contact_repository.dart';
import 'package:communication_super_app/features/messages/bloc/message_bloc.dart';
import 'package:communication_super_app/features/call_history/bloc/call_log_bloc.dart';
import 'package:communication_super_app/features/notes/bloc/note_bloc.dart';
import 'package:communication_super_app/features/dialer/bloc/dialer_bloc.dart';
import 'package:communication_super_app/features/favorites/bloc/favorites_bloc.dart';
import 'package:communication_super_app/features/favorites/bloc/favorites_event.dart';
import 'package:communication_super_app/features/favorites/repositories/favorites_repository.dart';
import 'package:communication_super_app/features/search/bloc/search_bloc.dart';
import 'package:communication_super_app/features/call_history/repositories/call_log_repository.dart';
import 'package:communication_super_app/features/settings/bloc/settings_bloc.dart';
import 'package:communication_super_app/features/settings/bloc/settings_event.dart';
import 'package:communication_super_app/features/settings/bloc/blocked_numbers_bloc.dart';
import 'package:communication_super_app/features/settings/repositories/blocked_numbers_repository.dart';
import 'package:communication_super_app/core/theme/theme_bloc.dart';

class AppBlocProviders extends StatelessWidget {
  final Widget child;

  const AppBlocProviders({
    super.key,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return MultiBlocProvider(
      providers: [
        BlocProvider(
          create: (context) => ThemeBloc()..add(const LoadTheme()),
        ),
        BlocProvider(
          create: (context) => AuthBloc(AuthRepository())
            ..add(const CheckAuthStatus()),
        ),
        BlocProvider(
          create: (context) => ContactBloc(ContactRepository()),
        ),
        BlocProvider(
          create: (context) => MessageBloc(),
        ),
        BlocProvider(
          create: (context) => CallLogBloc(),
        ),
        BlocProvider(
          create: (context) => NoteBloc(),
        ),
        BlocProvider(
          create: (context) => DialerBloc(ContactRepository()),
        ),
        BlocProvider(
          create: (context) =>
              FavoritesBloc(FavoritesRepository())..add(const LoadFavorites()),
        ),
        BlocProvider(
          create: (context) =>
              SearchBloc(ContactRepository(), CallLogRepository()),
        ),
        BlocProvider(
          create: (context) => SettingsBloc()..add(const LoadSettings()),
        ),
        BlocProvider(
          create: (context) => BlockedNumbersBloc(BlockedNumbersRepository())
            ..add(const LoadBlocked()),
        ),
      ],
      child: child,
    );
  }
}


