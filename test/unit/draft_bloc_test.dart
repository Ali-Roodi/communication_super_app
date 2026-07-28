import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:communication_super_app/features/messages/bloc/draft_bloc.dart';
import 'package:communication_super_app/features/messages/bloc/draft_event.dart';
import 'package:communication_super_app/features/messages/bloc/draft_state.dart';
import 'package:communication_super_app/features/messages/models/draft_model.dart';
import 'package:communication_super_app/features/messages/models/message_category_model.dart';
import 'package:communication_super_app/features/messages/repositories/draft_repository.dart';

class _MockRepo extends Mock implements DraftRepository {}

Draft _draft(String id, {bool isPinned = false, String? categoryId}) => Draft(
  id: id,
  body: 'متن $id',
  categoryId: categoryId,
  updatedAt: DateTime(2026, 1, 1),
  isPinned: isPinned,
);

void main() {
  late _MockRepo repo;

  setUpAll(() {
    registerFallbackValue(_draft('fallback'));
  });

  setUp(() {
    repo = _MockRepo();
    when(() => repo.getDrafts(
          categoryId: any(named: 'categoryId'),
          uncategorized: any(named: 'uncategorized'),
        )).thenAnswer((_) async => <Draft>[]);
    when(repo.getCategories).thenAnswer((_) async => <MessageCategory>[]);
    when(repo.getDraftCounts).thenAnswer(
      (_) async => (total: 0, uncategorized: 0),
    );
  });

  group('DraftBloc multi-select actions', () {
    blocTest<DraftBloc, DraftState>(
      'DeleteDrafts removes the whole selection and reloads',
      build: () {
        when(() => repo.deleteDrafts(any())).thenAnswer((_) async {});
        return DraftBloc(repo);
      },
      act: (bloc) => bloc.add(const DeleteDrafts(['d1', 'd2'])),
      verify: (_) {
        verify(() => repo.deleteDrafts(['d1', 'd2'])).called(1);
        verify(repo.getCategories).called(1);
      },
    );

    blocTest<DraftBloc, DraftState>(
      'PinDrafts passes the pin flag through',
      build: () {
        when(() => repo.setDraftsPinned(any(), any())).thenAnswer((_) async {});
        return DraftBloc(repo);
      },
      act: (bloc) => bloc.add(const PinDrafts(['d1'], pin: false)),
      verify: (_) =>
          verify(() => repo.setDraftsPinned(['d1'], false)).called(1),
    );

    blocTest<DraftBloc, DraftState>(
      'MoveDraftsToCategory files the selection, null meaning uncategorized',
      build: () {
        when(() => repo.moveDraftsToCategory(any(), any()))
            .thenAnswer((_) async {});
        return DraftBloc(repo);
      },
      act: (bloc) => bloc.add(const MoveDraftsToCategory(['d1'], null)),
      verify: (_) =>
          verify(() => repo.moveDraftsToCategory(['d1'], null)).called(1),
    );

    blocTest<DraftBloc, DraftState>(
      'DeleteCategories drops a filter that pointed at a deleted category',
      build: () {
        when(() => repo.deleteCategories(any())).thenAnswer((_) async {});
        return DraftBloc(repo);
      },
      act: (bloc) async {
        bloc.add(const LoadDrafts(categoryId: 'c1'));
        await Future<void>.delayed(Duration.zero);
        bloc.add(const DeleteCategories(['c1']));
      },
      verify: (_) {
        // The reload after the delete must ask for «همه», not for the category
        // that no longer exists.
        verify(() => repo.getDrafts(categoryId: 'c1', uncategorized: false))
            .called(1);
        verify(() => repo.getDrafts(categoryId: null, uncategorized: false))
            .called(greaterThanOrEqualTo(1));
      },
    );
  });

  group('DraftBloc SaveDraft', () {
    blocTest<DraftBloc, DraftState>(
      'carries the existing pin flag through an edit',
      build: () {
        when(() => repo.getDraft('d1'))
            .thenAnswer((_) async => _draft('d1', isPinned: true));
        when(() => repo.upsertDraft(any())).thenAnswer((_) async {});
        return DraftBloc(repo);
      },
      act: (bloc) => bloc.add(const SaveDraft(id: 'd1', body: 'متن تازه')),
      verify: (_) {
        final saved = verify(() => repo.upsertDraft(captureAny()))
            .captured
            .single as Draft;
        expect(saved.body, 'متن تازه');
        // The upsert REPLACEs the row — losing this flag silently unpinned a
        // draft every time it was edited.
        expect(saved.isPinned, isTrue);
      },
    );

    blocTest<DraftBloc, DraftState>(
      'a brand-new draft is not pinned and is never looked up',
      build: () {
        when(() => repo.upsertDraft(any())).thenAnswer((_) async {});
        return DraftBloc(repo);
      },
      act: (bloc) => bloc.add(const SaveDraft(body: 'متن')),
      verify: (_) {
        verifyNever(() => repo.getDraft(any()));
        final saved = verify(() => repo.upsertDraft(captureAny()))
            .captured
            .single as Draft;
        expect(saved.isPinned, isFalse);
      },
    );
  });
}
