import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;

import 'format_compact_json.dart';
import 'io.dart';
import 'md_live_core.dart';

String _resolvePath(String rawPath, String cwd) =>
    p.isAbsolute(rawPath) ? rawPath : p.normalize(p.join(cwd, rawPath));

typedef _CompactJsonOpts = ({
  bool checkOnly,
  bool collapseLists,
  int maxListLen,
  int? maxMapLen,
});

typedef _ProjectionContext = ({
  String cwd,
  Set<String> namespaces,
  TableGuardMode guardMode,
  bool verifyOnly,
  StringSink out,
  StringSink err,
});

abstract class _MdLiveCommand extends Command<int> {
  _MdLiveCommand(this._out, this._err, this._cwd);

  final StringSink _out;
  final StringSink _err;
  final String _cwd;

  @override
  void printUsage() => _out.writeln(usage);
}

class _CompactJsonCommand extends _MdLiveCommand {
  _CompactJsonCommand(super._out, super._err, super._cwd) {
    argParser
      ..addFlag(
        'check',
        negatable: false,
        help: 'Verify that JSON files are formatted without writing changes.',
      )
      ..addFlag(
        'collapse-lists',
        negatable: false,
        help: 'Collapse primitive JSON arrays onto a single line.',
      )
      ..addOption(
        'max-inline-list-length',
        defaultsTo: '100',
        help: 'Maximum character length for single-line primitive arrays.',
      )
      ..addOption(
        'max-inline-map-length',
        defaultsTo: '160',
        help:
            'Maximum character length for single-line primitive leaf objects '
            '(0 = unlimited).',
      );
  }

  @override
  String get name => 'compact-json';

  @override
  String get description =>
      'Format or verify JSON files using compact single-line leaf objects.';

  @override
  String get invocation => '${runner!.executableName} $name [options] <files>';

  @override
  int run() {
    final results = argResults!;
    if (results.rest.isEmpty) {
      _err
        ..writeln('Error: Specify at least one .json file.')
        ..writeln(usage);
      return 64;
    }
    final maxListLen = int.tryParse(
      results.option('max-inline-list-length') ?? '100',
    );
    final maxMapLenRaw = int.tryParse(
      results.option('max-inline-map-length') ?? '160',
    );
    if (maxListLen == null || maxListLen < 0 || maxMapLenRaw == null) {
      _err.writeln('Error: Invalid integer length option.');
      return 64;
    }
    final opts = (
      checkOnly: results.flag('check'),
      collapseLists: results.flag('collapse-lists'),
      maxListLen: maxListLen,
      maxMapLen: maxMapLenRaw <= 0 ? null : maxMapLenRaw,
    );

    var hasFailure = false;
    for (final rawPath in results.rest) {
      if (!_processSingleJsonFile(rawPath, opts)) hasFailure = true;
    }
    return hasFailure ? 1 : 0;
  }

  bool _processSingleJsonFile(String rawPath, _CompactJsonOpts opts) {
    final file = File(_resolvePath(rawPath, _cwd));
    if (!file.existsSync()) {
      _err.writeln('File not found: $rawPath');
      return false;
    }
    final existing = file.readAsStringSync();
    final Object? decoded;
    try {
      decoded = jsonDecode(existing);
    } on FormatException catch (e) {
      _err.writeln('Invalid JSON in $rawPath: ${e.message}');
      return false;
    }
    final body = formatCompactJson(
      decoded,
      collapsePrimitiveLists: opts.collapseLists,
      maxInlineListLength: opts.maxListLen,
      maxInlineMapLength: opts.maxMapLen,
    );
    final formatted = '$body\n';
    if (existing.replaceAll('\r\n', '\n') == formatted) {
      return true;
    }
    if (opts.checkOnly) {
      _err.writeln('Needs formatting: $rawPath');
      return false;
    }
    file.writeAsStringSync(formatted);
    _out.writeln('Formatted $rawPath');
    return true;
  }
}

void _addProjectionOptions(ArgParser parser) {
  parser
    ..addMultiOption(
      'namespace',
      abbr: 'n',
      help:
          'Sentinel namespace(s) to project (defaults to all declared '
          'namespaces in each file).',
    )
    ..addOption(
      'guard-mode',
      allowed: ['none', 'mdformat'],
      defaultsTo: 'none',
      help: 'Whether to wrap tables in <!-- mdformat off --> guard comments.',
    );
}

class _VerifyCommand extends _MdLiveCommand {
  _VerifyCommand(super._out, super._err, super._cwd) {
    _addProjectionOptions(argParser);
  }

  @override
  String get name => 'verify';

  @override
  String get description =>
      'Verify that Markdown sentinel tables match their JSON sources on disk.';

  @override
  String get invocation => '${runner!.executableName} $name [options] <files>';

  @override
  int run() => _runMarkdownProjection(
    argResults!,
    verifyOnly: true,
    out: _out,
    err: _err,
    cwd: _cwd,
    usage: usage,
  );
}

class _SyncCommand extends _MdLiveCommand {
  _SyncCommand(super._out, super._err, super._cwd) {
    _addProjectionOptions(argParser);
  }

  @override
  String get name => 'sync';

  @override
  String get description =>
      'Project and update Markdown sentinel tables in place from JSON sources.';

  @override
  String get invocation => '${runner!.executableName} $name [options] <files>';

  @override
  int run() => _runMarkdownProjection(
    argResults!,
    verifyOnly: false,
    out: _out,
    err: _err,
    cwd: _cwd,
    usage: usage,
  );
}

int _runMarkdownProjection(
  ArgResults results, {
  required bool verifyOnly,
  required StringSink out,
  required StringSink err,
  required String cwd,
  required String usage,
}) {
  if (results.rest.isEmpty) {
    err
      ..writeln('Error: Specify at least one .md file.')
      ..writeln(usage);
    return 64;
  }
  final guardMode = results.option('guard-mode') == 'mdformat'
      ? TableGuardMode.mdformat
      : TableGuardMode.none;
  final ctx = (
    cwd: cwd,
    namespaces: results.multiOption('namespace').toSet(),
    guardMode: guardMode,
    verifyOnly: verifyOnly,
    out: out,
    err: err,
  );
  var hasFailure = false;

  for (final rawPath in results.rest) {
    if (!_projectOneFile(rawPath, ctx)) hasFailure = true;
  }
  if (!hasFailure && verifyOnly) {
    out.writeln('Verification PASSED.');
  }
  return hasFailure ? 1 : 0;
}

bool _projectOneFile(String rawPath, _ProjectionContext ctx) {
  final resolvedPath = _resolvePath(rawPath, ctx.cwd);
  final mdFile = File(resolvedPath);
  if (!mdFile.existsSync()) {
    ctx.err.writeln('File not found: $rawPath');
    return false;
  }
  final existing = mdFile.readAsStringSync();
  final (:projected, :errors) = projectMarkdownFileFromDisk(
    resolvedPath,
    namespaces: ctx.namespaces,
    guardMode: ctx.guardMode,
  );
  if (errors.isNotEmpty) {
    for (final error in errors) {
      ctx.err.writeln(error);
    }
    return false;
  }
  final inSync =
      normalizeMarkdownTableFormatting(existing) ==
      normalizeMarkdownTableFormatting(projected);
  if (ctx.verifyOnly) {
    if (!inSync) {
      ctx.err.writeln('Drift detected in: $rawPath');
      return false;
    }
    return true;
  }
  if (!inSync) {
    mdFile.writeAsStringSync(projected);
    ctx.out.writeln('Updated $rawPath');
  } else {
    ctx.out.writeln('Up to date: $rawPath');
  }
  return true;
}

/// Runs the `md_live` command-line interface with [args] and returns a POSIX
/// exit code (`0` on success, `1` on validation/drift failure, `64` on usage
/// error).
Future<int> runMdLiveCli(
  List<String> args, {
  StringSink? stdoutSink,
  StringSink? stderrSink,
  String? workingDirectory,
}) async {
  final out = stdoutSink ?? stdout;
  final err = stderrSink ?? stderr;
  final cwd = workingDirectory ?? Directory.current.path;

  final runner =
      CommandRunner<int>(
          'md_live',
          'JSON-backed Markdown sentinel tables, inline live spans, and '
              'compact JSON formatting.',
        )
        ..addCommand(_CompactJsonCommand(out, err, cwd))
        ..addCommand(_VerifyCommand(out, err, cwd))
        ..addCommand(_SyncCommand(out, err, cwd));

  try {
    final parsed = runner.parse(args);
    if (parsed.flag('help') && parsed.command == null) {
      out.writeln(runner.usage);
      return 0;
    }
    final code = await runner.runCommand(parsed);
    if (code == null) {
      out.writeln(runner.usage);
      return 0;
    }
    return code;
  } on UsageException catch (e) {
    err
      ..writeln(e.message)
      ..writeln()
      ..writeln(e.usage);
    return 64;
  }
}
