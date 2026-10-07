import 'known_fields.dart';
import 'sentinel_sources.dart';

/// Extracts a typed list of JSON object maps from `data[key]`.
List<Map<String, dynamic>> recordsList(Map<String, dynamic> data, String key) =>
    (data[key] as List).cast<Map<String, dynamic>>();

({RegExpMatch startMatch, int endIdx, String endTag})?
_matchSentinelBlockBounds(
  String markdown, {
  required String namespace,
  required String sentinelId,
}) {
  final escNs = RegExp.escape(namespace);
  final escId = RegExp.escape(sentinelId);
  final startPattern = RegExp(
    '<!--\\s*$escNs:$escId:start(?:\\s+([^>]*?))?\\s*-->',
  );
  final endTag = '<!-- $namespace:$sentinelId:end -->';
  final startMatch = startPattern.firstMatch(markdown);
  final endIdx = markdown.indexOf(endTag);
  if (startMatch == null || endIdx == -1 || endIdx <= startMatch.end) {
    return null;
  }
  return (startMatch: startMatch, endIdx: endIdx, endTag: endTag);
}

/// Splices [renderedBody] between `<!-- $namespace:$sentinelId:start ... -->`
/// and `<!-- $namespace:$sentinelId:end -->` in [markdown] with blank-line
/// padding.
///
/// When [src] is provided, emits `src="$src"` on the start marker. When [src]
/// is omitted, preserves any existing attributes (such as `src="..."`) already
/// present on the start marker in [markdown].
String replaceSentinelBlock(
  String markdown, {
  required String namespace,
  required String sentinelId,
  required String renderedBody,
  String? src,
}) {
  final bounds = _matchSentinelBlockBounds(
    markdown,
    namespace: namespace,
    sentinelId: sentinelId,
  );
  if (bounds == null) {
    throw StateError(
      'Missing or misordered sentinel pair '
      '"<!-- $namespace:$sentinelId:start -->" ... '
      '"<!-- $namespace:$sentinelId:end -->".',
    );
  }
  final existingAttrs = bounds.startMatch.group(1)?.trim() ?? '';
  final resolvedAttr = (src != null && src.trim().isNotEmpty)
      ? ' src="${src.trim()}"'
      : (existingAttrs.isNotEmpty ? ' $existingAttrs' : '');
  final startTag = '<!-- $namespace:$sentinelId:start$resolvedAttr -->';
  final replacement =
      '$startTag\n\n${renderedBody.trimRight()}\n\n${bounds.endTag}';
  return markdown.replaceRange(
    bounds.startMatch.start,
    bounds.endIdx + bounds.endTag.length,
    replacement,
  );
}

/// Splices multiple sentinel blocks (`sentinelId -> renderedBody`) from
/// [blocks] into [markdown] under [namespace], optionally setting `src="..."`
/// attributes from [sources] (`sentinelId -> src`).
String replaceSentinelBlocks(
  String markdown, {
  required String namespace,
  required Map<String, String> blocks,
  Map<String, String> sources = const {},
}) {
  var updated = markdown;
  for (final entry in blocks.entries) {
    updated = replaceSentinelBlock(
      updated,
      namespace: namespace,
      sentinelId: entry.key,
      renderedBody: entry.value,
      src: sources[entry.key],
    );
  }
  return updated;
}

final RegExp _unescapedPipePattern = RegExp(r'(?<!\\)\|');

/// Escapes unescaped pipe characters (`|`) inside a Markdown table cell without
/// double-escaping already-escaped `\|` sequences.
String escapeMarkdownTableCell(String text) =>
    text.replaceAll(_unescapedPipePattern, r'\|');

/// Controls whether rendered GFM pipe tables are emitted as unguarded pipe
/// tables (default for Prettier / GitHub) or wrapped in `mdformat` guard
/// comments (`<!-- mdformat off -->` ... `<!-- mdformat on -->`).
enum TableGuardMode {
  /// Emits raw GFM pipe tables with zero guard comments (Prettier / GitHub
  /// default).
  none,

  /// Wraps the table in `<!-- mdformat off(...) -->` ... `<!-- mdformat on -->`
  /// for `mdformat` repositories.
  mdformat,
}

/// Renders a GFM pipe table, optionally wrapped in `<!-- mdformat off -->` ...
/// `<!-- mdformat on -->` guards when [guardMode] is [TableGuardMode.mdformat],
/// escaping pipe characters in each cell.
String renderGuardedMarkdownTable({
  required List<String> headers,
  required List<String> alignments,
  required Iterable<List<String>> rows,
  TableGuardMode guardMode = TableGuardMode.none,
  String? guardComment = 'prevent table wrapping',
}) {
  if (headers.isEmpty || headers.length != alignments.length) {
    throw ArgumentError(
      'headers (${headers.length}) and alignments (${alignments.length}) '
      'must be non-empty and have equal length.',
    );
  }
  final lines = <String>[
    if (guardMode == TableGuardMode.mdformat)
      guardComment == null || guardComment.isEmpty
          ? '<!-- mdformat off -->'
          : '<!-- mdformat off($guardComment) -->',
    '| ${headers.map(escapeMarkdownTableCell).join(' | ')} |',
    '| ${alignments.join(' | ')} |',
  ];
  for (final row in rows) {
    if (row.length != headers.length) {
      throw ArgumentError(
        'Row has ${row.length} cells, expected ${headers.length}.',
      );
    }
    lines.add('| ${row.map(escapeMarkdownTableCell).join(' | ')} |');
  }
  if (guardMode == TableGuardMode.mdformat) {
    lines.add('<!-- mdformat on -->');
  }
  return lines.join('\n');
}

/// Renders a GFM pipe table from [records] by extracting the value at each key
/// in [keys] per row (supporting the virtual `"#index"` 1-based row number
/// column starting at [startRowNumber]), formatting it via [cellFormatters] or
/// [fieldTypes] when provided.
String renderKeyedMarkdownTable(
  List<Map<String, dynamic>> records, {
  required List<String> headers,
  required List<String> alignments,
  required List<String> keys,
  Map<String, String Function(Map<String, dynamic> row)> cellFormatters =
      const {},
  Map<String, KnownFieldType> fieldTypes = const {},
  int startRowNumber = 1,
  TableGuardMode guardMode = TableGuardMode.none,
  String? guardComment = 'prevent table wrapping',
}) {
  final rows = <List<String>>[];
  for (var i = 0; i < records.length; i++) {
    final row = records[i];
    final cells = <String>[];
    for (final key in keys) {
      if (cellFormatters[key] case final formatter?) {
        cells.add(formatter(row));
      } else if (key == '#index') {
        cells.add('**${startRowNumber + i}**');
      } else if (!row.containsKey(key)) {
        throw StateError('Missing column key "$key" in row: $row');
      } else if (fieldTypes[key] case final fieldType?) {
        cells.add(fieldType.formatMarkdown(row[key]));
      } else {
        cells.add('${row[key]}');
      }
    }
    rows.add(cells);
  }
  return renderGuardedMarkdownTable(
    headers: headers,
    alignments: alignments,
    rows: rows,
    guardMode: guardMode,
    guardComment: guardComment,
  );
}

/// Renders a sentinel-wrapped GFM pipe table block
/// (`<!-- $namespace:$sentinelId:start ... -->` ...
/// `<!-- $namespace:$sentinelId:end -->`).
///
/// When [rows] is omitted or empty, emits the header and alignment rows inside
/// the sentinel markers so a downstream [projectSentinelMarkdown] pass can
/// populate the body.
String renderSentinelTableBlock({
  required String namespace,
  required String sentinelId,
  required List<String> headers,
  required List<String> alignments,
  Iterable<List<String>> rows = const [],
  String? src,
  String? cols,
  TableGuardMode guardMode = TableGuardMode.none,
  String? guardComment = 'prevent table wrapping',
}) {
  final table = renderGuardedMarkdownTable(
    headers: headers,
    alignments: alignments,
    rows: rows,
    guardMode: guardMode,
    guardComment: guardComment,
  );
  final srcAttr = (src != null && src.trim().isNotEmpty)
      ? ' src="${src.trim()}"'
      : '';
  final colsAttr = (cols != null && cols.trim().isNotEmpty)
      ? ' cols="${cols.trim()}"'
      : '';
  return '<!-- $namespace:$sentinelId:start$srcAttr$colsAttr -->\n\n'
      '$table\n\n'
      '<!-- $namespace:$sentinelId:end -->';
}

/// Parsed GFM table header row, alignment row, [TableGuardMode], and optional
/// `mdformat` guard comment extracted from an existing Markdown sentinel block.
typedef ParsedMarkdownTableHeader = ({
  List<String> headers,
  List<String> alignments,
  TableGuardMode guardMode,
  String? guardComment,
});

/// Row builder callback for [projectSentinelMarkdown] when a collection uses
/// custom composite cells.
typedef SentinelRowBuilder =
    List<String> Function(Map<String, dynamic> record, int rowIndex);

final RegExp _mdformatOffGuardPattern = RegExp(
  r'^\s*<!--\s*mdformat\s+off(?:\(([^)]*)\))?\s*-->',
  multiLine: true,
);
final RegExp _tableAlignmentCellPattern = RegExp(r'^:?-+:?$');

String _canonicalizeAlignmentCell(String cell) {
  final left = cell.startsWith(':');
  final right = cell.endsWith(':');
  if (left && right) return ':---:';
  if (left) return ':---';
  if (right) return '---:';
  return '---';
}

List<String>? _trySplitPipeTableRow(String line) {
  final trimmed = line.trim();
  if (!trimmed.startsWith('|') ||
      !trimmed.endsWith('|') ||
      trimmed.length < 2) {
    return null;
  }
  final inner = trimmed.substring(1, trimmed.length - 1);
  return inner.split(_unescapedPipePattern).map((c) => c.trim()).toList();
}

final RegExp _fencedBlockOrLineRegex = RegExp(
  r'^ {0,3}(`{3,}|~{3,})[^\n]*\n[\s\S]*?^ {0,3}\1[ \t]*$'
  r'|([^\n]+)',
  multiLine: true,
);

/// Normalizes `\r\n` line endings and canonicalizes GFM pipe table cell padding
/// and alignment dash counts (`:---`, `:---:`, `---:`, `---`) outside fenced
/// code blocks so Prettier (`mdf`)-formatted tables compare equal to `md_live`
/// projections without ignoring cell content or prose whitespace.
String normalizeMarkdownTableFormatting(String markdown) => markdown
    .replaceAll('\r\n', '\n')
    .replaceAllMapped(_fencedBlockOrLineRegex, (match) {
      if (match.group(1) != null) return match.group(0)!;
      final line = match.group(2)!;
      final cells = _trySplitPipeTableRow(line);
      if (cells == null) return line;
      final normalizedCells =
          (cells.isNotEmpty && cells.every(_tableAlignmentCellPattern.hasMatch))
          ? [for (final c in cells) _canonicalizeAlignmentCell(c)]
          : cells;
      return '| ${normalizedCells.join(' | ')} |';
    });

List<List<String>> _extractFirstTwoPipeRows(String blockBody) {
  final pipeRows = <List<String>>[];
  for (final line in blockBody.split('\n')) {
    final cells = _trySplitPipeTableRow(line);
    if (cells != null) {
      pipeRows.add(cells);
      if (pipeRows.length == 2) break;
    } else if (pipeRows.isNotEmpty) {
      break;
    }
  }
  return pipeRows;
}

/// Extracts the GFM pipe table `headers`, `alignments`, `guardMode`, and
/// `mdformat off` `guardComment` from an existing sentinel [blockBody].
ParsedMarkdownTableHeader parseMarkdownTableHeader(
  String blockBody, {
  TableGuardMode defaultGuardMode = TableGuardMode.none,
}) {
  final guardMatch = _mdformatOffGuardPattern.firstMatch(blockBody);
  final guardMode = guardMatch != null
      ? TableGuardMode.mdformat
      : defaultGuardMode;
  final guardComment = guardMatch != null
      ? guardMatch.group(1)
      : (defaultGuardMode == TableGuardMode.mdformat
            ? 'prevent table wrapping'
            : null);
  final pipeRows = _extractFirstTwoPipeRows(blockBody);
  if (pipeRows.length < 2) {
    throw const FormatException(
      'Sentinel block must contain a GFM pipe table header and alignment row.',
    );
  }
  final headers = [for (final c in pipeRows[0]) c.replaceAll(r'\|', '|')];
  final rawAlignments = pipeRows[1];
  if (headers.isEmpty ||
      headers.length != rawAlignments.length ||
      !rawAlignments.every(_tableAlignmentCellPattern.hasMatch)) {
    throw const FormatException(
      'Invalid GFM table header or alignment row in sentinel block.',
    );
  }
  return (
    headers: headers,
    alignments: [for (final a in rawAlignments) _canonicalizeAlignmentCell(a)],
    guardMode: guardMode,
    guardComment: guardComment,
  );
}

List<String>? _parseExplicitColsAttr(String? explicitColsAttr) {
  if (explicitColsAttr == null || explicitColsAttr.trim().isEmpty) return null;
  final cols = explicitColsAttr
      .split(',')
      .map((c) => c.trim())
      .where((c) => c.isNotEmpty)
      .toList();
  return cols.isEmpty ? null : cols;
}

List<String>? _lookupDeclaredTableColumns(
  Map<String, dynamic> rootJson,
  String collectionKey,
) {
  final rawCols = rootJson['table_columns'];
  if (rawCols is! Map) return null;
  final list = rawCols[collectionKey];
  if (list is! List) return null;
  return list.whereType<String>().toList();
}

/// Resolves the ordered list of JSON field keys corresponding to the
/// [expectedColumnCount] columns of a Markdown table for [collectionKey].
List<String> resolveCollectionTableColumns(
  Map<String, dynamic> rootJson,
  String collectionKey, {
  required int expectedColumnCount,
  List<Map<String, dynamic>> records = const [],
  String? explicitColsAttr,
}) {
  final candidates =
      _parseExplicitColsAttr(explicitColsAttr) ??
      _lookupDeclaredTableColumns(rootJson, collectionKey) ??
      (records.isNotEmpty ? records.first.keys.toList() : const <String>[]);
  if (candidates.length != expectedColumnCount) {
    throw StateError(
      'Cannot resolve $expectedColumnCount table columns for "$collectionKey" '
      '(got ${candidates.length} keys: ${candidates.join(', ')}). '
      'Declare "table_columns" in JSON or cols="..." on the sentinel marker.',
    );
  }
  return candidates;
}

/// Returns the trimmed body inside `<!-- $namespace:$sentinelId:start ... -->`
/// and `<!-- $namespace:$sentinelId:end -->` in [markdown], or `null` if no
/// matching sentinel block exists.
String? extractSentinelBlockBody(
  String markdown, {
  required String namespace,
  required String sentinelId,
}) {
  final bounds = _matchSentinelBlockBounds(
    markdown,
    namespace: namespace,
    sentinelId: sentinelId,
  );
  if (bounds == null) return null;
  return markdown.substring(bounds.startMatch.end, bounds.endIdx).trim();
}

String? _extractMarkerAttr(String attrs, String name) {
  final match = RegExp('\\b$name="([^"]*)"').firstMatch(attrs);
  final val = match?.group(1)?.trim();
  return (val == null || val.isEmpty) ? null : val;
}

typedef _SentinelProjection = ({
  String namespace,
  Map<String, Map<String, dynamic>> jsonByPath,
  Map<String, SentinelRowBuilder> rowBuilders,
  Map<String, Map<String, String Function(Map<String, dynamic> row)>>
  cellFormatters,
  Map<String, List<List<String>>> customTableRows,
  Set<String> continuousIndexCollections,
  Map<String, int> collectionRowCounters,
  TableGuardMode? guardMode,
});

String _renderSentinelTableBody(
  _SentinelProjection projection, {
  required String sentinelId,
  required String attrs,
  required String existingBody,
}) {
  final namespace = projection.namespace;
  final tableSpec = parseMarkdownTableHeader(
    existingBody,
    defaultGuardMode: projection.guardMode ?? TableGuardMode.none,
  );
  final effectiveGuardMode = projection.guardMode ?? tableSpec.guardMode;
  if (projection.customTableRows[sentinelId] case final prebuiltRows?) {
    return renderGuardedMarkdownTable(
      headers: tableSpec.headers,
      alignments: tableSpec.alignments,
      rows: prebuiltRows,
      guardMode: effectiveGuardMode,
      guardComment: tableSpec.guardComment,
    );
  }
  final src = _extractMarkerAttr(attrs, 'src');
  if (src == null) {
    throw StateError(
      'Sentinel block "$namespace:$sentinelId" is missing src="...".',
    );
  }
  final spec = parseSentinelSourceSpec(src);
  final rootJson = projection.jsonByPath[spec.filePath];
  if (rootJson == null) {
    throw StateError(
      'Missing JSON source "${spec.filePath}" for "$namespace:$sentinelId".',
    );
  }
  final slice = resolveSentinelJsonSlice(rootJson, spec.selector);
  if (slice == null) {
    throw StateError(
      'Sentinel src="$src" on "$namespace:$sentinelId" did not resolve to a '
      'record list.',
    );
  }
  final collectionKey = (spec.selector ?? '')
      .split('/')
      .last
      .split('?')
      .first
      .trim();
  final isContinuous = projection.continuousIndexCollections.contains(
    collectionKey,
  );
  final startRowNumber = isContinuous
      ? (projection.collectionRowCounters[collectionKey] ?? 1)
      : 1;
  if (isContinuous) {
    projection.collectionRowCounters[collectionKey] =
        startRowNumber + slice.length;
  }
  final rowBuilder =
      projection.rowBuilders[sentinelId] ??
      projection.rowBuilders[collectionKey];
  if (rowBuilder != null) {
    return renderGuardedMarkdownTable(
      headers: tableSpec.headers,
      alignments: tableSpec.alignments,
      rows: [
        for (var i = 0; i < slice.length; i++)
          rowBuilder(slice[i], startRowNumber - 1 + i),
      ],
      guardMode: effectiveGuardMode,
      guardComment: tableSpec.guardComment,
    );
  }
  final keys = resolveCollectionTableColumns(
    rootJson,
    collectionKey,
    expectedColumnCount: tableSpec.headers.length,
    records: slice,
    explicitColsAttr: _extractMarkerAttr(attrs, 'cols'),
  );
  return renderKeyedMarkdownTable(
    slice,
    headers: tableSpec.headers,
    alignments: tableSpec.alignments,
    keys: keys,
    cellFormatters:
        projection.cellFormatters[sentinelId] ??
        projection.cellFormatters[collectionKey] ??
        const {},
    fieldTypes: resolveCollectionFieldTypes(rootJson, collectionKey),
    startRowNumber: startRowNumber,
    guardMode: effectiveGuardMode,
    guardComment: tableSpec.guardComment,
  );
}

final RegExp _validLiveSpanKeyRegex = RegExp(r'^[a-zA-Z0-9_.:-]+$');

final RegExp _codeOrLiveSpanRegex = RegExp(
  r'^ {0,3}(`{3,}|~{3,})[^\n]*\n[\s\S]*?^ {0,3}\1[ \t]*$'
  r'|`[^`\n]+`'
  r'|(<span\s+[^>]*?\bdata-live="([^"]*)"[^>]*>)(?:((?:(?!</?span\b)[\s\S])*?)(</span>))?',
  multiLine: true,
);

({String openTag, String key, String inner, String closeTag})?
_tryParseLiveSpanMatch(Match match) {
  final openTag = match.group(2);
  if (openTag == null) return null;
  final key = match.group(3)!;
  final inner = match.group(4);
  final closeTag = match.group(5);
  if (closeTag == null ||
      inner == null ||
      !_validLiveSpanKeyRegex.hasMatch(key)) {
    throw FormatException(
      'Malformed, unclosed, or nested <span data-live="$key"> tag.',
    );
  }
  return (openTag: openTag, key: key, inner: inner, closeTag: closeTag);
}

/// Renders an inline `<span data-live="$key">$value</span>` scalar element,
/// validating that [key] matches `[a-zA-Z0-9_.:-]+`.
String renderLiveSpan(String key, Object value) {
  if (!_validLiveSpanKeyRegex.hasMatch(key)) {
    throw ArgumentError.value(
      key,
      'key',
      'data-live key must match [a-zA-Z0-9_.:-]+.',
    );
  }
  return '<span data-live="$key">$value</span>';
}

/// Extracts all `(key: ..., value: ...)` pairs from `<span data-live="key">value</span>`
/// elements in [markdown] (ignoring fenced code blocks and inline code spans).
List<({String key, String value})> extractLiveSpanValues(String markdown) => [
  for (final match in _codeOrLiveSpanRegex.allMatches(markdown))
    if (_tryParseLiveSpanMatch(match) case final span?)
      (key: span.key, value: span.inner),
];

/// Replaces the inner content of every `<span data-live="key">...</span>`
/// element in [markdown] (outside fenced code blocks and inline code spans)
/// with `inlineValues[key].toString()`.
String projectInlineLiveSpans(
  String markdown,
  Map<String, Object> inlineValues,
) => markdown.replaceAllMapped(_codeOrLiveSpanRegex, (match) {
  final span = _tryParseLiveSpanMatch(match);
  if (span == null) return match.group(0)!;
  if (!inlineValues.containsKey(span.key)) {
    throw StateError(
      'Unknown data-live key "${span.key}". '
      'Available keys: ${inlineValues.keys.join(', ')}',
    );
  }
  return '${span.openTag}${inlineValues[span.key]}${span.closeTag}';
});

/// Projects all sentinel table blocks under [namespace] and all inline
/// `<span data-live="key">...</span>` elements in [markdown] directly from
/// their declared `src="<file.json>#<selector>"` attributes, existing in-file
/// GFM table headers/alignments, and [inlineValues].
String projectSentinelMarkdown(
  String markdown, {
  required String namespace,
  required Map<String, Map<String, dynamic>> jsonByPath,
  Map<String, SentinelRowBuilder> rowBuilders = const {},
  Map<String, Map<String, String Function(Map<String, dynamic> row)>>
      cellFormatters =
      const {},
  Map<String, List<List<String>>> customTableRows = const {},
  Map<String, Object> inlineValues = const {},
  Set<String> continuousIndexCollections = const {},
  TableGuardMode? guardMode = TableGuardMode.none,
}) {
  final escNs = RegExp.escape(namespace);
  final pattern = RegExp(
    '<!--\\s*$escNs:([a-zA-Z0-9_:-]+):start(?:\\s+([^>]*?))?\\s*-->'
    r'([\s\S]*?)'
    '<!--\\s*$escNs:\\1:end\\s*-->',
  );
  final projection = (
    namespace: namespace,
    jsonByPath: jsonByPath,
    rowBuilders: rowBuilders,
    cellFormatters: cellFormatters,
    customTableRows: customTableRows,
    continuousIndexCollections: continuousIndexCollections,
    collectionRowCounters: <String, int>{},
    guardMode: guardMode,
  );
  final withTables = markdown.replaceAllMapped(pattern, (match) {
    final sentinelId = match.group(1)!;
    final attrs = match.group(2)?.trim() ?? '';
    final existingBody = match.group(3)!;
    final rendered = _renderSentinelTableBody(
      projection,
      sentinelId: sentinelId,
      attrs: attrs,
      existingBody: existingBody,
    );
    final attrSuffix = attrs.isNotEmpty ? ' $attrs' : '';
    return '<!-- $namespace:$sentinelId:start$attrSuffix -->\n\n'
        '$rendered\n\n'
        '<!-- $namespace:$sentinelId:end -->';
  });
  return projectInlineLiveSpans(withTables, inlineValues);
}

/// Formats an integer with comma thousands separators (e.g. `195000` ->
/// `195,000`, `-1250` -> `-1,250`).
String formatCommaInt(int value) {
  final str = value.abs().toString();
  final buf = StringBuffer();
  if (value < 0) buf.write('-');
  for (var i = 0; i < str.length; i++) {
    if (i > 0 && (str.length - i) % 3 == 0) {
      buf.write(',');
    }
    buf.write(str[i]);
  }
  return buf.toString();
}

/// Rounds [value] to an integer and formats it with comma thousands separators.
///
/// When [roundHalfToEven] is `true`, uses round-half-to-even (banker's
/// rounding) for `.5` ties to match IEEE 754 / Python `round()`; otherwise uses
/// `num.round()`.
String formatCommaNum(num value, {bool roundHalfToEven = false}) {
  if (value is int) return formatCommaInt(value);
  final v = value.toDouble();
  final floor = v.floor();
  final rounded = (roundHalfToEven && (v - floor == 0.5))
      ? (floor.isEven ? floor : floor + 1)
      : v.round();
  return formatCommaInt(rounded);
}

/// Formats a speedup ratio (`numerator / denominator`) as a bold Markdown
/// multiplier (`**1.98x**`), optionally appending a signed percentage delta
/// (`(+97.7%)`) when [includeDeltaPercent] is `true` and a warning suffix
/// (` ⚠️`) when [unstable] is `true`.
///
/// Returns [nullText] when either [numerator] or [denominator] is `null`.
/// When `denominator <= 0`, treats the ratio as `0.0`.
String formatSpeedupRatio(
  num? numerator,
  num? denominator, {
  int decimals = 2,
  bool includeDeltaPercent = false,
  int deltaDecimals = 1,
  bool unstable = false,
  String nullText = 'N/A',
}) {
  if (numerator == null || denominator == null) return nullText;
  final numVal = numerator.toDouble();
  final denVal = denominator.toDouble();
  final ratio = denVal > 0 ? (numVal / denVal) : 0.0;
  var formatted = '**${ratio.toStringAsFixed(decimals)}x**';
  if (includeDeltaPercent) {
    final delta = (ratio - 1.0) * 100.0;
    final sign = delta >= 0 ? '+' : '';
    formatted = '$formatted ($sign${delta.toStringAsFixed(deltaDecimals)}%)';
  }
  if (unstable) {
    formatted = '$formatted ⚠️';
  }
  return formatted;
}
