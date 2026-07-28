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
Global speaker rename (editing one segment's speaker label renames every segment sharing that
label, matching how diarization groups them) is implemented and real-GUI-tested (2026-07-28). The
AI Chat Roles library was re-culled against the strictly-filmmaking/podcast/journalism criterion
(2026-07-28): 402 → 302 skill files (100 removed, ~25%) — see standing practice below for what the
prior "0 removed" pass missed. Dailies now **always link to source media, never copy**
(`Daily.linkedSourcePath: String?`, nil only means a pre-change Daily that's still a real copy —
not migrated, left as-is) — this app isn't sandboxed (no entitlements file, confirmed via
`build.sh`'s ad-hoc/local-dev codesign), so a plain absolute path is used instead of a
security-scoped bookmark. Caught and fixed a real bug during this session's GUI test:
`ContentView.handleDrop`'s Finder-drag path used `loadFileRepresentation`, which Apple docs say
vends a temporary copy invalid after the completion handler returns — under the old copy model
that was harmless, under the new link model it linked straight to a `/var/folders/.../T/...`
scratch file instead of the user's real file; fixed via `loadInPlaceFileRepresentation`. Also new:
one global cache/render location for derived files (extracted audio, YouTube downloads,
whisper.cpp format conversions) — `CacheSettings` (UserDefaults-backed, defaults to
`~/Library/Caches/com.postproduction.Audium/`), overridable in Settings, same conceptual model as
Avid's Media Cache. Full real-GUI-tested detail (link-not-copy disk verification, moved-file
graceful-failure test, custom-cache-location derived-file verification, relaunch persistence) in
spec.md §8's "Media linking (not copying) + global cache location" subsection. The single-loaded-
Daily model and the separate Paper Edit window are both gone as of 2026-07-28: a tab-based
interface now lets multiple Dailies stay open as tabs (only the active tab's content loads into
the one shared `AudioPlaybackController` — playback stayed shared, per the revised decision, not
per-tab), and Story Editor (the former Paper Edit window's content) is one of those tabs, opened
on demand via the same toolbar button rather than pinned. All 4 spec-mandated test stages passed
against the signed app; see spec.md §8's "Tab-based interface + Story Editor tab" subsection.
Word-level timestamps + arbitrary text-selection highlighting + inline "Add to Paper Edit" are
implemented (2026-07-28): all three real transcription providers (WhisperKit/whisper.cpp/OpenAI)
now populate optional per-word timing on `TranscriptSegment.words`; Gemini still can't (no internal
timestamp structure), so its transcripts fall back to segment-level selection granularity, by
design. The transcript now renders as one shared `NSTextView` (`TranscriptFlowView.swift`, new
file) instead of a SwiftUI `Text`-per-segment list — the same "drop to AppKit when SwiftUI can't do
it" move as `PlayerView`/`AVPlayerView` — so a drag can select an arbitrary, cross-segment phrase; a
floating "Add Highlight"/"Add to Paper Edit" pill appears over the selection (right-click as
secondary fallback). `Highlight.start`/`.end` needed no schema change to become sub-segment-precise
— it was already a generic `TimeInterval` pair. Real GUI testing on Zeus caught two real bugs before
either reached this stage's completion: `SpeakerDiarizer.labelSpeakers` (shared by all three
providers) was silently dropping every segment's `words` field when rebuilding segments post-
diarization, and whisper.cpp's own `[_BEG_]`-style internal tokens were leaking into the word list
as fake "words" — both fixed and re-verified live (word data confirmed persisted correctly on disk
after the fix, `[_BEG_]` confirmed gone from a fresh re-transcribe). A follow-up doubt-driven-
development adversarial review (fresh subagent, no prior context) then caught 4 more real bugs
(a backwards selection-boundary fallback direction, a rare flag re-arm that could silently eat one
real click-to-seek, choppy per-word highlight-background painting, an overly broad special-token
filter) — all fixed; one OpenAI word/segment boundary-pairing edge case was accepted as a documented
trade-off rather than fixed. Full detail, including one known-but-unresolved edge case (a selection
starting inside a segment's timestamp/speaker prefix didn't show the floating bar in one re-check —
not conclusively distinguished from a testing-methodology artifact this session also uncovered:
the Waveform panel's "Re-transcribe" link and the Transcript panel's floating "Add Highlight"
button happen to sit at nearly the same x-coordinate in different panels, which caused several
false "the button doesn't work" readings during this session's own `cliclick`/AXPress testing), in
spec.md §8's new subsection.

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

**Correction (2026-07-28): the "0 removed" conclusion above was itself too shallow, per direct user
feedback — it checked every file for *any* media-adjacent keyword rather than judging each one
against the actual stated criterion (strictly filmmaking/podcast/journalism).** Re-run properly:
8 categories cut wholesale (newsletter, PR/communications, social media, image prompting, both
translation categories, audience/distribution, YouTube — 83 files, all genuinely promotional/
localization-business functions, not craft), 8 kept wholesale (clearly in scope), and the rest
(research/writing/media-business/editing, plus `production-support` — a 5th category the user's own
breakdown omitted entirely, flagged rather than silently guessed at) read file-by-file against the
real criterion, not pattern-matched by name. Net: 402 → 302 (100 removed, ~25%) — a real cut this
time. The lesson isn't "always find something to cut" (research/media-business/editing genuinely
came back 100% kept on close reading, including subdirectories — `locations-logistics`, `media-
competitive` — the user's own directive guessed would need trimming) — it's that **the bar is
reading each file against the stated criterion, not a keyword sweep for relatedness**; both a false
"nothing to cut" and a manufactured cut are failures of the same underlying shortcut. See spec.md's
"Roles library re-culled against the actual criterion" subsection for the full per-category
breakdown and reasoning.

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

**Standing practice (as of 2026-07-28): a `Delete "X" and everything in it?` confirmation dialog
(and by extension any similarly-styled destructive-confirm dialog) is easy to trigger *by
accident* via positional button-index guessing in a row that has more than one icon-only control**
— during real-GUI-testing the speaker-rename feature, a positional guess intended to select a
Daily row instead landed on that Daily's parent folder's delete-confirmation trigger, and the
follow-up `click button "Cancel" of window "Audium"` (named lookup — the known -1728 issue) failed
silently while the dialog was apparently still auto-advancing, and the folder + its seeded test
media were actually deleted. No real harm (session-scratchpad test data), but it cost a full
re-seed. **Before clicking anything in a row with multiple unlabeled icon buttons, check the
`help` attribute** (`help of <button>` via System Events — distinct from `name`/`description`,
which are usually `missing value` for SwiftUI's icon-only buttons) — it frequently carries the
real accessibility label (e.g. `"Remove highlight"`, likely also `"Delete Folder"`-style text on
destructive icons) where blind positional guessing risks a destructive action. Also confirmed this
session, correcting an older permanent note below: plain keyboard **Escape does reliably dismiss**
`NSOpenPanel`/`NSSavePanel` and (per this incident) still leaves a `.confirmationDialog` visually
open rather than confirming it — but a *stale* AppleScript reference obtained before a dialog
appeared (e.g. `window "Audium"` captured pre-dialog) can silently fail once the dialog changes
the window's element tree; re-fetch the reference fresh after the dialog appears, same "re-derive
after any layout change" lesson as the AXCell/List note above, now confirmed for confirmation
dialogs specifically, not just static layout. Separately: entering any row's inline edit mode
(e.g. this app's transcript speaker/text editing) inserts new `Done`/`Cancel` buttons into that
row, shifting every subsequent button's index in the same scroll area — always re-fetch button
indices after toggling an edit mode rather than reusing indices captured before it. And: plain
`keystroke`/`key code` System Events commands target whatever the OS considers frontmost at the
keyboard-input level, which can silently diverge from the app most recently `click`-ed via
AXPress — in this session, keystrokes meant for a just-focused Audium `TextField` landed in a
completely different application's text input instead, with no error from `osascript`. Setting
`value of <text field>` directly plus `perform action "AXConfirm" of <text field>` avoided that
whole class of misdirected-keystroke risk and is the safer default for scripted text entry in
future sessions.

**Standing practice (as of 2026-07-28): atomic commits — split by concern, don't bundle everything
since the last commit into one.** If a session touches unrelated features (a bug fix + a new
feature, or two independent features), commit them separately even when they land in the same
session — one commit per concern, not one commit per session. **Two concrete violations, don't do
this again**: `e2254cc` bundled the global-speaker-rename bug fix together with the unrelated Roles
library re-cull (402→302 skill files) in one commit; `c4e1e39` bundled a small "Clear-clip" button
addition together with the much larger, unrelated tab-based-interface architecture change in one
commit. Both are real, separable units of work that got flattened into a single commit message
covering two different stories — harder to review, harder to revert one without the other, harder
to `git log`/`git blame` later. Going forward: before committing, check whether the staged diff
actually represents one concern; if it's two, stage and commit them separately even if both were
written in the same sitting.

**Standing practice (as of 2026-07-28): adversarial review before marking a non-trivial feature
done, in addition to (not instead of) real-GUI-testing/source-verification.** For features
involving subtle invariants — shared state across components, timing/concurrency, format-
conversion math, multi-step architectural decisions — run a fresh-context adversarial review (the
`doubt-driven-development` skill: CLAIM → EXTRACT → DOUBT → RECONCILE) before considering the work
done. This is a different failure mode than the "verify against a real source" lessons already
above (whisper.cpp's actual release assets, ScriptFixer's actual source, Calibri's actual font
files, Parakeet's actual benchmarks) — those catch a *fact* the implementing context got wrong;
adversarial review catches a *reasoning/design* flaw that survives fact-checking precisely because
the same context that made the decision is also the one checking it, so it re-confirms its own
blind spots rather than finding them. Does **not** replace real-GUI-testing (spec §8's testing
discipline) or the interchange-format/live-research practices above — it's an added pass, run
*before* those or alongside them, specifically for the class of bug that a passing GUI test and a
correct fact-check both miss: the underlying design decision itself being subtly wrong. Simple UI
additions (a button, a label, a layout tweak) don't need this — reserve it for the invariant-heavy
category described above.
