import 'package:equatable/equatable.dart';
import '../models/draft_model.dart';
import '../models/message_category_model.dart';

abstract class DraftState extends Equatable {
  const DraftState();

  @override
  List<Object?> get props => [];
}

class DraftInitial extends DraftState {
  const DraftInitial();
}

class DraftLoading extends DraftState {
  const DraftLoading();
}

class DraftsLoaded extends DraftState {
  final List<Draft> drafts;
  final List<MessageCategory> categories;

  /// Total / uncategorized draft counts for the «همه» / «بدون دسته‌بندی» rows.
  final int totalCount;
  final int uncategorizedCount;

  /// The currently-applied filter (null + !uncategorized = «همه»).
  final String? filterCategoryId;
  final bool filterUncategorized;

  const DraftsLoaded({
    required this.drafts,
    required this.categories,
    required this.totalCount,
    required this.uncategorizedCount,
    this.filterCategoryId,
    this.filterUncategorized = false,
  });

  @override
  List<Object?> get props => [
        drafts,
        categories,
        totalCount,
        uncategorizedCount,
        filterCategoryId,
        filterUncategorized,
      ];
}

class DraftError extends DraftState {
  final String message;
  const DraftError(this.message);

  @override
  List<Object?> get props => [message];
}
