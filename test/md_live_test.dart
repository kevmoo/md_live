import 'dart:convert';
import 'dart:io';

import 'package:md_live/md_live.dart';
import 'package:process/process.dart';
import 'package:test/test.dart';
import 'package:test_descriptor/test_descriptor.dart' as d;

class _FakeProcessManager implements ProcessManager {
  _FakeProcessManager(this._handler);

  final ProcessResult Function(List<Object> command) _handler;

  @override
  ProcessResult runSync(
    List<Object> command, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    Encoding? stdoutEncoding = systemEncoding,
    Encoding? stderrEncoding = systemEncoding,
  }) => _handler(command);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('formatCompactJson', () {
    test('collapses primitive leaf maps at indent >= 2', () {
      final data = {
        'items': [
          {'id': 'H01', 'score': 42, 'active': true},
        ],
      };
      expect(
        formatCompactJson(data),
        '{\n'
        '  "items": [\n'
        '    {"id": "H01", "score": 42, "active": true}\n'
        '  ]\n'
        '}',
      );
    });

    test('supports collapsePrimitiveLists and maxInlineMapLength', () {
      final data = {
        'tags': ['alpha', 'beta'],
        'items': [
          {'id': 'very_long_identifier_value', 'status': 'MERGED'},
        ],
      };
      expect(
        formatCompactJson(
          data,
          collapsePrimitiveLists: true,
          maxInlineMapLength: 20,
        ),
        '{\n'
        '  "tags": ["alpha", "beta"],\n'
        '  "items": [\n'
        '    {\n'
        '      "id": "very_long_identifier_value",\n'
        '      "status": "MERGED"\n'
        '    }\n'
        '  ]\n'
        '}',
      );
    });
  });

  group('sentinel_sources', () {
    test(
      'extractSentinelJsonSources and extractSentinelNamespaces ignore code',
      () {
        const md = '''
```markdown
<!-- fake:one:start src="ignored.json#items" -->
```
Inline `<!-- fake:two:start src="ignored2.json" -->` here.
<!-- live:table:start src="data.json#rows?status=OPEN" -->
<!-- other:summary:start src="summary.json#stats" -->
''';
        expect(extractSentinelJsonSources(md), {
          'data.json#rows?status=OPEN',
          'summary.json#stats',
        });
        expect(extractSentinelNamespaces(md), {'live', 'other'});
      },
    );

    test('parseSentinelSourceSpec rejects traversal and schemes', () {
      expect(parseSentinelSourceSpec('data/items.json#rows'), (
        filePath: 'data/items.json',
        selector: 'rows',
      ));
      expect(
        () => parseSentinelSourceSpec('../secret.json'),
        throwsFormatException,
      );
      expect(
        () => parseSentinelSourceSpec('https://example.com/a.json'),
        throwsFormatException,
      );
      expect(
        () => parseSentinelSourceSpec('/abs/a.json'),
        throwsFormatException,
      );
    });

    test(
      'resolveSentinelJsonSlice and filterSentinelRecords filter slices',
      () async {
        final json = {
          'groups': [
            {
              'items': [
                {'id': 'A', 'status': 'OPEN', 'tier': '1'},
                {'id': 'B', 'status': 'CLOSED', 'tier': '1'},
                {'id': 'C', 'status': 'MERGED', 'tier': '2'},
              ],
            },
          ],
        };
        final slice = resolveSentinelJsonSlice(
          json,
          'groups/items?status=OPEN,MERGED&tier!=2',
        );
        expect(slice, [
          {'id': 'A', 'status': 'OPEN', 'tier': '1'},
        ]);

        final bundled = await bundleSentinelJsonSources(
          '<!-- ns:id:start src="items.json#groups/items?status=CLOSED" -->',
          (path) => path == 'items.json' ? jsonEncode(json) : null,
        );
        expect(bundled['items.json#groups/items?status=CLOSED'], [
          {'id': 'B', 'status': 'CLOSED', 'tier': '1'},
        ]);
      },
    );
  });

  group('known_fields', () {
    test('tryParseTrackerLink validates canonical GitHub PR/Issue URLs', () {
      expect(tryParseTrackerLink('https://github.com/kevmoo/md_live/pull/12'), (
        githubRepo: 'kevmoo/md_live',
        kind: 'pull',
        number: 12,
      ));
      expect(
        tryParseTrackerLink('https://github.com/kevmoo/md_live/issues/5'),
        (githubRepo: 'kevmoo/md_live', kind: 'issues', number: 5),
      );
      expect(
        tryParseTrackerLink('https://github.com/kevmoo/md_live/pull/0'),
        isNull,
      );
      expect(
        tryParseTrackerLink('https://github.com/kevmoo/md_live/pull/12?foo=1'),
        isNull,
      );
    });

    test('KnownFieldType validates and formats values', () {
      expect(KnownFieldType.status.validateValue('MERGED'), isNull);
      expect(KnownFieldType.status.validateValue('BOGUS'), contains('invalid'));
      expect(KnownFieldType.status.formatMarkdown('MERGED'), '☑️ **MERGED**');
      expect(
        tryMatchKnownStatusRank('☑️ **MERGED**'),
        KnownStatus.merged.lifecycleRank,
      );

      expect(
        KnownFieldType.trackerLink.formatMarkdown([
          'https://github.com/kevmoo/md_live/pull/1',
          'https://github.com/kevmoo/md_live/pull/2',
          'https://github.com/dart-lang/sdk/issues/99',
        ]),
        '[kevmoo/md_live#1](https://github.com/kevmoo/md_live/pull/1), '
        '[#2](https://github.com/kevmoo/md_live/pull/2), '
        '[dart-lang/sdk#99](https://github.com/dart-lang/sdk/issues/99)',
      );

      expect(KnownFieldType.slotId.formatMarkdown('H01'), '**H01**');
      expect(
        KnownFieldType.codeSpan.formatMarkdown(['foo', 'bar']),
        '`foo`, `bar`',
      );
    });

    test(
      'validateKnownFields and validateSentinelSources catch schema errors',
      () {
        final badJson = {
          'field_types': {'status': 'status', 'pr': 'tracker_link'},
          'table_columns': {
            'items': ['#index', 'status', 'missing_col'],
          },
          'items': [
            {'status': 'UNKNOWN_STATE', 'pr': '[bad](https://github.com)'},
          ],
        };
        final errs = validateKnownFields(badJson);
        expect(
          errs,
          contains(predicate<String>((s) => s.contains('missing_col'))),
        );
        expect(
          errs,
          contains(predicate<String>((s) => s.contains('UNKNOWN_STATE'))),
        );
        expect(
          errs,
          contains(predicate<String>((s) => s.contains('raw URL without'))),
        );
      },
    );
  });

  group('md_live_core & TableGuardMode', () {
    test('defaults to TableGuardMode.none (Prettier clean)', () {
      final table = renderGuardedMarkdownTable(
        headers: ['Slot', 'Score'],
        alignments: [':---', '---:'],
        rows: [
          ['**H01**', formatCommaInt(12500)],
        ],
      );
      expect(table, isNot(contains('mdformat')));
      expect(
        table,
        '| Slot | Score |\n'
        '| :--- | ---: |\n'
        '| **H01** | 12,500 |',
      );

      final guarded = renderGuardedMarkdownTable(
        headers: ['Slot'],
        alignments: [':---'],
        rows: [
          ['H01'],
        ],
        guardMode: TableGuardMode.mdformat,
      );
      expect(
        guarded,
        startsWith('<!-- mdformat off(prevent table wrapping) -->'),
      );
      expect(guarded, endsWith('<!-- mdformat on -->'));
    });

    test('projectSentinelMarkdown projects tables and inline live spans', () {
      final json = <String, dynamic>{
        'field_types': {
          'slot': 'slot_id',
          'status': 'status',
          'pr': 'tracker_link',
        },
        'table_columns': {
          'items': ['#index', 'slot', 'status', 'pr'],
        },
        'items': [
          {
            'slot': 'H01',
            'status': 'MERGED',
            'pr': 'https://github.com/kevmoo/md_live/pull/1',
          },
        ],
      };

      const markdown = '''
Count: <span data-live="total">0</span> (`<span data-live="ignored">x</span>`)

<!-- demo:items:start src="data.json#items" -->

| # | Slot | Status | PR |
| :- | :--- | :--- | :--- |
| stale | stale | stale | stale |

<!-- demo:items:end -->
''';

      final projected = projectSentinelMarkdown(
        markdown,
        namespace: 'demo',
        jsonByPath: {'data.json': json},
        inlineValues: {'total': 1},
      );

      expect(projected, isNot(contains('mdformat')));
      expect(projected, contains('Count: <span data-live="total">1</span>'));
      expect(
        projected,
        contains(
          '| **1** | **H01** | ☑️ **MERGED** | [kevmoo/md_live#1](https://github.com/kevmoo/md_live/pull/1) |',
        ),
      );
      expect(extractLiveSpanValues(projected), [(key: 'total', value: '1')]);
    });
  });

  group('io & syncRemoteGithubPrStatuses', () {
    test('syncRemoteGithubPrStatuses updates statuses via ProcessManager', () {
      final prs = <Map<String, dynamic>>[
        {
          'upstream_pr': 'https://github.com/kevmoo/md_live/pull/7',
          'status': 'IN_REVIEW',
        },
      ];
      final fakePm = _FakeProcessManager((cmd) {
        expect(cmd, containsAll(['gh', 'pr', 'view', '7']));
        return ProcessResult(0, 0, '{"state":"MERGED","isDraft":false}', '');
      });
      syncRemoteGithubPrStatuses(prs, processManager: fakePm);
      expect(prs.single['status'], 'MERGED');
    });

    test('syncOrVerifyGeneratedFiles detects drift and writes files', () async {
      await d.dir('gen', [d.file('out.md', 'stale\n')]).create();
      final dirPath = d.path('gen');
      final errBuf = StringBuffer();

      expect(
        syncOrVerifyGeneratedFiles(
          dirPath: dirPath,
          expectedFiles: {'out.md': 'fresh\n'},
          verifyOnly: true,
          err: errBuf,
        ),
        1,
      );
      expect(errBuf.toString(), contains('Drift detected in: out.md'));

      expect(
        syncOrVerifyGeneratedFiles(
          dirPath: dirPath,
          expectedFiles: {'out.md': 'fresh\n'},
          verifyOnly: false,
        ),
        0,
      );
      expect(
        syncOrVerifyGeneratedFiles(
          dirPath: dirPath,
          expectedFiles: {'out.md': 'fresh\n'},
          verifyOnly: true,
          out: StringBuffer(),
        ),
        0,
      );
    });
  });
}
