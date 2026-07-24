# Third-party Skill sources

Files under `Skills/` are curated, unmodified copies of markdown skill definitions from two
MIT-licensed repos (spec.md §8, "AI Chat Roles"). Both licenses are reproduced below per MIT's
attribution requirement.

- `Skills/autopunk/**/*.md` — all 394 `SKILL.md` files from
  [ur-grue/autopunk-media-skills](https://github.com/ur-grue/autopunk-media-skills), copyright
  (c) 2026 ur-grue, mirrored under the source repo's own `category/subcategory/` folder
  structure (21 categories, as the app's role picker displays them — see `Role.titleCase`
  in `Sources/Audium/Role.swift` for the slug-to-title mapping: Archive Legal, Audience
  Distribution, Data Journalism, Editing, Image Prompting, Magazine Journalism, Media Business,
  Newsletter, PR Communications, Podcast, Pre-Production, Production Support, Radio Audio,
  Research, Screenwriting, Social Media, TV Documentary, Translation, Translation Localization,
  Writing, YouTube — the repo's `locales` category exists but is currently empty upstream, so it
  doesn't appear here).
  Only the `SKILL.md` content is bundled per file (renamed to `<skill-slug>.md`, dropping the
  per-skill folder and its `.evals.json` sibling) — the app's role picker doesn't need eval
  fixtures. Originally a hand-curated 14-file subset (TV Documentary, Editing, Production
  Support, Screenwriting); expanded to the full set per user decision (2026-07-23) once the
  picker UI could handle grouping/search at that scale (see spec.md §8).
- `Skills/filmcraft.md` — `skills/filmcraft/SKILL.md` from
  [OmkarPalika/filmcraft](https://github.com/OmkarPalika/filmcraft), copyright (c) 2026 Omkar
  Palika. Only the main standing-rules file is bundled; its `references/` and `directors/`
  subfolders are dynamically-loaded reference material out of scope for a static role (see
  spec.md §8).

## MIT License (both sources)

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
