import 'package:communication_super_app/core/bloc_providers/app_bloc_providers.dart';
import 'package:communication_super_app/core/database/database_helper.dart';
import 'package:communication_super_app/features/edition/bloc/edition_bloc.dart';
import 'package:communication_super_app/features/secure/bloc/secure_session_bloc.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// The real provider list, built for real.
///
/// A provider can only read the providers listed ABOVE it; reading one listed
/// below throws `ProviderNotFoundException` on the first frame of every
/// launch. That is exactly how the first build of the secure section died on
/// the device (it read AuthBloc, which was listed after it) — with every unit
/// test green, because none of them builds this list.
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    DatabaseHelper.databasePathOverride = inMemoryDatabasePath;
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    DatabaseHelper.resetForTesting();
  });

  testWidgets('every eager bloc can be built in the listed order', (
    tester,
  ) async {
    late SecureSessionBloc secure;
    late EditionBloc edition;
    await tester.pumpWidget(
      AppBlocProviders(
        child: Builder(
          builder: (context) {
            secure = context.read<SecureSessionBloc>();
            edition = context.read<EditionBloc>();
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(secure, isNotNull);
    expect(edition, isNotNull);
  });
}
