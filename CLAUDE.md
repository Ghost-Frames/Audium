# Audium

Native macOS transcription app (WhisperKit/whisper.cpp/Gemini/OpenAI transcription +
multi-provider AI chat), built zero-dependency/no-Xcode like the other Ghost-Frames tools.
whisper.cpp (bundled static binary, `Resources/bin/whisper-cli`, CPU-only) is the local
transcription option on Intel Macs — WhisperKit's CoreML pipeline is unsupported there (spec §5,
Known Issues); Zeus specifically is Intel, so this matters for testing on this machine.

v1 (transcription core) is feature-complete and pre-release-cleaned. v2 is underway: pivoting
toward a project-based story-editing tool — screen dailies, transcribe, mark highlights, and
assemble a paper edit without opening Avid/Premiere/Resolve. See `docs/spec.md` Section 8 for
the full v2 architecture (Project/Daily/Highlight/Paper Edit data model, video playback, CMX3600
EDL export, ScriptFixer/ScriptSync export, `.docx` export, batch/folder transcription, AI Chat
"Roles"). All original v2 export requirements are now complete (TXT/SRT/VTT/ScriptSync/`.docx`
transcript export, EDL/`.docx` Paper Edit export). NVIDIA Parakeet was considered as a second local
ASR engine and rejected (2026-07-27, real research — see spec.md §9) — no Intel path, contested/
implementation-dependent Apple Silicon speed claims, narrower language support than Whisper.

Always read `docs/spec.md` first, before investigating or changing anything. Check its
"Known Issues" and "Resolved" sections (Section 5) before re-diagnosing something that may
already be documented there — several past issues (Keychain ACL bugs, WhisperKit model-lookup
errors, provider-default wiring) look like new bugs on first encounter but are already root-caused
there.

**Standing practice (as of 2026-07-23): Claude Code owns updates to `docs/spec.md` and this
file directly** after every task — not just reporting changes back for the user to relay
through Claude.ai. Update both yourself, same level of detail as the existing entries, before
considering a task done.

**Standing practice (as of 2026-07-26): every v2 feature gets a real GUI smoke test** against
the signed `build/Audium.app` (not just a clean `swift build`/type-check) before being marked
complete — code-level correctness isn't sufficient, per this project's testing discipline
throughout Section 8. UI automation is AXPress via System Events, walking `uiElements()` by
positional index path (not named title lookups, which fail unreliably — `-1728`); re-derive the
path fresh after any layout change rather than reusing indices from a previous session's dump —
this app's AX tree does not flatten in simple visual/declaration order (verify by position, not
memory). Inside a `List`, each row is wrapped in an `AXCell` on macOS — a row's real controls sit
one level *deeper* than a plain `VStack`/`HStack` row would (`row → AXCell → button`); getting
that depth wrong doesn't error, it silently clicks the inert cell instead of the control (see spec
§8's Paper Edit section for a concrete case this actually caused). NSSavePanel/NSOpenPanel
confirmation, Finder-drag release, and `List` drag-to-reorder are all categorically not
synthetically automatable (see spec §5/§8's permanent notes) and need a human at the mouse for
that one step, with automated verification (AX state reads, `log show` against `AudiumLog`'s
categories, on-disk file/JSON inspection) resuming immediately after. Don't report a feature done
on code review alone.

**Standing practice (as of 2026-07-26): implementing a real external file/interchange format
(EDL, and by extension anything similar later — AAF, XML interchange, etc.) requires live research
against real sources first, cited in the spec.md write-up** — not implementation from
training-data recollection alone, even when confident. The CMX3600 EDL exporter's format details
were cross-checked against multiple independent live sources (a maintained reference OSS EDL
writer, published format guides, a canonical drop-frame algorithm writeup) before any code was
written; a synthetic-data command-line test harness (compile+run the exporter's file(s) standalone
with hand-verifiable inputs, outside the app) caught a real math bug before it ever reached a real
GUI test. Where genuine confidence is only "structurally correct, not confirmed against the real
target application," say so explicitly rather than implying more certainty than earned — this
project ships to a real Avid workflow, and quiet overconfidence there is worse than an honest gap.

**Standing practice (as of 2026-07-27): bundling a third-party CLI tool that has no official
prebuilt macOS binary requires checking the actual GitHub Releases API (or equivalent), not the
web page** — `whisper.cpp`'s releases page failed to render its own asset list over `WebFetch`,
but `curl .../releases/latest` (GitHub's REST API) gave the real, complete asset manifest
immediately, confirming no macOS CLI binary existed and building from source was actually
necessary, not just assumed. When building from source for bundling, verify the result is
actually self-contained (`otool -L`, expect only system frameworks — `libSystem`, `Accelerate`,
`libc++`, etc.) before treating it as equivalent to `ffmpeg`/`yt-dlp`'s bundled static binaries.
**Also noted this session**: `log show --predicate 'subsystem == "com.postproduction.Audium"'`
returned zero lines for an entire real transcription run (whisper.cpp on Zeus/Intel) despite the
unconditional `AudiumLog` calls that should have fired — `log show --predicate 'process ==
"Audium"'` for the same window returned 1000+ system-subsystem lines, so unified logging itself
was working, just not this app's own subsystem. Not root-caused. If `log show` verification for
`AudiumLog`'s own subsystem/categories comes up empty again, don't assume the feature under test
silently failed — cross-check via screenshot/on-disk evidence before concluding anything, same as
this session did.

**Standing practice reinforced (2026-07-27), concrete case**: the ScriptFixer/ScriptSync export
(spec.md §8/§9) is a second data point for the 2026-07-26 "check real sources for interchange
formats" practice above — this project's *own* spec.md §9 roadmap had recorded a remembered
ScriptFixer export convention (18-char dialogue indent, 52-char line width, `NAME:`/`NAME OS:` cue
format) that turned out wrong on every specific once actually checked against
`github.com/Ghost-Frames/ScriptFixer`'s real, current source (real values: 0-char/flush-left
indent, 45-char width, bare uppercase cue with no colon or suffix). A previously-written spec.md
entry is not itself a verified source — it can encode the same kind of unverified recollection this
practice exists to catch, and should be re-checked against the real thing rather than trusted just
because it's already written down. Also notable: ScriptFixer's own `README.md` documents a
`SPEAKER (O.S.)` off-camera-tag feature that isn't actually implemented in its checked-in
`InterviewParser.swift` (verified by grepping the source, not just reading the doc) — a second
reminder that a tool's README describes intent, not necessarily its shipped behavior, and both need
checking independently when they might disagree.

**Standing practice (as of 2026-07-27): a scope-narrowing request ("audit and filter, don't assume
X already qualifies") still requires real evidence for the "nothing to remove" outcome, not just a
skim.** Asked to narrow AI Chat Roles to strictly media-related content, the honest result of
actually auditing all 394 bundled `autopunk-media-skills` files (category listing, a keyword sweep
across every file's full text, and a manual full-read of the ~15 most generic-*sounding* individual
skill filenames) was that nothing needed removing — the source package was already media-scoped
throughout, down to skills with deceptively generic filenames (`internal-memo-writer`,
`welcome-email-writer`) turning out to explicitly frame themselves around journalist/press/newsroom/
editorial use in their own body text once actually read in full, not just their filename. Reported
that "already compliant" finding plainly, backed by the audit evidence, rather than manufacturing a
removal to have something to show for the pass — see spec.md's "Roles scope narrowed to strictly
media-related" subsection for the full method and the 8 genuine journalism/editorial additions
pulled from upstream instead (394 → 402 files, 0 removed).

**Standing practice (as of 2026-07-27): a binary-format writer that produces structurally valid
output (passes its own integrity check, gets identified correctly by `file`) can still be wrong in
a way only the real target application would show — verify with the real application, not just the
format checker.** The `.docx` writer (`DocxExporter.swift`) produced a file that was byte-valid
OOXML/ZIP (`unzip -t` clean, `file` said "Microsoft Word 2007+") but every bold run silently
rendered as regular weight — not an XML bug at all, but this specific machine's `Calibri` font
install being incomplete (only Regular + Bold-Italic combined face, no plain Bold/Italic files), so
the renderer had no matching font file to apply the trait with. Caught via `textutil` (macOS's own
docx reader) *and* confirmed by actually opening the file in real Microsoft Word and real Apple
Pages — both installed on this dev machine, both used as genuine independent checks, not just one.
Fixed by switching to `Helvetica`, a core Apple font guaranteed complete on every Mac. The lesson:
"the file is structurally valid" and "the file renders correctly in the software people will
actually open it with" are different claims, and a full-weight, real-application test is what this
project's own testing standard already calls for — this session is a concrete case of that standard
catching a real bug a structural check alone would have missed entirely.

**Standing practice (as of 2026-07-27): a competitor/technology-choice claim carried in this spec
from an earlier pass ("~20x faster") deserves the same live-research skepticism as any other
unverified claim, not a pass just because it's already written down.** NVIDIA Parakeet was on the
v2 roadmap (§9) as a second local ASR engine on the strength of a secondhand "~20x faster than
Whisper" claim. Real research reversed it: no mature Intel-Mac path exists (Parakeet's speed
depends on Apple Silicon's Neural Engine, same limitation this app already works around for
WhisperKit via `whisper.cpp` — but no equivalent bundleable CPU implementation exists for Parakeet
yet); the speed claim itself is contested and implementation-dependent (one detailed real-world
benchmark found it 2.6x *slower* via MLX with heavy memory pressure, while a dedicated CoreML port
claims 10-23x faster on the same hardware class); and its multilingual variant covers 25 languages
against Whisper's 99+. Removed from the roadmap (not silently deleted — left in spec.md with the
full reversal and citations, same treatment as the ScriptFixer memory-correction entry) rather than
built. This is the same "spec.md is not itself a verified source" lesson as the ScriptFixer entry
above, applied to a technology/architecture decision instead of a file-format convention.

**Standing practice (as of 2026-07-27): `System Events` AX automation that works for one kind of
confirmation dialog in this app doesn't necessarily work for another, even a structurally similar
one** — `NSSavePanel`'s Save button and custom SwiftUI `.alert`/`.confirmationDialog` sheets have
both been driven successfully via `click item N of UI elements of <sheet>` earlier in this
project's testing history, but the exact same pattern against `ProjectBrowserPanel`'s "Delete
Daily" confirmation dialog silently didn't take effect in this session (the dailies remained after
what looked like a successful click, with no error from `osascript`) — root cause not investigated,
since it was just batch-test cleanup, not the feature under test. Worked around by editing
`.audiumproject.json` directly (removing the stray entries) plus deleting the orphaned media files
by hand rather than fighting the automation further. If a future session hits the same "click
reported success but nothing changed" pattern on a confirmation dialog, verify the actual
before/after state (don't trust a clean `osascript` exit code alone) and be ready to fall back to
direct data manipulation for cleanup — same spirit as the existing NSSavePanel/List-drag-reorder
permanent notes, one more concrete case that AX automation reliability in this app is per-control,
not global.
