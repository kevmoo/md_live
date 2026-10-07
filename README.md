JSON-backed Markdown sentinel tables, inline live spans, declarative field
validation, and compact JSON formatting for Dart repositories and CI pipelines.

`md_live` lets structured `.json` data files drive GitHub Flavored Markdown
(GFM) pipe tables and inline prose spans without sacrificing clean diffs, static
type validation, or Prettier (`mdf`) compatibility.

## Features

- **Sentinel Table Projection (`<!-- ns:id:start src="..." -->`)**:
  - Splices JSON record collections directly into GFM pipe tables while
    preserving your existing Markdown table headers and column alignments.
  - Supports `#<selector>` paths and query filters
    (`src="data.json#items?status!=CLOSED"`).
  - Defaults to `TableGuardMode.none` so generated Markdown tables stay clean
    for Prettier and GitHub rendering.
- **Inline Live Spans (`<span data-live="key">...</span>`)**:
  - Updates computed metrics or version badges inline inside prose paragraphs
    while ignoring fenced code blocks and inline code spans.
- **Declarative Schema & Field Validation (`field_types` & `table_columns`)**:
  - Validates and formats `status` (`KnownStatus` lifecycle badges),
    `tracker_link` (canonical GitHub PR/Issue URLs), `slot_id`, and `code_span`
    fields directly from JSON metadata.
- **Compact JSON Formatting (`formatCompactJson`)**:
  - Formats structured JSON with 2-space indentation while collapsing primitive
    leaf objects onto single lines (`{"id": "H01", "status": "MERGED"}`) for
    compact, readable diffs.
- **Zero-Alias CLI (`md_live`)**:
  - `md_live verify <files.md>`: Verifies that Markdown sentinel tables match
    their JSON sources on disk.
  - `md_live sync <files.md>`: Projects and updates Markdown sentinel tables in
    place.
  - `md_live compact-json [--check] <files.json>`: Formats or checks JSON files
    using `formatCompactJson`.

## Sentinel Syntax

Declare a JSON-backed sentinel block in any Markdown file using HTML comments
around a GFM pipe table:

```markdown
<!-- bench:results:start src="benchmarks.json#runs?status=OPEN,MERGED" -->

| # | Slot | Status | PR |
| :- | :--- | :--- | :--- |
| **1** | **H01** | ☑️ **MERGED** | [kevmoo/md_live#1](https://github.com/kevmoo/md_live/pull/1) |

<!-- bench:results:end -->
```

Pair it with a structured JSON file (`benchmarks.json`):

```json
{
  "field_types": {
    "slot": "slot_id",
    "status": "status",
    "pr": "tracker_link"
  },
  "table_columns": {
    "runs": ["#index", "slot", "status", "pr"]
  },
  "runs": [
    {"slot": "H01", "status": "MERGED", "pr": "https://github.com/kevmoo/md_live/pull/1"}
  ]
}
```

## CLI Usage

Verify that Markdown files are in sync with their JSON sources (for CI checks):

```bash
dart run md_live verify README.md docs/REPORT.md
```

Update Markdown sentinel tables in place after editing JSON data:

```bash
dart run md_live sync README.md docs/REPORT.md
```

Format or check JSON data files with compact single-line leaf records:

```bash
dart run md_live compact-json benchmarks.json
dart run md_live compact-json --check benchmarks.json
```

## Library Usage

```dart
import 'package:md_live/md_live.dart';

void main() {
  final json = <String, dynamic>{
    'field_types': {'status': 'status'},
    'table_columns': {
      'items': ['name', 'status'],
    },
    'items': [
      {'name': 'Parser', 'status': 'MERGED'},
    ],
  };

  const template = '''
Total items: <span data-live="count">0</span>

<!-- demo:items:start src="items.json#items" -->

| Component | Status |
| :--- | :--- |

<!-- demo:items:end -->
''';

  final projected = projectSentinelMarkdown(
    template,
    namespace: 'demo',
    jsonByPath: {'items.json': json},
    inlineValues: {'count': 1},
  );
  print(projected);
}
```
