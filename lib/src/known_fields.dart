import 'dart:convert';

import 'sentinel_sources.dart';

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

String? _validateStringOrNonEmptyList(
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

String _formatTrackerLinkMarkdown(Object? value) {
  if (value is String) {
    return _formatSingleTrackerLink(value).markdown;
  }
  if (value is List) {
    final parts = <String>[];
    String? lastRepo;
    for (final item in value) {
      final formatted = _formatSingleTrackerLink(
        item as String,
        previousRepo: lastRepo,
      );
      parts.add(formatted.markdown);
      lastRepo = formatted.repo;
    }
    return parts.join(', ');
  }
  throw ArgumentError.value(value, 'value', 'Invalid tracker_link value');
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

String _formatCodeSpanMarkdown(Object? value) {
  if (value is String) return '`${value.trim()}`';
  if (value is List) {
    return value.map((e) => '`${(e as String).trim()}`').join(', ');
  }
  throw ArgumentError.value(value, 'value', 'Invalid code_span value');
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
          : 'invalid status "$value" '
                '(expected one of: '
                '${KnownStatus.values.map((s) => s.jsonKey).join(', ')})',
    KnownFieldType.trackerLink => _validateStringOrNonEmptyList(
      value,
      _validateSingleTrackerLink,
      'tracker_link',
    ),
    KnownFieldType.slotId => _validateSlotIdValue(value),
    KnownFieldType.codeSpan => _validateStringOrNonEmptyList(
      value,
      _validateSingleCodeSpan,
      'code_span',
    ),
  };

  /// Projects a validated raw JSON field [value] into its canonical GFM
  /// Markdown cell representation.
  String formatMarkdown(Object? value) => switch (this) {
    KnownFieldType.status => KnownStatus.fromKey(value as String).markdownBadge,
    KnownFieldType.trackerLink => _formatTrackerLinkMarkdown(value),
    KnownFieldType.slotId => '**${(value as String).trim()}**',
    KnownFieldType.codeSpan => _formatCodeSpanMarkdown(value),
  };
}

Map<String, KnownFieldType> _extractFlatFieldTypes(
  Map<dynamic, dynamic> source,
) => {
  for (final entry in source.entries)
    if (entry case MapEntry(
      key: final String k,
      value: final String v,
    ) when !k.contains('.'))
      k: ?KnownFieldType.tryFromKey(v),
};

Map<String, KnownFieldType> _extractDottedFieldTypes(
  Map<dynamic, dynamic> source,
  String collectionKey,
) {
  final dotPrefix = '$collectionKey.';
  final result = <String, KnownFieldType>{};
  for (final entry in source.entries) {
    if (entry case MapEntry(
      key: final String k,
      value: final String v,
    ) when k.startsWith(dotPrefix)) {
      final field = k.substring(dotPrefix.length);
      final type = KnownFieldType.tryFromKey(v);
      if (field.isNotEmpty && !field.contains('.') && type != null) {
        result[field] = type;
      }
    }
  }
  return result;
}

/// Resolves the `field -> KnownFieldType` map for [collectionKey] from
/// `rootJson['field_types']`, merging any top-level default field types with
/// collection-scoped overrides (supporting both `"collection.field": "type"`
/// and `"collection": {"field": "type"}`).
Map<String, KnownFieldType> resolveCollectionFieldTypes(
  Map<String, dynamic> rootJson, [
  String? collectionKey,
]) {
  final rawFieldTypes = rootJson['field_types'];
  if (rawFieldTypes is! Map) return const {};
  final resolved = _extractFlatFieldTypes(rawFieldTypes);
  if (collectionKey == null) return resolved;
  resolved.addAll(_extractDottedFieldTypes(rawFieldTypes, collectionKey));
  final scoped = rawFieldTypes[collectionKey];
  if (scoped is Map) {
    resolved.addAll(_extractFlatFieldTypes(scoped));
  }
  return resolved;
}

List<String> _validateCollectionKnownFields(
  String collectionKey,
  List<Object?> items,
  Map<String, KnownFieldType> fieldTypes,
  String prefix,
) {
  final errors = <String>[];
  for (var i = 0; i < items.length; i++) {
    final item = items[i];
    if (item is! Map) continue;
    for (final entry in fieldTypes.entries) {
      final field = entry.key;
      if (!item.containsKey(field)) continue;
      final err = entry.value.validateValue(item[field]);
      if (err != null) {
        errors.add('$prefix$collectionKey[$i].$field: $err');
      }
    }
  }
  return errors;
}

String? _validateScopedFieldTypeEntry(
  String parentKey,
  Object? subKey,
  Object? subVal,
  String prefix,
) {
  if (subKey is! String || subKey.isEmpty || subKey.contains('.')) {
    return '${prefix}invalid field_types key "$parentKey.$subKey"';
  }
  if (subVal is! String || KnownFieldType.tryFromKey(subVal) == null) {
    return '${prefix}unknown field_type "$subVal" for "$parentKey.$subKey"';
  }
  return null;
}

List<String> _validateScopedFieldTypesMap(
  Object? parentKey,
  Map<dynamic, dynamic> scoped,
  Map<String, dynamic> rootJson,
  String prefix,
) {
  if (parentKey is! String ||
      parentKey.isEmpty ||
      parentKey.contains('.') ||
      rootJson[parentKey] is! List) {
    return ['${prefix}unknown collection "$parentKey" in field_types'];
  }
  return [
    for (final sub in scoped.entries)
      ?_validateScopedFieldTypeEntry(parentKey, sub.key, sub.value, prefix),
  ];
}

String? _validateStringFieldTypeEntry(
  Object? key,
  String val,
  Map<String, dynamic> rootJson,
  String prefix,
) {
  if (key is! String || key.isEmpty) {
    return '${prefix}invalid field_types key "$key"';
  }
  if (key.contains('.')) {
    final parts = key.split('.');
    if (parts.length != 2 ||
        parts[0].isEmpty ||
        parts[1].isEmpty ||
        rootJson[parts[0]] is! List) {
      return '${prefix}unknown collection in field_types key "$key"';
    }
  }
  if (KnownFieldType.tryFromKey(val) == null) {
    return '${prefix}unknown field_type "$val" for "$key"';
  }
  return null;
}

List<String> _validateFieldTypesDeclaration(
  Map<dynamic, dynamic> rawFieldTypes,
  Map<String, dynamic> rootJson,
  String prefix,
) {
  final errors = <String>[];
  for (final entry in rawFieldTypes.entries) {
    final key = entry.key;
    final val = entry.value;
    if (val is String) {
      final err = _validateStringFieldTypeEntry(key, val, rootJson, prefix);
      if (err != null) errors.add(err);
    } else if (val is Map) {
      errors.addAll(_validateScopedFieldTypesMap(key, val, rootJson, prefix));
    } else {
      errors.add('${prefix}invalid field_types entry for "$key"');
    }
  }
  return errors;
}

List<String> _validateSingleTableColumnsEntry(
  Object? colKey,
  Object? colVal,
  Map<String, dynamic> rootJson,
  String prefix,
) {
  if (colKey is! String || colKey.isEmpty || rootJson[colKey] is! List) {
    return ['${prefix}unknown collection "$colKey" in table_columns'];
  }
  if (colVal is! List ||
      colVal.isEmpty ||
      !colVal.every((e) => e is String && e.trim().isNotEmpty)) {
    final msg =
        '${prefix}table_columns["$colKey"] must be a non-empty '
        'list of column keys';
    return [msg];
  }
  final cols = colVal.cast<String>();
  final items = rootJson[colKey] as List<Object?>;
  final errors = <String>[];
  for (var i = 0; i < items.length; i++) {
    final item = items[i];
    if (item is! Map) continue;
    for (final col in cols) {
      if (col != '#index' && !item.containsKey(col)) {
        errors.add('$prefix$colKey[$i] missing table_columns key "$col"');
      }
    }
  }
  return errors;
}

List<String> _validateTableColumnsDeclaration(
  Object? rawTableCols,
  Map<String, dynamic> rootJson,
  String prefix,
) {
  if (rawTableCols == null) return const [];
  if (rawTableCols is! Map) {
    return ['${prefix}table_columns must be a JSON object map'];
  }
  return [
    for (final entry in rawTableCols.entries)
      ..._validateSingleTableColumnsEntry(
        entry.key,
        entry.value,
        rootJson,
        prefix,
      ),
  ];
}

/// Validates `rootJson['field_types']` and `rootJson['table_columns']`
/// declarations and checks every record in matching collections against its
/// declared [KnownFieldType] rules.
List<String> validateKnownFields(
  Map<String, dynamic> rootJson, {
  String prefix = '',
}) {
  final tableColErrors = _validateTableColumnsDeclaration(
    rootJson['table_columns'],
    rootJson,
    prefix,
  );
  final rawFieldTypes = rootJson['field_types'];
  if (rawFieldTypes == null) return tableColErrors;
  if (rawFieldTypes is! Map) {
    return [
      ...tableColErrors,
      '${prefix}field_types must be a JSON object map',
    ];
  }
  final declErrors = _validateFieldTypesDeclaration(
    rawFieldTypes,
    rootJson,
    prefix,
  );
  if (declErrors.isNotEmpty) return [...tableColErrors, ...declErrors];

  final errors = <String>[...tableColErrors];
  for (final entry in rootJson.entries) {
    if (entry.key == 'field_types' ||
        entry.key == 'table_columns' ||
        entry.value is! List) {
      continue;
    }
    final fieldTypes = resolveCollectionFieldTypes(rootJson, entry.key);
    if (fieldTypes.isEmpty) continue;
    errors.addAll(
      _validateCollectionKnownFields(
        entry.key,
        entry.value as List<Object?>,
        fieldTypes,
        prefix,
      ),
    );
  }
  return errors;
}

({Object? decoded, String? parseError}) _loadCachedSentinelJson(
  String filePath,
  String? Function(String relativeJsonPath) readJsonFileSync,
  Map<String, Object?> decodedCache,
) {
  if (decodedCache.containsKey(filePath)) {
    return (decoded: decodedCache[filePath], parseError: null);
  }
  final raw = readJsonFileSync(filePath);
  if (raw == null || raw.trim().isEmpty) {
    decodedCache[filePath] = null;
    return (decoded: null, parseError: null);
  }
  try {
    final decoded = jsonDecode(raw);
    decodedCache[filePath] = decoded;
    return (decoded: decoded, parseError: null);
  } on FormatException catch (e) {
    decodedCache[filePath] = null;
    return (decoded: null, parseError: e.message);
  }
}

/// Validates that every sentinel `src="<file.json>[#<selector>]"` marker in
/// [markdown] resolves to a non-empty list of JSON object maps via
/// [readJsonFileSync] and passes [validateKnownFields], returning any
/// validation error messages.
List<String> validateSentinelSources(
  String markdown,
  String? Function(String relativeJsonPath) readJsonFileSync, {
  String? markdownName,
}) {
  final sources = extractSentinelJsonSources(markdown);
  if (sources.isEmpty) return const [];

  final prefix = markdownName != null ? '$markdownName: ' : '';
  final decodedCache = <String, Object?>{};
  final validatedFiles = <String>{};
  final errors = <String>[];

  for (final src in sources) {
    final ({String filePath, String? selector}) spec;
    try {
      spec = parseSentinelSourceSpec(src);
    } on FormatException catch (e) {
      errors.add('${prefix}invalid sentinel src "$src" (${e.message})');
      continue;
    }
    final (:decoded, :parseError) = _loadCachedSentinelJson(
      spec.filePath,
      readJsonFileSync,
      decodedCache,
    );
    if (parseError != null) {
      errors.add('${prefix}invalid JSON in "${spec.filePath}" ($parseError)');
    }
    if (decoded == null) {
      errors.add(
        '${prefix}missing JSON file "${spec.filePath}" for src="$src"',
      );
      continue;
    }
    if (validatedFiles.add(spec.filePath) && decoded is Map) {
      errors.addAll(
        validateKnownFields(
          Map<String, dynamic>.from(decoded),
          prefix: '$prefix${spec.filePath}: ',
        ),
      );
    }
    final slice = resolveSentinelJsonSlice(decoded, spec.selector);
    if (slice == null || slice.isEmpty) {
      errors.add(
        '${prefix}sentinel src="$src" did not resolve to a '
        'non-empty record list',
      );
    }
  }
  return errors;
}
