import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'format_compact_json.dart';
import 'io.dart';
import 'md_live_core.dart';
import 'sentinel_sources.dart';

/// Exception thrown by [expectMdLiveClean] when one or more Markdown files (or
/// referenced JSON files when `checkCompactJson` is enabled) have validation
/// errors or drift from their JSON sources on disk.
final class MdLiveVerificationException implements Exception {
  /// Human-readable description of all verification failures, including line
  /// diffs and CLI remediation commands.
  final String message;

  /// Relative or absolute paths of the files that failed verification.
  final List<String> failedFiles;

  MdLiveVerificationException({
    required this.message,
    required this.failedFiles,
  });

  @override
  String toString() => 'MdLiveVerificationException: $message';
}

const Set<String> _ignoredDirectoryNames = {'build', 'node_modules'};

String _displayPath(String rootDir, String fullPath) =>
    p.isWithin(rootDir, fullPath)
    ? p.relative(fullPath, from: rootDir)
    : fullPath;

List<String> _discoverSentinelMarkdownFiles(
  String rootDir, {
  required bool includeLiveSpans,
}) {
  final dir = Directory(rootDir);
  if (!dir.existsSync()) return const [];
  final discovered = <String>[];
  final queue = <Directory>[dir];

  while (queue.isNotEmpty) {
    final current = queue.removeLast();
    for (final entity in current.listSync(followLinks: false)) {
      final name = p.basename(entity.path);
      if (name.startsWith('.') || _ignoredDirectoryNames.contains(name)) {
        continue;
      }
      if (entity is Directory) {
        queue.add(entity);
      } else if (entity is File && name.endsWith('.md')) {
        final content = entity.readAsStringSync();
        if (extractSentinelNamespaces(content).isNotEmpty ||
            (includeLiveSpans && extractLiveSpanValues(content).isNotEmpty)) {
          discovered.add(p.normalize(entity.path));
        }
      }
    }
  }
  discovered.sort();
  return discovered;
}

/// Formats a compact unified-style diff of the first differing span between
/// [expected] and [actual].
String _buildLineDiff(List<String> expected, List<String> actual) {
  var prefix = 0;
  final minLen = expected.length < actual.length
      ? expected.length
      : actual.length;
  while (prefix < minLen && expected[prefix] == actual[prefix]) {
    prefix++;
  }

  var expectedSuffix = expected.length;
  var actualSuffix = actual.length;
  while (expectedSuffix > prefix &&
      actualSuffix > prefix &&
      expected[expectedSuffix - 1] == actual[actualSuffix - 1]) {
    expectedSuffix--;
    actualSuffix--;
  }

  final buffer = StringBuffer('@@ line ${prefix + 1} @@\n');
  const maxLinesShown = 20;

  final removedCount = expectedSuffix - prefix;
  for (var i = 0; i < removedCount && i < maxLinesShown; i++) {
    buffer.writeln('- ${expected[prefix + i]}');
  }
  if (removedCount > maxLinesShown) {
    buffer.writeln('... (${removedCount - maxLinesShown} more removed lines)');
  }

  final addedCount = actualSuffix - prefix;
  for (var i = 0; i < addedCount && i < maxLinesShown; i++) {
    buffer.writeln('+ ${actual[prefix + i]}');
  }
  if (addedCount > maxLinesShown) {
    buffer.writeln('... (${addedCount - maxLinesShown} more added lines)');
  }

  return buffer.toString().trimRight();
}

typedef _VerifyConfig = ({
  String rootDir,
  Set<String> namespaces,
  TableGuardMode guardMode,
  Map<String, SentinelRowBuilder> rowBuilders,
  Map<String, Map<String, String Function(Map<String, dynamic> row)>>
  cellFormatters,
  Map<String, List<List<String>>> customTableRows,
  Map<String, Object> inlineValues,
  Set<String> continuousIndexCollections,
});

({String? failureMessage, Set<String> jsonFiles}) _checkMarkdownFile(
  String mdPath,
  _VerifyConfig config,
) {
  final display = _displayPath(config.rootDir, mdPath);
  final file = File(mdPath);
  if (!file.existsSync()) {
    return (
      failureMessage: 'Markdown file "$display" does not exist at "$mdPath".',
      jsonFiles: const {},
    );
  }
  final existing = file.readAsStringSync();
  if (extractSentinelNamespaces(existing).isEmpty &&
      (config.inlineValues.isEmpty ||
          extractLiveSpanValues(existing).isEmpty)) {
    return (
      failureMessage:
          'Markdown file "$display" contains no sentinel blocks '
          '(<!-- ns:id:start ... -->).',
      jsonFiles: const {},
    );
  }

  final (:projected, :errors) = projectMarkdownFileFromDisk(
    mdPath,
    namespaces: config.namespaces,
    guardMode: config.guardMode,
    rowBuilders: config.rowBuilders,
    cellFormatters: config.cellFormatters,
    customTableRows: config.customTableRows,
    inlineValues: config.inlineValues,
    continuousIndexCollections: config.continuousIndexCollections,
  );
  if (errors.isNotEmpty) {
    return (failureMessage: errors.join('\n'), jsonFiles: const {});
  }

  final jsonFiles = <String>{
    for (final src in extractSentinelJsonSources(existing))
      p.normalize(
        p.join(file.parent.path, parseSentinelSourceSpec(src).filePath),
      ),
  };

  final normExisting = normalizeMarkdownTableFormatting(existing);
  final normProjected = normalizeMarkdownTableFormatting(projected);
  if (normExisting == normProjected) {
    return (failureMessage: null, jsonFiles: jsonFiles);
  }

  final diff = _buildLineDiff(
    LineSplitter.split(normExisting).toList(),
    LineSplitter.split(normProjected).toList(),
  );
  return (
    failureMessage:
        '"$display" is out of sync with its JSON sources:\n\n'
        '$diff\n\n'
        'To update, run:\n'
        '  dart run md_live sync $display',
    jsonFiles: jsonFiles,
  );
}

String? _checkCompactJsonFile(String jsonPath, String rootDir) {
  final display = _displayPath(rootDir, jsonPath);
  final file = File(jsonPath);
  if (!file.existsSync()) return null;
  final existing = file.readAsStringSync();
  final Object? decoded;
  try {
    decoded = jsonDecode(existing);
  } on FormatException catch (e) {
    return 'Invalid JSON in "$display": ${e.message}';
  }
  final formatted = '${formatCompactJson(decoded)}\n';
  if (existing.replaceAll('\r\n', '\n') == formatted) return null;
  return '"$display" is not formatted with formatCompactJson.\n'
      'To format, run:\n'
      '  dart run md_live compact-json $display';
}

/// Verifies that Markdown files containing `md-live` sentinel blocks match
/// their JSON sources on disk.
///
/// When [markdownFiles] is omitted, recursively discovers all `.md` files under
/// [directoryPath] (defaults to [Directory.current]) that declare at least one
/// `<!-- <ns>:<id>:start ... -->` sentinel block.
///
/// Throws an [MdLiveVerificationException] if no sentinel Markdown files are
/// found, if any sentinel source fails schema validation, or if any Markdown
/// table (modulo Prettier column-width padding) or `<span data-live>` span is
/// out of sync with its JSON data.
///
/// Because all parameters are optional and named, [expectMdLiveClean] can be
/// passed directly as a tear-off to `test()`:
/// ```dart
/// import 'package:md_live/md_live.dart';
/// import 'package:test/scaffolding.dart';
///
/// void main() {
///   test('md_live', expectMdLiveClean);
/// }
/// ```
Future<void> expectMdLiveClean({
  String? directoryPath,
  List<String>? markdownFiles,
  Set<String> namespaces = const {},
  TableGuardMode guardMode = TableGuardMode.none,
  Map<String, SentinelRowBuilder> rowBuilders = const {},
  Map<String, Map<String, String Function(Map<String, dynamic> row)>>
      cellFormatters =
      const {},
  Map<String, List<List<String>>> customTableRows = const {},
  Map<String, Object> inlineValues = const {},
  Set<String> continuousIndexCollections = const {},
  bool checkCompactJson = false,
}) async {
  final rootDir = p.normalize(
    p.absolute(directoryPath ?? Directory.current.path),
  );
  final targetPaths = markdownFiles != null
      ? [
          for (final raw in markdownFiles)
            p.isAbsolute(raw)
                ? p.normalize(raw)
                : p.normalize(p.join(rootDir, raw)),
        ]
      : _discoverSentinelMarkdownFiles(
          rootDir,
          includeLiveSpans: inlineValues.isNotEmpty,
        );

  if (targetPaths.isEmpty) {
    throw MdLiveVerificationException(
      message:
          'No Markdown files with sentinel blocks (<!-- ns:id:start ... -->) '
          'found under "$rootDir".',
      failedFiles: const [],
    );
  }

  final config = (
    rootDir: rootDir,
    namespaces: namespaces,
    guardMode: guardMode,
    rowBuilders: rowBuilders,
    cellFormatters: cellFormatters,
    customTableRows: customTableRows,
    inlineValues: inlineValues,
    continuousIndexCollections: continuousIndexCollections,
  );
  final failedFiles = <String>[];
  final messages = <String>[];
  final referencedJsonFiles = <String>{};

  for (final mdPath in targetPaths) {
    final (:failureMessage, :jsonFiles) = _checkMarkdownFile(mdPath, config);
    referencedJsonFiles.addAll(jsonFiles);
    if (failureMessage != null) {
      failedFiles.add(_displayPath(rootDir, mdPath));
      messages.add(failureMessage);
    }
  }

  if (checkCompactJson) {
    final sortedJson = referencedJsonFiles.toList()..sort();
    for (final jsonPath in sortedJson) {
      final err = _checkCompactJsonFile(jsonPath, rootDir);
      if (err != null) {
        failedFiles.add(_displayPath(rootDir, jsonPath));
        messages.add(err);
      }
    }
  }

  if (messages.isNotEmpty) {
    throw MdLiveVerificationException(
      message: messages.join('\n\n'),
      failedFiles: failedFiles,
    );
  }
}
