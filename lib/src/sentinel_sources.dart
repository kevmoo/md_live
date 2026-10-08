import 'dart:async';
import 'dart:convert';

final RegExp _fencedCodeBlockRegex = RegExp(
  r'^ {0,3}(`{3,}|~{3,})[^\n]*\n[\s\S]*?^ {0,3}\1[ \t]*$',
  multiLine: true,
);
final RegExp _inlineCodeSpanRegex = RegExp(r'`[^`\n]+`');
const String _sentinelStartCorePattern =
    r'<!--\s*([a-zA-Z0-9_-]+):([a-zA-Z0-9_:-]+):start(?:\s+([^>]*?))?\s*-->';

final RegExp _sentinelStartMarkerRegex = RegExp(_sentinelStartCorePattern);

/// Matches a paired `<!-- <namespace>:<sentinelId>:start ... -->` ...
/// `<!-- <namespace>:<sentinelId>:end -->` block.
///
/// Capture groups: (1) `namespace`, (2) `sentinelId`, (3) optional attribute
/// string, (4) inner block body.
final RegExp sentinelBlockPattern = RegExp(
  '$_sentinelStartCorePattern([\\s\\S]*?)<!--\\s*\\1:\\2:end\\s*-->',
);

/// A matched `<!-- <namespace>:<sentinelId>:start ... -->` ...
/// `<!-- <namespace>:<sentinelId>:end -->` block.
typedef ParsedSentinelBlock = ({
  int start,
  int end,
  String namespace,
  String sentinelId,
  String attrs,
  String body,
});

/// Extracts a trimmed `name="value"` attribute from a sentinel start-marker
/// attribute string [attrs], or returns `null` if absent or empty.
String? extractSentinelMarkerAttr(String attrs, String name) {
  final match = RegExp('\\b$name="([^"]*)"').firstMatch(attrs);
  final val = match?.group(1)?.trim();
  return (val == null || val.isEmpty) ? null : val;
}

/// Parses all paired sentinel blocks in [text], optionally filtering to
/// [namespace] and [sentinelId].
Iterable<ParsedSentinelBlock> parseSentinelBlocks(
  String text, {
  String? namespace,
  String? sentinelId,
}) sync* {
  for (final m in sentinelBlockPattern.allMatches(text)) {
    final ns = m.group(1)!;
    final id = m.group(2)!;
    if (namespace != null && ns != namespace) continue;
    if (sentinelId != null && id != sentinelId) continue;
    yield (
      start: m.start,
      end: m.end,
      namespace: ns,
      sentinelId: id,
      attrs: m.group(3)?.trim() ?? '',
      body: m.group(4)!,
    );
  }
}

String _stripMarkdownCode(String markdown) => markdown
    .replaceAll(_fencedCodeBlockRegex, '')
    .replaceAll(_inlineCodeSpanRegex, '');

/// Extracts all unique `src="<file.json>[#<selector>]"` expressions declared on
/// sentinel start markers in [markdown] (ignoring markers inside fenced code
/// blocks or inline code spans).
Set<String> extractSentinelJsonSources(String markdown) => {
  for (final m in _sentinelStartMarkerRegex.allMatches(
    _stripMarkdownCode(markdown),
  ))
    ?extractSentinelMarkerAttr(m.group(3) ?? '', 'src'),
};

/// Extracts all unique sentinel `<namespace>` prefixes declared on
/// `<!-- <namespace>:<id>:start ... -->` markers in [markdown] (ignoring
/// markers inside fenced code blocks or inline code spans).
Set<String> extractSentinelNamespaces(String markdown) => {
  for (final m in _sentinelStartMarkerRegex.allMatches(
    _stripMarkdownCode(markdown),
  ))
    if (m.group(1)!.trim().isNotEmpty) m.group(1)!.trim(),
};

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
    throw ArgumentError.value(
      src,
      'src',
      'Sentinel src must be a relative file path without ".." traversal.',
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
  if (key.startsWith('@')) return null;
  if (current is Map) return current[key];
  if (current is! List) return null;
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
