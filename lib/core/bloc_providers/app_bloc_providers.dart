import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:communication_super_app/features/authentication/bloc/auth_bloc.dart';
import 'package:communication_super_app/features/authentication/bloc/auth_event.dart';
import 'package:communication_super_app/features/authentication/repositories/auth_repository.dart';
import 'package:communication_super_app/features/contacts/bloc/contact_bloc.dart';
import 'package:communication_super_app/features/contacts/repositories/contact_repository.dart';
import 'package:communication_super_app/features/messages/bloc/message_bloc.dart';
import 'package:communication_super_app/features/messages/bloc/draft_bloc.dart';
import 'package:communication_super_app/features/messages/repositories/draft_repository.dart';
import 'package:communication_super_app/features/messages/bloc/template_bloc.dart';
import 'package:communication_super_app/features/messages/repositories/template_repository.dart';
import 'package:communication_super_app/features/messages/bloc/scheduled_bloc.dart';
import 'package:communication_super_app/features/messages/bloc/scheduled_event.dart';
import 'package:communication_super_app/features/call_history/bloc/call_log_bloc.dart';
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
import 'package:communication_super_app/core/sim/sim_bloc.dart';

class AppBlocProviders extends StatelessWidget {
  final Widget child;

  const AppBlocProviders({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return MultiBlocProvider(
      providers: [
        BlocProvider(create: (context) => ThemeBloc()..add(const LoadTheme())),
        BlocProvider(
          create: (context) =>
              AuthBloc(AuthRepository())..add(const CheckAuthStatus()),
        ),
        // Roster first: the contacts read merges the SIM address book, and the
        // composer/dialer decide whether to show a SIM affordance at all from
        // this. It is cheap (one channel call) and answers nothing until the
        // permission gate runs, which re-dispatches LoadSims.
        BlocProvider(create: (context) => SimBloc()..add(const LoadSims())),
        BlocProvider(create: (context) => ContactBloc(ContactRepository())),
        BlocProvider(create: (context) => MessageBloc()),
        BlocProvider(create: (context) => DraftBloc(DraftRepository())),
        BlocProvider(create: (context) => TemplateBloc(TemplateRepository())),
        // **`lazy: false`, and that is the whole of «زمان‌بندی کار نمی‌کند».**
        // A `BlocProvider` is lazy by default and this bloc is only ever read
        // from `ConversationScreen` and `ScheduledMessagesScreen` — so on an
        // ordinary launch it was never constructed, which meant: the 30-second
        // delivery tick never started, the native AlarmManager alarm was never
        // re-armed for whatever was already pending, and an alarm that fired
        // while the app was alive had no Dart handler to be given back to.
        //
        // A message scheduled for 09:00 whose alarm the OS had dropped
        // (Doze, App Standby, an OEM "sleeping apps" sweep) therefore sat
        // pending through every launch until the user happened to *open a
        // conversation* — at which point the bloc was finally built, the first
        // sweep found it overdue, and it went out that same minute. Which is
        // exactly what was reported: scheduled for 09:00, delivered at 11:00
        // the moment the app was opened.
        BlocProvider(
          lazy: false,
          create: (context) =>
              ScheduledMessageBloc()..add(const LoadScheduled()),
        ),
        BlocProvider(create: (context) => CallLogBloc()),
        BlocProvider(create: (context) => DialerBloc(ContactRepository())),
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
          create: (context) =>
              BlockedNumbersBloc(BlockedNumbersRepository())
                ..add(const LoadBlocked()),
        ),
      ],
      child: child,
    );
  }
}
