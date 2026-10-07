import 'dart:convert';
import 'dart:io' hide Process, ProcessException, ProcessResult, ProcessSignal;

import 'package:path/path.dart' as p;
import 'package:process/process.dart';

import 'known_fields.dart';
import 'md_live_core.dart';
import 'sentinel_sources.dart';

String? _readCachedFile(String fullPath, Map<String, String?> cache) {
  if (cache.containsKey(fullPath)) return cache[fullPath];
  final file = File(fullPath);
  final content = file.existsSync() ? file.readAsStringSync() : null;
  cache[fullPath] = content;
  return content;
}

List<String> _validateExpectedMarkdownSources(
  String dirPath,
  Map<String, String> expectedFiles,
) {
  final fileCache = <String, String?>{};
  final errors = <String>[];
  for (final entry in expectedFiles.entries) {
    if (!entry.key.endsWith('.md')) continue;
    errors.addAll(
      validateSentinelSources(
        entry.value,
        (relJsonPath) =>
            expectedFiles[relJsonPath] ??
            _readCachedFile(p.join(dirPath, relJsonPath), fileCache),
        markdownName: entry.key,
      ),
    );
  }
  return errors;
}

/// Compares or writes each relative file path in [expectedFiles] under
/// [dirPath], and validates that any sentinel `src="..."` markers in `.md`
/// files resolve to non-empty JSON record slices.
///
/// Returns `0` on success, or `1` when validation fails or file drift is
/// detected in [verifyOnly] mode.
int syncOrVerifyGeneratedFiles({
  required String dirPath,
  required Map<String, String> expectedFiles,
  required bool verifyOnly,
  StringSink? out,
  StringSink? err,
}) {
  final outSink = out ?? stdout;
  final errSink = err ?? stderr;
  final srcErrors = _validateExpectedMarkdownSources(dirPath, expectedFiles);
  if (srcErrors.isNotEmpty) {
    for (final error in srcErrors) {
      errSink.writeln('Sentinel source error: $error');
    }
    return 1;
  }

  if (verifyOnly) {
    final drift = <String>[
      for (final entry in expectedFiles.entries)
        if (!File(p.join(dirPath, entry.key)).existsSync() ||
            (entry.key.endsWith('.md')
                ? normalizeMarkdownTableFormatting(
                        File(p.join(dirPath, entry.key)).readAsStringSync(),
                      ) !=
                      normalizeMarkdownTableFormatting(entry.value)
                : File(
                        p.join(dirPath, entry.key),
                      ).readAsStringSync().replaceAll('\r\n', '\n') !=
                      entry.value.replaceAll('\r\n', '\n')))
          entry.key,
    ];
    if (drift.isNotEmpty) {
      errSink.writeln('Drift detected in: ${drift.join(', ')}');
      return 1;
    }
    outSink.writeln('Verification PASSED (JSON and sentinel blocks in sync).');
    return 0;
  }

  for (final entry in expectedFiles.entries) {
    File(p.join(dirPath, entry.key)).writeAsStringSync(entry.value);
  }
  return 0;
}

/// Projects all sentinel blocks in [markdownPath] from their relative JSON
/// `src="..."` files on disk.
///
/// When [namespaces] is empty, all `<!-- <ns>:<id>:start ... -->` namespaces
/// declared in [markdownPath] are projected in declaration order.
({String projected, List<String> errors}) projectMarkdownFileFromDisk(
  String markdownPath, {
  Set<String> namespaces = const {},
  TableGuardMode guardMode = TableGuardMode.none,
  Map<String, SentinelRowBuilder> rowBuilders = const {},
  Map<String, Map<String, String Function(Map<String, dynamic> row)>>
      cellFormatters =
      const {},
  Map<String, List<List<String>>> customTableRows = const {},
  Map<String, Object> inlineValues = const {},
  Set<String> continuousIndexCollections = const {},
}) {
  final mdFile = File(markdownPath);
  if (!mdFile.existsSync()) {
    return (projected: '', errors: ['Markdown file not found: $markdownPath']);
  }
  final markdown = mdFile.readAsStringSync();
  final baseDir = mdFile.parent.path;
  final rawCache = <String, String?>{};
  final errors = validateSentinelSources(
    markdown,
    (relPath) => _readCachedFile(p.join(baseDir, relPath), rawCache),
    markdownName: p.basename(markdownPath),
  );
  if (errors.isNotEmpty) return (projected: markdown, errors: errors);

  final jsonByPath = <String, Map<String, dynamic>>{};
  for (final src in extractSentinelJsonSources(markdown)) {
    final spec = parseSentinelSourceSpec(src);
    if (jsonByPath.containsKey(spec.filePath)) continue;
    final raw = _readCachedFile(p.join(baseDir, spec.filePath), rawCache);
    if (raw != null) {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        jsonByPath[spec.filePath] = Map<String, dynamic>.from(decoded);
      }
    }
  }

  final activeNamespaces = namespaces.isNotEmpty
      ? namespaces
      : extractSentinelNamespaces(markdown);
  var current = markdown;
  try {
    if (activeNamespaces.isEmpty && inlineValues.isNotEmpty) {
      current = projectInlineLiveSpans(current, inlineValues);
    } else {
      for (final ns in activeNamespaces) {
        current = projectSentinelMarkdown(
          current,
          namespace: ns,
          jsonByPath: jsonByPath,
          rowBuilders: rowBuilders,
          cellFormatters: cellFormatters,
          customTableRows: customTableRows,
          inlineValues: inlineValues,
          continuousIndexCollections: continuousIndexCollections,
          guardMode: guardMode,
        );
      }
    }
  } on Object catch (e) {
    return (projected: markdown, errors: ['${p.basename(markdownPath)}: $e']);
  }
  return (projected: current, errors: const []);
}

({bool isGithubPr, KnownStatus? status}) _querySingleGithubPrStatus(
  String link,
  ProcessManager processManager,
  StringSink errSink,
) {
  if (tryParseTrackerLink(link) case (
    githubRepo: final repo,
    kind: 'pull',
    :final number,
  )) {
    final res = processManager.runSync([
      'gh',
      'pr',
      'view',
      '$number',
      '--repo',
      repo,
      '--json',
      'state,isDraft',
    ]);
    if (res.exitCode != 0) {
      errSink.writeln(
        'Warning: gh pr view failed for $repo#$number (exit ${res.exitCode})',
      );
      return (isGithubPr: true, status: null);
    }
    final decoded = jsonDecode(res.stdout as String) as Map<String, dynamic>;
    return (
      isGithubPr: true,
      status: KnownStatus.fromGithubState(
        decoded['state'] as String,
        isDraft: decoded['isDraft'] as bool? ?? false,
      ),
    );
  }
  return (isGithubPr: false, status: null);
}

KnownStatus _aggregateKnownStatuses(List<KnownStatus> statuses) {
  if (statuses.contains(KnownStatus.inReview)) return KnownStatus.inReview;
  if (statuses.contains(KnownStatus.draft)) return KnownStatus.draft;
  if (statuses.contains(KnownStatus.merged)) return KnownStatus.merged;
  return statuses.first;
}

String? _resolveRecordPrStatus(
  Object? rawLink,
  ProcessManager processManager,
  StringSink errSink,
) {
  final links = switch (rawLink) {
    final String s => [s],
    final List<Object?> l => l.whereType<String>().toList(),
    _ => const <String>[],
  };
  final statuses = <KnownStatus>[];
  for (final link in links) {
    final res = _querySingleGithubPrStatus(link, processManager, errSink);
    if (res.isGithubPr && res.status == null) return null;
    if (res.status case final status?) statuses.add(status);
  }
  if (statuses.isEmpty) return null;
  return _aggregateKnownStatuses(statuses).jsonKey;
}

/// Queries `gh pr view --json state,isDraft` for each record in [prs] whose
/// [linkKey] is a GitHub PR URL or list of PR URLs, updating `pr[statusKey]` to
/// the canonical [KnownStatus.jsonKey] (`"MERGED"`, `"IN_REVIEW"`, `"DRAFT"`,
/// `"CLOSED_UNMERGED"`).
void syncRemoteGithubPrStatuses(
  List<Map<String, dynamic>> prs, {
  String linkKey = 'upstream_pr',
  String statusKey = 'status',
  ProcessManager processManager = const LocalProcessManager(),
  StringSink? err,
}) {
  final errSink = err ?? stderr;
  for (final pr in prs) {
    final updated = _resolveRecordPrStatus(
      pr[linkKey],
      processManager,
      errSink,
    );
    if (updated != null) {
      pr[statusKey] = updated;
    }
  }
}
