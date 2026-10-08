/// Resolves an enum value in [values] whose [keyOf] matches [key], or throws
/// an [ArgumentError] naming [typeName].
T enumByKey<T extends Enum>(
  List<T> values,
  String key,
  String Function(T) keyOf,
  String typeName,
) {
  for (final value in values) {
    if (keyOf(value) == key) return value;
  }
  throw ArgumentError.value(key, 'key', 'Unknown $typeName');
}

/// Canonical status values for [KnownFieldType.status], ordered by lifecycle
/// stage from earliest (`DRAFT`) to terminal (`CLOSED_UNMERGED`).
enum KnownStatus {
  draft('DRAFT', '📝 **DRAFT**', 1),
  open('OPEN', '🟢 **OPEN**', 2),
  inReview('IN_REVIEW', '🟡 **IN REVIEW**', 3),
  merged('MERGED', '☑️ **MERGED**', 4),
  fixed('FIXED', '✅ **FIXED**', 5),
  verifiedFixed('VERIFIED_FIXED', '✅ **VERIFIED FIXED**', 6),
  closed('CLOSED', '⚪ **CLOSED**', 7),
  closedUnmerged('CLOSED_UNMERGED', '❌ **CLOSED UNMERGED**', 8);

  const KnownStatus(this.jsonKey, this.markdownBadge, this.lifecycleRank);

  final String jsonKey;
  final String markdownBadge;
  final int lifecycleRank;

  /// Whether this status represents active in-flight work (`DRAFT` or
  /// `IN_REVIEW`).
  bool get isInFlight => this == draft || this == inReview;

  /// Sums the counts of all [isInFlight] statuses in [counts].
  static int countInFlight(Map<KnownStatus, int> counts) => [
    for (final entry in counts.entries)
      if (entry.key.isInFlight) entry.value,
  ].fold(0, (a, b) => a + b);

  static KnownStatus? tryFromKey(String key) {
    for (final value in values) {
      if (value.jsonKey == key) return value;
    }
    return null;
  }

  static KnownStatus fromKey(String key) =>
      enumByKey(values, key, (v) => v.jsonKey, 'KnownStatus');

  /// Maps a GitHub `gh pr view --json state,isDraft` state (`"MERGED"`,
  /// `"OPEN"`, `"CLOSED"`) and [isDraft] flag to the canonical [KnownStatus].
  static KnownStatus fromGithubState(String state, {required bool isDraft}) =>
      switch (state.trim().toUpperCase()) {
        'MERGED' => KnownStatus.merged,
        'OPEN' when isDraft => KnownStatus.draft,
        'OPEN' => KnownStatus.inReview,
        'CLOSED' => KnownStatus.closedUnmerged,
        final upper => KnownStatus.fromKey(upper),
      };
}

/// Counts records in [records] grouped by their [KnownStatus] value at
/// [statusKey].
Map<KnownStatus, int> countByStatus(
  Iterable<Map<String, dynamic>> records, {
  String statusKey = 'status',
}) {
  final counts = <KnownStatus, int>{};
  for (final record in records) {
    if (record[statusKey] case final String key) {
      if (KnownStatus.tryFromKey(key) case final status?) {
        counts[status] = (counts[status] ?? 0) + 1;
      }
    }
  }
  return counts;
}

final RegExp _nonAlphaNumericPattern = RegExp('[^A-Z0-9]+');
final RegExp _edgeUnderscorePattern = RegExp(r'^_+|_+$');

/// Matches a raw status key or rendered status badge cell (such as
/// `"☑️ MERGED"` or `"🟡 IN REVIEW"`) to its [KnownStatus.lifecycleRank], or
/// returns `null` if [cellText] is not a recognized status.
int? tryMatchKnownStatusRank(String cellText) {
  final normalized = cellText
      .toUpperCase()
      .replaceAll(_nonAlphaNumericPattern, '_')
      .replaceAll(_edgeUnderscorePattern, '');
  return KnownStatus.tryFromKey(normalized)?.lifecycleRank;
}

/// Structured components of a validated [KnownFieldType.trackerLink] value.
typedef ParsedTrackerLink = ({String githubRepo, String kind, int number});

/// Parses a canonical GitHub PR/Issue URL
/// (`https://github.com/<owner>/<repo>/(pull|issues)/<num>`) using
/// [Uri.tryParse] and Dart 3 list patterns, or returns `null` if [raw] is not a
/// canonical GitHub tracker link.
ParsedTrackerLink? tryParseTrackerLink(String raw) {
  final uri = Uri.tryParse(raw);
  if (uri == null || uri.toString() != raw) return null;
  final (String repo, String kind, String numStr) = switch (uri) {
    Uri(
      scheme: 'https',
      host: 'github.com',
      hasPort: false,
      userInfo: '',
      hasQuery: false,
      hasFragment: false,
      pathSegments: [
        final owner && != '',
        final name && != '',
        final kind && ('pull' || 'issues'),
        final numStr,
      ],
    )
        when !owner.contains('%') && !name.contains('%') =>
      ('$owner/$name', kind, numStr),
    _ => ('', '', ''),
  };
  if (kind.isEmpty) return null;
  final number = int.tryParse(numStr);
  if (number == null || number <= 0 || '$number' != numStr) return null;
  return (githubRepo: repo, kind: kind, number: number);
}

final RegExp _slotIdDisallowedPattern = RegExp(r'[*<>\[\]]');

String? _validateScalarOrList(
  Object? value,
  String? Function(Object? item) validateItem,
  String typeName,
) {
  if (value is String) return validateItem(value);
  if (value is List && value.isNotEmpty) {
    for (final item in value) {
      final err = validateItem(item);
      if (err != null) return err;
    }
    return null;
  }
  return '$typeName must be a non-empty string or list of strings, '
      'got "$value"';
}

String _formatScalarOrList(
  Object? value,
  String Function(String item) formatItem,
  String typeName,
) => switch (value) {
  final String s => formatItem(s),
  final List<Object?> l => l.map((e) => formatItem(e as String)).join(', '),
  _ => throw ArgumentError.value(value, 'value', 'Invalid $typeName value'),
};

String? _validateSingleTrackerLink(Object? item) {
  if (item is! String || item.trim().isEmpty) {
    return 'tracker_link must be a non-empty string URL, got "$item"';
  }
  if (item.contains('[') || item.contains(']')) {
    return 'tracker_link "$item" must be a raw URL without '
        'Markdown "[...](...)" syntax';
  }
  if (tryParseTrackerLink(item) != null) {
    return null;
  }
  return 'invalid tracker_link "$item" (expected '
      'https://github.com/<owner>/<repo>/(pull|issues)/<num>)';
}

({String markdown, String? repo}) _formatSingleTrackerLink(
  String raw, {
  String? previousRepo,
}) {
  if (tryParseTrackerLink(raw) case (
    githubRepo: final repo,
    kind: _,
    :final number,
  )) {
    final label = (previousRepo == repo) ? '#$number' : '$repo#$number';
    return (markdown: '[$label]($raw)', repo: repo);
  }
  return (markdown: raw, repo: null);
}

String? _validateSlotIdValue(Object? value) {
  if (value is! String || value.trim().isEmpty) {
    return 'slot_id must be a non-empty string, got "$value"';
  }
  if (_slotIdDisallowedPattern.hasMatch(value)) {
    return 'slot_id "$value" must not contain Markdown "**", brackets, '
        'or HTML tags';
  }
  return null;
}

String? _validateSingleCodeSpan(Object? item) {
  if (item is! String || item.trim().isEmpty || item.contains('`')) {
    return 'code_span must be a non-empty string without backticks, '
        'got "$item"';
  }
  return null;
}

/// Known field types for declarative `md-live` JSON schemas
/// (`"field_types"`), providing (a) raw value validation and (b) automatic
/// GFM Markdown cell formatting.
enum KnownFieldType {
  status('status'),
  trackerLink('tracker_link'),
  slotId('slot_id'),
  codeSpan('code_span');

  const KnownFieldType(this.jsonKey);

  final String jsonKey;

  static KnownFieldType? tryFromKey(String key) {
    for (final value in values) {
      if (value.jsonKey == key) return value;
    }
    return null;
  }

  /// Validates a raw JSON field [value], returning `null` if valid or a
  /// human-readable error message if invalid.
  String? validateValue(Object? value) => switch (this) {
    KnownFieldType.status =>
      (value is String && KnownStatus.tryFromKey(value) != null)
          ? null
          : 'invalid status "$value" (expected one of: '
                '${KnownStatus.values.map((s) => s.jsonKey).join(', ')})',
    KnownFieldType.trackerLink => _validateScalarOrList(
      value,
      _validateSingleTrackerLink,
      'tracker_link',
    ),
    KnownFieldType.slotId => _validateSlotIdValue(value),
    KnownFieldType.codeSpan => _validateScalarOrList(
      value,
      _validateSingleCodeSpan,
      'code_span',
    ),
  };

  /// Projects a validated raw JSON field [value] into its canonical GFM
  /// Markdown cell representation.
  String formatMarkdown(Object? value) {
    switch (this) {
      case KnownFieldType.status:
        return KnownStatus.fromKey(value as String).markdownBadge;
      case KnownFieldType.trackerLink:
        String? lastRepo;
        return _formatScalarOrList(value, (item) {
          final formatted = _formatSingleTrackerLink(
            item,
            previousRepo: lastRepo,
          );
          lastRepo = formatted.repo;
          return formatted.markdown;
        }, 'tracker_link');
      case KnownFieldType.slotId:
        return '**${(value as String).trim()}**';
      case KnownFieldType.codeSpan:
        return _formatScalarOrList(value, (s) => '`${s.trim()}`', 'code_span');
    }
  }
}
