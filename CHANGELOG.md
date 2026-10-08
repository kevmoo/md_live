## 0.1.0-wip

- Initial version: sentinel-backed GFM pipe table projection, `<span data-live>`
  inline scalar projection, declarative `field_types` validation, and
  `formatCompactJson`.
- Add `expectMdLiveClean` (`MdLiveVerificationException`) for zero-arg
  `package:test` drift verification (`test('md_live', expectMdLiveClean);`) and
  `normalizeMarkdownTableFormatting` so Prettier (`mdf`)-padded pipe tables
  compare equal to `md_live` projections.
- Add `renderSentinelTableBlock`, `renderLiveSpan`, `formatCommaNum`, and
  `formatSpeedupRatio` (plus negative-integer handling in `formatCommaInt`).
- **Breaking:** Move `field_types` and `table_columns` under a reserved root
  `"@md_live"` envelope (`mdLiveEnvelopeKey`, `mdLiveEnvelope`). Legacy
  root-level directives and unknown envelope keys are reported by
  `validateKnownFields`.
- Add `field_values` string allowlists, `countByStatus`, and
  `KnownStatus.countInFlight`.
- Add `parseSentinelBlocks`, `sentinelBlockPattern`, and
  `extractSentinelMarkerAttr` so sentinel attributes parse in any order.
- **Breaking:** Remove `rowBuilders` / `SentinelRowBuilder` (use
  `cellFormatters` keyed by collection, with `cols="..."` for per-sentinel
  columns), `filterSentinelRecords`, and `extractSentinelBlockBody`.
- **Breaking:** `parseSentinelSourceSpec` throws `ArgumentError` instead of
  `FormatException`.
- Fix inline `<span data-live>` projection being skipped for Markdown files
  without sentinel tables; `expectMdLiveClean` now discovers span-only files,
  verifies projection idempotency, and fails when `inlineValues` are provided
  but no live spans are found.
- Fix `formatCommaInt` emitting a double minus sign for the minimum 64-bit `int`
  on native targets.
