import 'package:meta/meta.dart';

/// `search.query`'s `filters` parameter (`protocol.md` §3.3, Task 20 §3).
///
/// Not a chip: a chip is a token the server hands back in a response; a filter
/// is a token the client asks for from a closed set the sidecar owns. This is
/// the request shape, not a response DTO, so it carries no `fromJson` — only
/// `toJson`, for the one direction this ever travels.
///
/// `sortBy` ships only [SortByFilter.viewCount] — the other three real YouTube
/// sort options could not be told apart from relevance by result order across
/// several live probes, so shipping a labelled-but-guessed option was rejected
/// rather than risked. See `sidecar/src/parser/search-filters.ts` for what was
/// actually measured.
enum UploadDateFilter { hour, today, week, month, year }

enum SearchTypeFilter { video, channel, playlist, movie }

enum DurationFilter { short, medium, long }

enum SortByFilter { viewCount }

const Object _unchanged = Object();

@immutable
class SearchFilters {
  const SearchFilters({this.uploadDate, this.type, this.duration, this.sortBy});

  final UploadDateFilter? uploadDate;
  final SearchTypeFilter? type;
  final DurationFilter? duration;
  final SortByFilter? sortBy;

  bool get isEmpty => uploadDate == null && type == null && duration == null && sortBy == null;

  /// Hard invariant 10: every field needs a sentinel, or clearing one filter
  /// dimension back to "any" — passing `null` — would read as "leave it alone"
  /// and the dropdown would appear to do nothing.
  SearchFilters copyWith({
    Object? uploadDate = _unchanged,
    Object? type = _unchanged,
    Object? duration = _unchanged,
    Object? sortBy = _unchanged,
  }) {
    return SearchFilters(
      uploadDate: identical(uploadDate, _unchanged)
          ? this.uploadDate
          : uploadDate as UploadDateFilter?,
      type: identical(type, _unchanged) ? this.type : type as SearchTypeFilter?,
      duration: identical(duration, _unchanged) ? this.duration : duration as DurationFilter?,
      sortBy: identical(sortBy, _unchanged) ? this.sortBy : sortBy as SortByFilter?,
    );
  }

  Map<String, dynamic> toJson() => {
        if (uploadDate != null) 'uploadDate': uploadDate!.name,
        if (type != null) 'type': type!.name,
        if (duration != null) 'duration': duration!.name,
        if (sortBy != null) 'sortBy': sortBy!.name,
      };

  @override
  bool operator ==(Object other) =>
      other is SearchFilters &&
      other.uploadDate == uploadDate &&
      other.type == type &&
      other.duration == duration &&
      other.sortBy == sortBy;

  @override
  int get hashCode => Object.hash(uploadDate, type, duration, sortBy);
}
