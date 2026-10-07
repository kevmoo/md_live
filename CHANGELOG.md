## 0.1.0-wip

- Initial version: sentinel-backed GFM pipe table projection, `<span data-live>`
  inline scalar projection, declarative `field_types` validation, and
  `formatCompactJson`.
- Add `expectMdLiveClean` (`MdLiveVerificationException`) for zero-arg
  `package:test` drift verification (`test('md_live', expectMdLiveClean);`) and
  `normalizeMarkdownTableFormatting` so Prettier (`mdf`)-padded pipe tables
  compare equal to `md_live` projections.
