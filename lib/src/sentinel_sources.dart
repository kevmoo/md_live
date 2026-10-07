import 'dart:async';
import 'dart:convert';

final RegExp _fencedCodeBlockRegex = RegExp(
  r'^ {0,3}(`{3,}|~{3,})[^\n]*\n[\s\S]*?^ {0,3}\1[ \t]*$',
  multiLine: true,
);
final RegExp _inlineCodeSpanRegex = RegExp(r'`[^`\n]+`');
final RegExp _sentinelStartSrcRegex = RegExp(
  r'<!--\s*[a-zA-Z0-9_-]+:[a-zA-Z0-9_:-]+:start\s+[^>]*?\bsrc="([^"]+)"[^>]*?-->',
);
final RegExp _sentinelNamespaceRegex = RegExp(
  r'<!--\s*([a-zA-Z0-9_-]+):[a-zA-Z0-9_:-]+:start\b[^>]*?-->',
);

/// Extracts all unique `src="<file.json>[#<selector>]"` expressions declared on
/// sentinel start markers in [markdown] (ignoring markers inside fenced code
/// blocks or inline code spans).
Set<String> extractSentinelJsonSources(String markdown) {
  final withoutCode = markdown
      .replaceAll(_fencedCodeBlockRegex, '')
      .replaceAll(_inlineCodeSpanRegex, '');
  return {
    for (final m in _sentinelStartSrcRegex.allMatches(withoutCode))
      if (m.group(1)!.trim().isNotEmpty) m.group(1)!.trim(),
  };
}

/// Extracts all unique sentinel `<namespace>` prefixes declared on
/// `<!-- <namespace>:<id>:start ... -->` markers in [markdown] (ignoring
/// markers inside fenced code blocks or inline code spans).
Set<String> extractSentinelNamespaces(String markdown) {
  final withoutCode = markdown
      .replaceAll(_fencedCodeBlockRegex, '')
      .replaceAll(_inlineCodeSpanRegex, '');
  return {
    for (final m in _sentinelNamespaceRegex.allMatches(withoutCode))
      if (m.group(1)!.trim().isNotEmpty) m.group(1)!.trim(),
  };
}

/// Parses a sentinel `src="<filePath>[#<selector>]"` expression using [Uri] and
/// validates that `filePath` is a safe relative path without parent traversal
/// (`..`).
({String filePath, String? selector}) parseSentinelSourceSpec(String src) {
  final trimmed = src.trim();
  final uri = Uri.tryParse(trimmed);
  final filePath = uri?.path.trim() ?? '';
  if (uri == null ||
      uri.hasScheme ||
      uri.hasAuthority ||
      filePath.isEmpty ||
      filePath.startsWith('/') ||
      filePath.startsWith(r'\') ||
      trimmed.split('#').first.split('/').contains('..') ||
      filePath.split(r'\').contains('..')) {
    throw FormatException(
      'Sentinel src must be a relative file path without ".." traversal.',
      src,
    );
  }
  final selector = uri.hasFragment ? uri.fragment.trim() : null;
  return (
    filePath: filePath,
    selector: (selector == null || selector.isEmpty) ? null : selector,
  );
}

Object? _stepPropertyOnCurrent(Object? current, String key) {
  if (key.isEmpty) return current;
  if (current is Map) return current[key];
  if (current is List) {
    final collected = <Object?>[];
    for (final item in current) {
      if (item is! Map || !item.containsKey(key)) continue;
      final val = item[key];
      if (val is List) {
        collected.addAll(val);
      } else {
        collected.add(val);
      }
    }
    return collected;
  }
  return null;
}

typedef _FilterClause = ({String field, Set<String> values, bool isNegated});

List<_FilterClause>? _parseFilterClauses(String filterExpr) {
  if (filterExpr.isEmpty || !filterExpr.contains('=')) return null;
  final Map<String, List<String>> params;
  try {
    params = Uri(query: filterExpr).queryParametersAll;
  } on FormatException {
    return null;
  }
  if (params.isEmpty) return null;
  final clauses = <_FilterClause>[];
  for (final entry in params.entries) {
    final rawKey = entry.key;
    final isNegated = rawKey.endsWith('!');
    final field = (isNegated ? rawKey.substring(0, rawKey.length - 1) : rawKey)
        .trim();
    final values = entry.value
        .expand((v) => v.split(','))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toSet();
    if (field.isEmpty || values.isEmpty) return null;
    clauses.add((field: field, values: values, isNegated: isNegated));
  }
  return clauses;
}

bool _matchesClause(Map<dynamic, dynamic> item, _FilterClause clause) {
  final actual = item[clause.field]?.toString();
  if (actual == null) return false;
  return clause.isNegated
      ? !clause.values.contains(actual)
      : clause.values.contains(actual);
}

Object? _filterListByField(Object? current, String filterExpr) {
  if (current is! List) return null;
  final clauses = _parseFilterClauses(filterExpr);
  if (clauses == null) return null;
  return [
    for (final item in current)
      if (item is Map && clauses.every((c) => _matchesClause(item, c))) item,
  ];
}

/// Filters [records] using a sentinel query expression (`field=v1,v2&other!=v3`
/// parsed via `Uri(query: filterExpr).queryParametersAll`).
List<Map<String, dynamic>> filterSentinelRecords(
  List<Map<String, dynamic>> records,
  String filterExpr,
) {
  final clauses = _parseFilterClauses(filterExpr.trim());
  if (clauses == null) {
    throw ArgumentError.value(
      filterExpr,
      'filterExpr',
      'Invalid sentinel filter expression.',
    );
  }
  return [
    for (final item in records)
      if (clauses.every((c) => _matchesClause(item, c))) item,
  ];
}

Object? _applySelectorStep(Object? current, String step) {
  final qIdx = step.indexOf('?');
  if (qIdx == -1) {
    return _stepPropertyOnCurrent(current, step.trim());
  }
  final propPart = step.substring(0, qIdx).trim();
  final filterPart = step.substring(qIdx + 1).trim();
  final stepped = _stepPropertyOnCurrent(current, propPart);
  return _filterListByField(stepped, filterPart);
}

/// Evaluates an optional `#<selector>` path (supporting `/`-separated steps and
/// `?field=v1,v2&other!=v3` filters) against [decodedJson] and returns the
/// resulting list of JSON record maps, or `null` if the selector does not
/// resolve to a list of maps.
List<Map<String, dynamic>>? resolveSentinelJsonSlice(
  Object? decodedJson,
  String? selector,
) {
  var current = decodedJson;
  if (selector != null && selector.trim().isNotEmpty) {
    final steps = selector
        .split('/')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty);
    for (final step in steps) {
      current = _applySelectorStep(current, step);
      if (current == null) return null;
    }
  }
  if (current is! List) return null;
  final result = <Map<String, dynamic>>[];
  for (final item in current) {
    if (item is! Map) return null;
    result.add(Map<String, dynamic>.from(item));
  }
  return result;
}

/// Scans [markdown] for sentinel `src="<file.json>[#<selector>]"` attributes,
/// loads each distinct relative `.json` file once via [readJsonFile], and
/// returns a map of `src -> List<Map<String, dynamic>>` slices.
Future<Map<String, List<Map<String, dynamic>>>> bundleSentinelJsonSources(
  String markdown,
  FutureOr<String?> Function(String relativeJsonPath) readJsonFile,
) async {
  final sources = extractSentinelJsonSources(markdown);
  if (sources.isEmpty) return const {};

  final decodedFileCache = <String, Object?>{};
  final bundled = <String, List<Map<String, dynamic>>>{};

  for (final src in sources) {
    final spec = parseSentinelSourceSpec(src);
    if (!decodedFileCache.containsKey(spec.filePath)) {
      final rawJson = await readJsonFile(spec.filePath);
      decodedFileCache[spec.filePath] =
          (rawJson != null && rawJson.trim().isNotEmpty)
          ? jsonDecode(rawJson)
          : null;
    }
    final decoded = decodedFileCache[spec.filePath];
    if (decoded == null) continue;
    final slice = resolveSentinelJsonSlice(decoded, spec.selector);
    if (slice != null) {
      bundled[src] = slice;
    }
  }
  return bundled;
}
