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
EDL export, docx export, AI Chat "Roles").

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
