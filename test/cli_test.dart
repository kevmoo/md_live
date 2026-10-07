import 'dart:io';

import 'package:md_live/md_live.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:test_descriptor/test_descriptor.dart' as d;

void main() {
  group('runMdLiveCli', () {
    test('compact-json formats and verifies JSON files', () async {
      await d.dir('proj', [
        d.file(
          'data.json',
          '{\n'
              '  "items": [\n'
              '    {\n'
              '      "id": "H01",\n'
              '      "ok": true\n'
              '    }\n'
              '  ]\n'
              '}\n',
        ),
      ]).create();
      final cwd = d.path('proj');
      final out = StringBuffer();
      final err = StringBuffer();

      expect(
        await runMdLiveCli(
          ['compact-json', '--check', 'data.json'],
          stdoutSink: out,
          stderrSink: err,
          workingDirectory: cwd,
        ),
        1,
      );
      expect(err.toString(), contains('Needs formatting: data.json'));

      err.clear();
      expect(
        await runMdLiveCli(
          ['compact-json', 'data.json'],
          stdoutSink: out,
          stderrSink: err,
          workingDirectory: cwd,
        ),
        0,
      );
      expect(
        File(p.join(cwd, 'data.json')).readAsStringSync(),
        '{\n  "items": [\n    {"id": "H01", "ok": true}\n  ]\n}\n',
      );

      expect(
        await runMdLiveCli(
          ['compact-json', '--check', 'data.json'],
          stdoutSink: out,
          stderrSink: err,
          workingDirectory: cwd,
        ),
        0,
      );
    });

    test('verify and sync project sentinel tables on disk', () async {
      await d.dir('doc_proj', [
        d.file(
          'items.json',
          '{\n'
              '  "field_types": {"status": "status"},\n'
              '  "table_columns": {"rows": ["name", "status"]},\n'
              '  "rows": [\n'
              '    {"name": "Core", "status": "MERGED"}\n'
              '  ]\n'
              '}\n',
        ),
        d.file(
          'REPORT.md',
          '<!-- demo:rows:start src="items.json#rows" -->\n\n'
              '| Component | Status |\n'
              '| :--- | :--- |\n'
              '| stale | stale |\n\n'
              '<!-- demo:rows:end -->\n',
        ),
      ]).create();
      final cwd = d.path('doc_proj');
      final out = StringBuffer();
      final err = StringBuffer();

      expect(
        await runMdLiveCli(
          ['verify', 'REPORT.md'],
          stdoutSink: out,
          stderrSink: err,
          workingDirectory: cwd,
        ),
        1,
      );
      expect(err.toString(), contains('Drift detected in: REPORT.md'));

      err.clear();
      expect(
        await runMdLiveCli(
          ['sync', 'REPORT.md'],
          stdoutSink: out,
          stderrSink: err,
          workingDirectory: cwd,
        ),
        0,
      );
      expect(out.toString(), contains('Updated REPORT.md'));

      final synced = File(p.join(cwd, 'REPORT.md')).readAsStringSync();
      expect(synced, contains('| Core | ☑️ **MERGED** |'));
      expect(synced, isNot(contains('mdformat')));

      out.clear();
      expect(
        await runMdLiveCli(
          ['verify', 'REPORT.md'],
          stdoutSink: out,
          stderrSink: err,
          workingDirectory: cwd,
        ),
        0,
      );
      expect(out.toString(), contains('Verification PASSED.'));
    });

    test('returns 64 on missing arguments or unknown command', () async {
      final out = StringBuffer();
      final err = StringBuffer();

      expect(
        await runMdLiveCli(['verify'], stdoutSink: out, stderrSink: err),
        64,
      );
      expect(
        await runMdLiveCli(['unknown-cmd'], stdoutSink: out, stderrSink: err),
        64,
      );
      expect(
        await runMdLiveCli(['--help'], stdoutSink: out, stderrSink: err),
        0,
      );
    });
  });
}
