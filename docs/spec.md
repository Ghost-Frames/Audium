# Audium (placeholder name) — Product & Architecture Spec

## 1. Vision

A native macOS transcription app, built to the same standard as MXFixer/QCheck/ScriptFixer:
zero-dependency, drag-and-drop, `swiftc`-compiled, no Xcode/Docker/Python runtime required
by the end user. Functionally targets feature-parity with **MacWhisper Pro's file-transcription
half** (not its live-dictation half), plus multi-provider AI (Claude/Gemini/ChatGPT) instead of
a single OpenAI-shaped integration.

**Platform requirement: both Intel and Apple Silicon Macs, not Apple Silicon only.** This is a
real product requirement, not just a dev-convenience nice-to-have — target users include Assistant
Editors on a mix of hardware. WhisperKit/CoreML is ANE-accelerated on Apple Silicon and falls back
to CPU+GPU on Intel per Argmax's own docs; any crash or correctness issue that only manifests on
Intel is a bug to fix, not a platform to drop support for.

This is a clean break from the Scriberr-forked "Audium" project — that codebase (Go + Svelte5 +
Docker + Postgres) is abandoned. Nothing is carried over except the name (placeholder) and the
feature ideas gathered from evaluating Scriberr/StoryToolkitAI.

## 2. v1 Feature Scope

**In scope:**
- Drag-and-drop transcription — single file or batch/folder
- Local transcription via WhisperKit (Whisper models via CoreML/Metal, Swift-native)
- Model size selection (matching MacWhisper: Tiny/Base/Small/Medium/Large-v3/Turbo)
  - **Implemented, with a correction**: WhisperKit's `recommendedModels()` returns a
    device-specific list, not a fixed enum — MacWhisper's named tiers don't map 1:1 (no
    "medium" variant exists in the current WhisperKit version; `distil-whisper_*` variants exist
    that MacWhisper's list doesn't have). Settings' picker is populated live from
    `recommendedModels()` per-device rather than hand-typed, so it always matches what's
    actually available. Override wiring confirmed to reach `WhisperKit`'s init correctly;
    full execution still blocked by the known Intel crash (unrelated to this feature).
- Speaker diarization — SpeakerKit (Argmax, pyannote CoreML), same package as WhisperKit,
  no Python/PyTorch runtime bundled
- Export: TXT, SRT, VTT, JSON
- YouTube URL transcription (download audio, transcribe locally)
- Multi-provider AI integration for transcript actions (cleanup, summarize, chat-with-transcript):
  - Anthropic Claude (Messages API)
  - Google Gemini (Generative AI API)
  - OpenAI ChatGPT (Chat Completions API)
  - User selects provider + model per action; API keys stored in Keychain
- Custom prompt templates for AI cleanup/summarization (like MacWhisper's prompt system)
- Transcript editing (inline correction, timestamp-synced playback)
  - **Implemented and confirmed**: click-to-edit text and speaker label per segment, real 
    `Button`-based (not gesture-only, for accessibility), commit/cancel via Enter/Escape. 
    Timestamps stay fixed — text-only editing for v1, word-level resync deferred (see Resolved 
    Decisions). Edits confirmed to propagate to AI chat context (verified: Summarize reply 
    described the edited text, not original). Export propagation confirmed via direct 
    Exporter.render call against real edited in-memory segments.
- **Real audio waveform visualization + playback** — the waveform panel has been a placeholder
  shell since the initial scaffold (Section 4's bento layout described it, but only the
  drag-drop/YouTube-URL input ever got built into that space — no actual waveform rendering or
  playback controls exist yet). Needed: real waveform display (amplitude visualization of the
  loaded audio), play/pause/scrub controls, and **clickable transcript sync** — clicking a
  transcript segment seeks playback to that timestamp, and the currently-playing segment
  highlights in the transcript panel as playback progresses. This was implied by the original
  MacWhisper/Wavery reference mockups from early planning but never actually scoped as its own
  task — now explicit.
- **Transcription progress indication** — **Implemented and confirmed.** Determinate progress
  bar + percent where a provider reports one (e.g. "Identifying speakers: 85%"), elapsed-time
  counter otherwise so cloud API calls still read as "alive." Phase labels throughout
  ("Transcribing via Gemini…" → "Identifying speakers…"). Wired through the logging system —
  confirmed via real drag-and-drop test showing both the live UI progress bar and matching
  timestamped phase-transition log entries. Root cause of an earlier false "not working" report:
  a stale binary predating the feature's code, not an actual bug.
- **In-app logging + log viewer** — **Implemented and confirmed.** `os.Logger`-based, one
  subsystem (`com.postproduction.Audium`), six categories (Transcription/Diarization/Export/
  AIChat/Keychain/YouTube). Instrumented at start/success/failure across all providers,
  diarization, export, AI chat, Keychain, and YouTube download. Log viewer via `OSLogStore`,
  GlassPanel-styled, error/notice/info color-coded within the existing palette (no new colors).
  Real end-to-end test confirmed meaningful entries for success and failure cases alike. Caught
  and fixed a real bug along the way: `Exporter`'s save path had a silent `try?` swallowing
  write errors.

**Explicitly out of scope for v1:**
- Live/real-time dictation, system-wide hotkey dictation
- System audio capture / meeting recording
- Watch-folder automation (candidate for v1.1)
- Any editorial export (EDL/XML/AVID DS) — deferred; revisit once core app is solid, informed
  by StoryToolkitAI's approach but not urgent for v1

## 3. Architecture

### Transcription
- One `TranscriptionProvider` protocol, e.g.
  `protocol TranscriptionProvider { func transcribe(audio: URL) async throws -> Transcript }`
- Three implementations, user-selectable per job or as a default in Settings:
  - `WhisperKitProvider` — local, on-device, free, private. Default. Package:
    `argmax-oss-swift` (formerly WhisperKit), product `WhisperKit`. CoreML/Metal-accelerated,
    replaces WhisperX/Python entirely.
  - `GeminiTranscriptionProvider` — cloud, via Gemini API's native multimodal audio input
    (Gemini accepts audio files directly as an input type). Uses user's Gemini API key.
  - `OpenAIWhisperAPIProvider` — cloud, via OpenAI's `/v1/audio/transcriptions` endpoint (or
    GPT-4o native audio input). Uses user's OpenAI API key.
  - **Claude is NOT a transcription provider** — the Anthropic Messages API has no audio input
    modality; Claude's consumer "voice mode" is a separate product feature, not an API
    capability. Claude stays in the `AIProvider` role only (cleanup/summarize/chat on
    already-transcribed text).
- Local WhisperKit model files downloaded on first use, not bundled in the `.app`/DMG (see
  Resolved Decisions).
- Cloud providers (Gemini/OpenAI transcription) are a deliberate tradeoff against the
  local-first/private-by-default principle — clearly labeled as such in the picker UI, not
  defaulted to.

### Diarization
- **SpeakerKit** (Argmax) — ships in the same `argmax-oss-swift` package as WhisperKit,
  pyannote-based CoreML diarization, MIT license, actively maintained by the Argmax team.
  Confirmed and wired in (see Section 5, Resolved Decisions).
- No Python, no PyTorch, no venv — consistent with the "no terminal/setup" principle.
- Imported as a separate module (`import SpeakerKit`) alongside `import WhisperKit`, not via
  the `ArgmaxOSS` umbrella import, to avoid pulling in the unrelated TTSKit module.

### Multi-provider AI (text actions: cleanup, summarize, chat-with-transcript)
- One Swift protocol, e.g. `AIProvider { func complete(messages:, model:) async throws -> String }`
- Two concrete implementations: `GeminiProvider`, `OpenAIProvider` — each calling its vendor's
  native API directly, no OpenAI-compatible shim. **Confirmed working end-to-end** — real
  chat panel, real transcript-context injection (system message), real summarization tested
  against both providers with sensible, accurate output.
- Anthropic/Claude removed from this role (decided during build) — protocol stays generic
  enough that a Claude conformance could be added back later if wanted, but it's not part of
  v1's provider set. (Claude was already excluded from transcription entirely — no audio input
  in the Messages API — so this removes it from the app altogether, not just one role.)
- Provider + model selection persisted per action type via `ChatSettings`/`AIProviderKind`,
  same `UserDefaults` pattern as `TranscriptionSettings`.
- API keys in Keychain, same pattern as your SSH key handling (currently via dev override
  pending the Keychain GUI bug fix).
- Gemini and OpenAI implementations are shared/reused conceptually between this protocol
  and `TranscriptionProvider` (same vendor, same API key) but are separate protocol conformances
  since transcription and text-completion are different operations.
- Chat UI: bento third panel, role-based message bubbles (cyan user / glass assistant),
  auto-scrolling list, bottom-pinned composer, Cleanup/Summarize quick actions that inject
  the current transcript as context. Loading and inline error states handled (no crash/silent
  failure on API error).

### YouTube URL input
- **yt-dlp** bundled as a static/standalone binary, same pattern as ffmpeg/ffprobe in QCheck —
  no Python runtime required (yt-dlp ships as a standalone compiled executable). Downloads
  audio-only from a submitted URL to a local temp file, which then feeds into the exact same
  `TranscriptionProvider` pipeline as drag-and-drop — no separate/duplicated transcription logic
  for this input path. **Confirmed working end-to-end** via real GUI, including a bundled static
  ffmpeg (required by yt-dlp's audio extraction) — verified with PATH stripped to rule out any
  dev-machine Homebrew leakage.
- **GUI provider selection fix**: `runTranscription(on:)` previously hardcoded WhisperKitProvider
  regardless of `TranscriptionSettings.defaultProvider` — meaning the real GUI (drag-and-drop and
  YouTube) never respected the user's provider choice, only direct test-hook calls did. Fixed and
  verified via real `cliclick`-driven Finder drag-and-drop with default set to Gemini — confirmed
  WhisperKit is never touched when a cloud provider is selected as default.

### Build & distribution
- `swiftc` direct compilation, `build.sh` → `.app` + `.dmg` with Applications symlink
- Ad-hoc code signing
- No Xcode project required
- Repo under `Ghost-Frames` org, working directory convention `/Users/zeus/Developer`

## 4. Design Language

Explicit rejection of default SwiftUI/AppKit look (stock `Form`/`List`, `Color(.controlBackgroundColor)`,
flat `.cornerRadius(8)` cards).

- **Layout**: Bento-style main window — asymmetrical grid combining waveform/player, transcript
  panel, and AI chat sidebar as distinct floating regions rather than one stacked column.
- **Materials**: Native glassmorphism via `.ultraThinMaterial`/`.regularMaterial`, custom
  gradient-stroke borders on hover/focus.
- **Color**: OLED-dark default (`#000000`/near-black), single accent color — electric cyan
  (`#22D3EE`), used sparingly for buttons, active states, glowing borders, waveform highlights.
  Not a full palette; cyan is the one focal color throughout.
- **Typography**: SF Pro with deliberate custom type scale and tracking, not default
  `.title`/`.body` styles applied uniformly.
- **Motion**: SwiftUI native spring animations — `scaleEffect` tap feedback (`0.95` on press),
  `matchedGeometryEffect` for panel transitions, animated glow on active/focus states.
- **Reference workflow**: before building any given screen, check Aceternity UI / Magic UI /
  21st.dev / Uiverse.io for a specific visual pattern to adapt (not copy — these are
  React/Tailwind, translated by hand into SwiftUI). Flagged explicitly per component, not
  assumed silently.

## 5. Open Decisions (to resolve during scaffolding, not before)

- Final app name (currently placeholder: Audium)

**Resolved:**
- Word-level timestamp resync: deferred, not in v1 — editing is text/speaker-only, segment
  start/end timestamps stay fixed to whatever transcription produced
- Model bundling: first-run download, not bundled in `.app`/DMG (matches MacWhisper; keeps
  distributable size reasonable)
- Accent color: electric cyan `#22D3EE` on OLED-dark background (confirmed from mockup review)
- Diarization: SpeakerKit (Argmax, `argmax-oss-swift` package), MIT license — confirmed and
  wired into `Package.swift`, clean build verified
- Transcription architecture: `TranscriptionProvider` protocol with WhisperKit (local, default),
  Gemini, and OpenAI implementations. Claude excluded — no audio input in the Messages API
- Default transcription provider: user-configurable in Settings, no hardcoded bias toward
  WhisperKit. All three (WhisperKit/Gemini/OpenAI) are equally selectable as default; app ships
  with WhisperKit pre-selected out of the box but user can change it freely

**Known issue (deferred, not blocking):**
- WhisperKit crashes with SIGSEGV on Intel Macs (no Neural Engine) — `TextDecoder.swift:139`,
  KV-cache tensor allocation via `.float16` IOSurface-backed initializer, happens before
  CoreML compute-unit dispatch so `ModelComputeOptions` can't route around it. Confirmed on
  Zeus (Intel iMac20,2), not yet confirmed working or broken on Apple Silicon (monkey-sign
  currently unreachable). Filed/to-file against `argmaxinc/argmax-oss-swift`. Fix plan once
  confirmed on Apple Silicon: runtime ANE detection, block WhisperKit selection on Intel with
  a clear message, or steer default to cloud transcription (Gemini/OpenAI) on unsupported
  hardware. Not blocking other work — proceeding with hardware-agnostic features in the
  meantime (SpeakerKit, cloud transcription providers, export, AI provider panel).
- **New, separate bug** (real GUI, 2026-07-22): WhisperKit transcription fails with
  `Multiple models found matching "*openai*/*" in Repo(id: "argmaxinc/whisperkit-coreml", ...)`
  — a model-repo lookup ambiguity, distinct from the SIGSEGV (fails earlier, before decode).
  **Fixed** — root cause: `WhisperModelSettings.selectedVariant`'s `UserDefaults.string(forKey:)`
  could return `Optional("")` (persisted empty string) rather than `nil`, silently skipping the
  `?? recommendedModels().default` fallback and feeding an empty variant into WhisperKit's own
  glob-disambiguation logic. Fixed: getter now treats `""` as unset.
  Also checked: real drag-and-drop was NOT ignoring `TranscriptionSettings.defaultProvider` —
  confirmed via logs the WhisperKit attempts happened while WhisperKit was genuinely the
  selected default at that moment. Not a regression.
- **AudiumSigning.keychain-db password loss — RESOLVED (2026-07-22).** Fixed permanently using
  the same derived-password principle already proven for `Audium.keychain-db`: recreated with
  a password derived via HKDF-SHA256 (`Scripts/derive-signing-password.swift`, same algorithm
  as `KeychainStore.swift`, distinct info-string so it's not the same value). `build.sh` now
  unlocks + `set-key-partition-list`s automatically every build — zero human interaction, zero
  plaintext password anywhere. Confirmed: clean build, zero dialogs,
  `codesign --verify --deep --strict` reports genuinely valid. Bonus fix: `sign_item()` was
  swallowing codesign failures via `|| true`, printing false-positive "Signed" messages even on
  failure — now aborts loudly on real failures.
- **Stale item ACL after cert regeneration — found and fixed during pre-release smoke test
  (2026-07-22).** Distinct from the earlier ad-hoc-signing/cdhash bug (already resolved) — this
  is the cert-based fix working exactly as designed, but the "Audium Local Dev" certificate's
  underlying keypair was regenerated at some point (same Common Name, different key), leaving
  previously-saved Keychain items' ACLs bound to a certificate leaf hash that no longer exists.
  Confirmed via `security dump-keychain -a` (keychain unlock itself is fine, purely an
  item-level ACL mismatch) and `CSSMERR_CSP_VERIFY_FAILED` status on the affected items. Not a
  code bug — `KeychainStore.save()` already creates correct ACLs against whatever cert is
  currently running. Fix: re-save existing keys once via Settings to rewrite their ACLs against
  the current cert. One-time fix, not expected to recur unless the cert itself is deliberately
  regenerated again (which nothing in the normal build/rebuild flow does).
- **Recurring login-keychain migration prompt — fixed.** `migrateFromLoginKeychainIfNeeded()`
  was checking the known-corrupted login keychain on every launch, popping a dialog each time
  since that migration can never succeed. Gated to one attempt ever via a persisted
  UserDefaults flag. Code-only change, needs a rebuild to take effect (deferred, not yet
  rebuilt/retested as of this note).
- **`CLAUDE.md` created at repo root** — Claude Code reads this automatically at the start of
  every session, pointing it at `docs/spec.md` and specifically its Known Issues/Resolved
  sections, so context doesn't need to be manually re-supplied every prompt.
- **User decision (2026-07-22): WhisperKit-on-Intel (the SIGSEGV crash above) is deferred to
  last**, after transcription progress indication and the waveform/playback/clickable-transcript
  feature, since it's blocked on external factors (upstream fix or Apple Silicon access) rather
  than something addressable through more local iteration right now.
- Keychain GUI dialog ("Allow"/password prompt) intermittently rejects the correct login
  password with no error, both in Keychain Access.app and the app's own prompt. **RESOLVED —
  confirmed working end-to-end 2026-07-22.** Root cause was four independent, compounding bugs,
  each real and each necessary to fix:
  1. Corrupted internal state in the user's migrated `login.keychain-db` (from an earlier
     backup/OS-reinstall/migration) — fixed by moving to a dedicated
     `~/Library/Keychains/Audium.keychain-db`.
  2. Ad-hoc code signing gave every rebuild a new cdhash, and the dedicated keychain's
     self-only `SecAccess` ACL was bound to that exact cdhash — fixed with a stable local
     self-signed "Audium Local Dev" code-signing certificate (`build.sh` now signs with this
     identity instead of pure ad-hoc `-`), anchoring the ACL to the certificate's hash instead
     of one specific binary.
  3. The derived-keychain-password salt lookup used `UserDefaults.standard`, whose domain
     differs between an unbundled dev binary and the real signed `.app` — fixed by pinning to
     an explicit named `UserDefaults(suiteName:)`.
  4. `kSecUseDataProtectionKeychain` wasn't explicitly set to `false`, so writes may have been
     silently routing through the unified Data Protection Keychain model rather than the
     legacy file-based `Audium.keychain-db` — added defensively to save/load/delete.
  Real end-to-end confirmation: Settings → Save Keys → real `SecItemAdd ... OSStatus 0` →
  real Gemini transcription succeeded using the Keychain-stored key (not the dev override) →
  real diarization succeeded → real transcript rendered in the actual GUI. Dev-only env
  overrides (`AUDIUM_GEMINI_KEY_OVERRIDE` etc.) can now be removed per the Pre-Release
  Cleanup Checklist (Section 7) — no longer needed for testing.

**Cloud transcription providers — confirmed working end-to-end (via dev override, pending
Keychain fix for the real UI path):**
- Gemini (`gemini-flash-latest`): confirmed correct transcript. Limitation — Gemini's API
  returns no internal timestamp structure, so the provider fakes a single span covering the
  whole clip. This means SpeakerKit diarization has only one span to work with when Gemini is
  the transcription source — it can't attribute mid-clip speaker changes, unlike WhisperKit or
  OpenAI which provide real segment boundaries. Acceptable limitation, not a bug, but worth
  surfacing in the UI (e.g. a note when Gemini is selected) since it silently degrades
  diarization quality.
- OpenAI (`whisper-1`, deliberately not GPT-4o-transcribe variants): confirmed correct
  transcript with real per-segment timestamps via `verbose_json`. GPT-4o-transcribe/mini-transcribe
  were evaluated and rejected — neither supports `verbose_json`/`timestamp_granularities`, which
  this provider's diarization merge depends on. Noted for later: `gpt-4o-transcribe-diarize`
  exists with its own native diarization (`diarized_json`), which would replace SpeakerKit
  entirely if ever adopted — out of scope for now, kept as a future option.

## 6. Dev Workflow

Same split as your other projects: this doc (Claude.ai) → scaffolding + implementation prompts
(Claude Code on Zeus) → focused execution, one component/feature at a time, explicit confirmation
before builds.

**Hardware note:** Zeus (Intel, no ANE) is the primary dev/build machine via Remote-SSH from
monkey-sign (Apple Silicon). Since Intel support is a real platform requirement (Section 1), any
functionality that's CoreML/ANE-path-sensitive should ideally be validated on both machines before
being considered done — Zeus catches Intel-only bugs, monkey-sign confirms the accelerated path
still works and performs as expected.

## 7. Pre-Release Cleanup Checklist

**COMPLETE (2026-07-23).** All dev-only scaffolding removed and the app smoke-tested clean
afterward, scaffolding-free, as a genuine pre-release check:

- `AudiumApp.swift` — all TEMP manual test hooks removed (`AUDIUM_TEST_GEMINI`,
  `AUDIUM_TEST_OPENAI`, `AUDIUM_TEST_EXPORT_DIR`, `AUDIUM_TEST_AI_PROVIDER`,
  `AUDIUM_TEST_CHAT_AUDIO`, `AUDIUM_TEST_YOUTUBE_URL`, `AUDIUM_TEST_EXPORT_EDITED`,
  `AUDIUM_TEST_WHISPER_MODELS`, `AUDIUM_TEST_KEYCHAIN`, `AUDIUM_TEST_SETTINGS_DUMP`,
  `AUDIUM_TEST_LOGGING_AUDIO`, `AUDIUM_TEST_WHISPER_VARIANT_OVERRIDE` — the last had no `TEMP`
  marker comment but was equally dev-only scaffolding, caught by inspection rather than grep).
  `init()` is back down to just the off-main-thread Keychain migration call.
- `ContentView.swift` — the two TEMP hooks added during the waveform/playback and
  WhisperKit-Intel feature work this session (`AUDIUM_TEST_WAVEFORM_SEED`,
  `AUDIUM_TEST_TRANSCRIBE_DEFAULT`) removed the same way, same reasoning.
- `KeychainStore.swift` — `loadForTesting(for:envOverride:)` removed entirely. All four call
  sites (`AIProvider.swift` ×2, `TranscriptionProvider.swift` ×2) restored to plain
  `KeychainStore.load(for:)` — real Keychain reads only, no env-var bypass anywhere.
- Grepped the full `Sources/` tree for `TEMP`, `AUDIUM_TEST_`, `loadForTesting`, and
  `_OVERRIDE` post-cleanup: zero matches.
- Rebuilt via `build.sh`: clean build, valid signature (`codesign --verify --deep --strict`
  exit 0), signed with the stable "Audium Local Dev" identity.
- **Real, scaffolding-free smoke test** against the signed `build/Audium.app` — no test hooks
  exist anymore to fall back on, so every step below is genuine GUI interaction:
  - Real drag-and-drop (Finder → Waveform panel) of a local audio file → real Gemini
    transcription completed using the real Keychain-stored key, correct transcript returned.
  - Export TXT/SRT/VTT — all three produced correct, well-formed real files.
  - AI chat Cleanup and Summarize — both returned real, sensible Gemini responses using the
    real Keychain-stored key.
  - Confirmed no dev-only path was exercised: process environment carries no `AUDIUM_TEST_*`/
    `_OVERRIDE` vars, and the source grep above is clean.
  - One real bug found and fixed along the way (not scaffolding — see Section 5, Known Issues,
    "stale Keychain-item ACL"): the `gemini`/`openai` Keychain items' access-control entries
    were bound to a since-regenerated "Audium Local Dev" certificate, causing a live
    `SecurityAgent` prompt on every read despite the keychain itself unlocking silently as
    designed. Root-caused via `security dump-keychain -a` (trust requirement's certificate leaf
    hash didn't match the currently-installed cert's leaf hash) and confirmed via
    `CSSMERR_CSP_VERIFY_FAILED`. Fixed by re-saving both keys through Settings, which rewrites
    the ACL against the current cert — no code change needed, `KeychainStore.save()` already
    does the right thing. Watched the re-save happen live via `log stream` on the Keychain
    category: `SecItemAdd ... OSStatus 0` for both providers, zero prompts.

## 8. v2 Architecture — Story Editor / Paper Edit Tool

**New vision (2026-07-22):** Audium v2 shifts from "load one file, transcribe it" to a
**project-based story-editing tool** — screen dailies, build transcripts, mark highlights, and
assemble a paper edit, all without opening Avid/Premiere/Resolve. The paper edit gets brought
into the real NLE afterward; this tool handles the screening/scripting phase before that.

### Data model — Project

- A **Project** is a folder on disk (not a database) — fits the AE mental model, same spirit as
  an Avid bin structure. Contains:
  - **Sub-folders** by scene/day/interview subject (user-organized, not a fixed taxonomy) —
    each sub-folder holds one or more **Dailies** (source media) and their associated
    **Transcripts**.
  - A project-level metadata file (JSON) tracking folder structure, daily↔transcript links,
    highlights, and paper-edit state.
- **Daily**: one source media file (video or audio) + its Transcript (segments, speakers,
  timestamps — reuses existing `Transcript`/`TranscriptSegment` types) + its **Highlights**.
- **Highlight**: a marked range within a transcript (one or more contiguous segments, or a
  sub-segment range if word-level precision is ever added) — carries an optional tag/color/note.
  Not a new copy of the text; a reference into the source transcript, so edits to the original
  segment propagate to anywhere it's highlighted.
- **Paper Edit**: an ordered sequence of Highlight references, potentially spanning multiple
  Dailies/transcripts within a project — the assembled "selects" reel in script form. Reordering
  is drag-and-drop; each entry still points back to its source Daily/timestamp for traceability
  when brought into the real NLE later.

### UI implications

- Needs a **project browser** (new UI region — likely a left sidebar, expanding the current
  bento layout from 3 panels to 4: project tree · media/video panel · transcript panel · AI
  chat) showing the folder/daily tree, current selection driving what's loaded in the other
  panels.
- Transcript panel gains **highlight marking** — select a range, tag it, see highlighted ranges
  visually distinguished (cyan accent, consistent with existing design language).
- A separate **Paper Edit view** (new panel, tab, or window) showing the assembled sequence,
  reorderable, each entry showing source + timestamp + text, playable in order.

### Project data model + browser UI — smoke test complete (2026-07-26)

Implementation lives in `Sources/Audium/Project.swift` (data model + `ProjectController`) and
`ContentView.swift` (`ProjectBrowserPanel` sidebar + waveform-panel integration). Real GUI smoke
test run against the signed `build/Audium.app` (not `swift build` alone), using
Accessibility-driven automation (AXPress via System Events, positional element paths — named
AppleScript title lookups like `button "X" of sheet 1` unreliably fail with `-1728`, use
positional indices instead) for everything except NSSavePanel/NSOpenPanel confirmation and
Finder-drag release, which are not synthetically automatable (see permanent note below) and were
done by a human. All items below were independently verified via on-disk file/JSON inspection
and/or `log show` against the app's own unified-logging output, not just visual UI state.

**Final on-disk project layout** (matches the doc comment at the top of `Project.swift`):
```
MyProject/
  .audiumproject.json       <- single metadata file: id, name, folders[] (each folder has
                                id, name, dailies[]); each daily has id, displayName,
                                mediaFilename, addedAt, transcript, highlights[]
  Scene 1 - INT Kitchen/    <- ProjectFolder, user-named, single level (no nesting)
    3F2504E0-....aiff       <- copied media, filename = "<dailyID>.<original extension>";
                                displayName in the JSON preserves the original filename
    9F86D081-....aiff
  Interview - Josh Pratt/
```
Media is always copied into the project folder (never referenced in place) — see the rationale
comment in `Project.swift` (self-contained/zippable project folder, no dangling refs, uniform
handling of YouTube-downloaded dailies).

**Smoke test results (all 7 original scope items), against a real signed rebuild:**
1. `build.sh` rebuild — clean, ad-hoc/cert signing succeeded.
2. New Project — folder + `.audiumproject.json` confirmed created on disk with correct shape
   (NSSavePanel itself isn't automatable — see below — so project creation for this test was
   seeded directly on disk matching the exact Codable JSON shape, then opened via the in-app
   Recent list, which **is** a plain automatable SwiftUI button; every mutation after that point
   — folders, dailies, deletes — went through the real running app, not manual JSON edits).
3. 3 sub-folders added ("Scene 1 - INT Kitchen", "Scene 2 - EXT Backyard", "Interview - Josh
   Pratt") via the real "+ New Folder" alert flow.
4. Real test dialogue clips (`scene1_take1.aiff`, `scene1_take2.aiff`, `interview_clip.aiff`,
   generated via `say -r 120 -o ...`, ~7-8s each) dragged into different sub-folders by a human
   (Finder→Audium drag-and-drop is not synthetically completable — see below). Multiple dailies
   added to the same sub-folder confirmed working (Scene 1 ended up with two, added at different
   times). Each transcribed (Gemini) and diarized (SpeakerKit) automatically on ingest, confirmed
   via `log show` (`Daily added: ... to folder ...` → `Gemini transcription started/succeeded` →
   `Diarization started/succeeded`) and via the resulting `.audiumproject.json` transcript text
   matching the source clip's actual dialogue.
5. Clicking between Dailies in the sidebar correctly swaps Waveform/Transcript panel content —
   confirmed via AX-read duration + transcript text changing correctly in both directions
   (Kitchen ↔ Interview), no stale data.
6. Full quit (`osascript ... quit`, confirmed process gone) → relaunch (`open build/Audium.app`)
   → reopen via Recent → sidebar tree (all 3 folders, correct dailies, correct filenames) and
   transcripts confirmed identical to pre-quit on-disk state. Persistence fully round-trips.
7. Standalone (no-project) drag-and-drop confirmed still working — with the project explicitly
   closed first, a dropped clip transcribes directly (confirmed via `log show`: a
   `Gemini transcription started` line with **no** preceding `Daily added: ... to folder ...`
   line, proving it took the standalone code path in `ContentView.ingest(_:)`, not the
   project-ingest path).

**Bugs found via this live testing and fixed (all in the same pass, re-verified after fix):**
- **Filename bug**: dropped files showed their generated UUID instead of the original filename
  in the project browser. Root cause: `ContentView.handleDrop`'s temp-copy step renamed the
  dropped file to `UUID().uuidString + ext` *before* `ProjectController.addDaily` derives
  `displayName` from the source filename. Fixed by copying into a UUID-named *subdirectory*
  instead of renaming the file itself, so the original filename survives into `displayName`.
  Confirmed fixed: `scene1_take2`/`interview_clip` both show their real names post-fix, both in
  the live sidebar and in the persisted JSON.
- **No delete option**: added `ProjectController.deleteFolder(_:)` and `deleteDaily(_:from:)`
  (removes the on-disk file(s)/directory and the metadata entry, best-effort on the media
  removal since a missing file shouldn't block clearing metadata) plus trash-icon buttons and
  `.confirmationDialog` guards in `ProjectBrowserPanel`. If the deleted Daily was the one
  currently loaded in the Waveform/Transcript panels, `ContentView.clearLoadedContentIfMatches`
  resets those panels (and `AudioPlaybackController.reset()`, made internal for this purpose)
  rather than leaving them pointing at now-deleted media.
- **No click-to-upload alternative to drag-and-drop**: added a "Browse…" button next to the
  existing drop zone, wired to a new `ContentView.browseForFile()` using `NSOpenPanel` (same
  panel-presentation pattern as `Exporter`/`ProjectController`'s existing panels). Confirmed
  working (human-driven, same Powerbox caveat as any NSOpenPanel) — routes through the same
  `ingest(_:)` as drag-and-drop, so it correctly goes to the open project's selected folder when
  one exists, or standalone otherwise.
- **No re-transcribe option**: added a "Re-transcribe" button in the loaded-waveform state,
  wired to `ContentView.retranscribeCurrent()`, which re-runs `runTranscription` against
  whatever's currently loaded (`sourceAudioURL`/`currentDailyID`) — useful after a bad first
  pass or a provider/model change. Confirmed working end-to-end including the correct
  `updateDailyTranscript` write-back to the right Daily's JSON entry.

### Permanent note: NSSavePanel/NSOpenPanel and Finder-drag-and-drop are not synthetically automatable

Same category of macOS-enforced protection as the Secure Input Mode note above, discovered
during this smoke test. An NSSavePanel/NSOpenPanel ("Powerbox"-mediated system panel) cannot be
dismissed, confirmed, or cancelled via **any** synthetic input — tested exhaustively: cliclick at
multiple coordinate calibrations, AXPress on its buttons, keyboard Return/Escape (single and
double), Tab-to-focus-then-activate, even a synthetic drag of the panel's own title bar and its
native traffic-light close button. None worked. Text entry into the filename field via synthetic
keystroke *does* work — only the confirm/cancel action is blocked. Similarly, a Finder→app
drag-and-drop can be initiated and correctly hovers/highlights a valid drop target
programmatically, but the release/drop itself never delivers; the drag ghost persists until a
separate standalone drag-up command visually clears it, without ever completing the actual drop.

**Implication for future sessions**: any task requiring a New/Open Project dialog, an
NSOpenPanel-based Browse action, or a Finder-to-Audium drag needs a real human at the mouse.
Don't spend time re-attempting synthetic automation against these — go straight to asking the
user to perform the specific click/drag, then resume automated verification (AX state reads,
`log show`, on-disk file/JSON inspection) once they confirm it's done. Ordinary in-app SwiftUI
controls (buttons, `.alert`, `.confirmationDialog`) remain fully automatable via AXPress with
positional element paths, as does regular text-field entry — this limitation is specific to
system-level Powerbox panels and cross-application drag-and-drop.

### Video playback (upgraded from audio-only)

- Current `AudioPlaybackController` (AVAudioFile/AVAudioPlayer) is audio-only — v2 needs real
  video preview + scrubbing (user decision: full video preview/scrubbing required, not just
  audio-sync). Replace/extend with `AVPlayer` + `AVPlayerLayer`/`VideoPlayer` (SwiftUI) for
  video files; audio-only dailies still use the existing waveform view. Scrubbing, play/pause,
  and transcript-sync (click-to-seek, playhead-follows-highlight) all carry over from the v1
  implementation, just need to work against `AVPlayer`'s time-observation API instead of
  polling `AVAudioPlayer.currentTime`.

### Export additions

- **`.docx` export** — fourth format alongside TXT/SRT/VTT, using the same `Exporter` pattern.
  Two distinct docx outputs likely needed: (1) a formatted transcript export (readable script
  format, speaker labels, timestamps), and (2) a **paper edit export** — the assembled
  highlights in script/screenplay-adjacent formatting, this being the actual deliverable this
  whole feature exists to produce. `python-docx`-equivalent for Swift: check what's available
  (likely hand-rolling OOXML via a Swift docx-writing approach, or a small library) — research
  needed before implementation, don't assume a library exists without checking.

### AI Chat "Roles" (text-based skills as system prompts)

- User decision: **text-based skills only for v2** (not code-driven skills — see below).
- **Skill sources, now fully imported (2026-07-23) — superseding the earlier ~14-file curated
  subset:**
  - `ur-grue/autopunk-media-skills` — **all 394 `SKILL.md` files bundled**, not a curated
    subset. Mirrored under `Skills/autopunk/<category>/<subcategory>/<skill-slug>.md`, matching
    the source repo's own `skills/<category>/<subcategory>/<skill-slug>/SKILL.md` layout
    (flattened by one level — only `SKILL.md`'s content is kept per skill, renamed to
    `<slug>.md`; the sibling `.evals.json` fixture per skill isn't bundled, the app has no use
    for it). 21 non-empty categories (a 22nd, `locales`, exists upstream but is currently empty
    so nothing bundles from it) — see `Skills/THIRD_PARTY_LICENSES.md` for the full category
    list and license text (MIT, unchanged from the original curation).
  - `OmkarPalika/filmcraft` — unchanged from the original curation: only the main
    `skills/filmcraft/SKILL.md` ("standing rules") as `Skills/filmcraft.md`; its `references/`
    and `directors/` subfolders are still out of scope (dynamic loading is a bigger feature, see
    the original reasoning below).
  - Explicitly excluded (code-driven, need Python/tool execution, not static prompts):
    `nextlevelbuilder/ui-ux-pro-max-skill` and likely others in the `ComposioHQ/
    awesome-claude-skills` curated list — unchanged, revisit only if a specific
    editorial-relevant code-driven skill is worth the much bigger investment of giving the app
    its own tool-execution capability.
- **Bundle size impact**: `Skills/` is 4.1MB (394 autopunk files + filmcraft.md + the license
  doc) — negligible against the ~123MB signed `.app` (WhisperKit/CoreML dominates that number).
  `build.sh`'s existing `cp -R "$SKILLS_SRC" "$RES_DIR/Skills"` step needed no changes; it
  already copies the directory recursively regardless of how many category/subcategory levels
  are nested inside, confirmed via a real signed build (`codesign --verify --deep --strict`
  clean) with all 396 `.md` files present under `Contents/Resources/Skills`.
- **Display names**: `Role.name` (`Sources/Audium/Role.swift`) is *not* pulled directly from
  frontmatter — both source repos' `name:` field is the same kebab-case slug as the filename
  (e.g. `name: coverage-report-writer`), not a separate human title, so there's no cleaner field
  to prefer. `Role.titleCase(_:)` derives the display name by title-casing the slug
  (`"coverage-report-writer"` → `"Coverage Report Writer"`), with a small curated acronym set
  (tv, pr, ai, seo, cms, gdpr, qa, pdf, faq) so those uppercase correctly instead of becoming
  "Tv"/"Gdpr", plus two whole-word/phrase overrides (`youtube` → `YouTube`, `pre-production` →
  `Pre-Production`) for cases generic title-casing gets wrong. Same function drives category and
  subcategory display names, since both are hyphenated slugs from the same two repos'
  conventions.
- **Category/subcategory**: `Role.category` comes from autopunk's frontmatter `category:` field
  (title-cased); files with no `category` field (currently just filmcraft.md) fall back to a
  dedicated `"Filmcraft"` category rather than an empty/misc bucket. `Role.subcategory` is read
  from the file's folder position under `Skills/autopunk/<category>/<subcategory>/` rather than
  re-parsed from frontmatter, since the import already mirrors the source repo's folder layout
  and that's the more authoritative source for it.
- **Picker UI overhaul** (`Sources/Audium/RolePickerView.swift`, new file) — a flat 395-item
  `Picker(.menu)` is unusable at this scale, per the original curated-subset design's own
  `.frame(width: 130)` menu picker no longer being viable once the subset grew to the full set.
  Replaced with `RolePickerButton`: a compact button (`role.name` + chevron) that opens a
  `.popover` containing a search field (`TextField` filtering name/summary/category, live, no
  debounce needed at this data size) and a `LazyVStack` of `Section`s — one per
  `RoleLibrary.grouped` category, cyan pinned header, roles sorted by name within each, each row
  showing the subcategory as a caption underneath. `RoleLibrary.grouped` is computed once
  alongside `RoleLibrary.all` (category-grouped, alphabetically sorted) rather than per-render.
  Verified live end-to-end via a real signed build: opened the popover, searched "coverage",
  confirmed it surfaced "Coverage Report Writer" under Screenwriting → Revision (cross-category
  match via summary text working correctly), selected it, confirmed the header updated and the
  selection persisted via `ChatSettings.defaultRoleID` across an app relaunch.
- Storage: bundled under `Skills/` (same "bundled resource" pattern as `Resources/bin/`) —
  unchanged from the original design, just now populated by a real `git clone` of
  `ur-grue/autopunk-media-skills` plus a scripted copy into the category/subcategory layout,
  rather than a hand-picked file-by-file curation.
- **Role feature fully confirmed (2026-07-24)** — three-way live comparison against the real
  signed `build/Audium.app`, same test message ("What do you think of this footage? Give me
  your honest take.") sent to Gemini under No role, Filmcraft, and one autopunk role
  (Coverage Report Writer), confirming `role.systemPrompt` genuinely changes model behavior
  rather than the picker just being cosmetic:
  - **No role**: generic single-paragraph "you didn't attach any footage" reply.
  - **Filmcraft**: reply adopts a film-professional frame — explains it needs a shot
    breakdown/stills/script to give a "structured, professional read covering story/blocking,
    visual choices, pacing/editing, and performance," i.e. filmcraft's crew/craft framing shows
    up even before any real content is supplied.
  - **Coverage Report Writer** (autopunk): reply is visibly narrower and format-driven —
    branches into two explicit numbered options (script/synopsis vs. video footage), and the
    script path names the exact industry-standard coverage fields (Title & Writer, Format &
    Genre, Logline, Synopsis with Pass/Consider/Recommend framing), matching that skill's stated
    purpose far more specifically than filmcraft's broader craft-generalist tone.
  - Confirms both bundled skill sources (filmcraft and autopunk) are wired correctly end-to-end
    — `RolePickerButton` selection → `ChatSettings.defaultRoleID` → `selectedRole` →
    `Message(role: .system, content: role.systemPrompt)` injection — not just that the picker UI
    renders and persists a selection.
  - GUI automation note for future sessions: driving `RolePickerButton`'s popover search field
    and the chat composer via Accessibility `set value of` (not keystroke simulation) works
    correctly for both — confirmed the composer's `Send` button re-disables immediately after a
    successful send (its normal empty-input state), which looks like a failed send if checked
    immediately after clicking `Send` without first re-checking the chat transcript. These
    `set value`/`click` AX calls work fine against a background (non-frontmost) window, but any
    action requiring true OS-level keyboard input does not — see the Secure Input Mode note
    below for why keystroke simulation is avoided here entirely now, not just for API keys.

### AI Chat header overflow bug — fixed (2026-07-23)

Adding the role picker (above) to `AIChatPanel`'s header row made "AI Chat" render as a
vertical, single-character-wide column instead of horizontal text — three rigid-width controls
(Logs button, role picker, provider picker) in one `HStack` on the panel's fixed 340pt width
left the title's `Text` squeezed down to near-zero width, and SwiftUI wraps text into a vertical
stack of single characters when it has no horizontal room rather than truncating. Fixed by
splitting the header into two rows: `PanelTitle("AI Chat")` alone on its own line, then a second
row for the role picker (`.frame(maxWidth: .infinity)`, so it absorbs the panel's available
width) and the provider picker (fixed 100pt). This makes the overflow structurally impossible
regardless of how many controls end up in the second row, rather than just relieving pressure
for the current control count. Verified live via a real signed build — see the screenshot check
noted under the toolbar reorg below.

### Toolbar reorganization + About panel (2026-07-23)

Moved the Log Viewer button out of `AIChatPanel`'s header (freeing more of the header-overflow
fix's second row for the role/provider pickers) and into a proper window toolbar cluster,
alongside two new entries:

- `ContentView` now carries a `.toolbar { ToolbarItemGroup(placement: .primaryAction) { ... } }`
  with three icon buttons — About (`info.circle`), Logs (`doc.text.magnifyingglass`, same
  `openWindow(id: "logs")` call the old in-panel button used), Settings (`gearshape`, via
  `@Environment(\.openSettings)`, available since macOS 14 — matches this app's
  `LSMinimumSystemVersion`, so no fallback needed). Rendered next to the traffic lights since
  the app uses `.windowStyle(.hiddenTitleBar)`, which unifies the toolbar into the title bar
  area — idiomatic for a macOS app in this style, and keeps these controls out of any content
  panel rather than embedded in one, per the task's own framing.
- **New `AboutView.swift`** — a real About panel (app name/version/build from
  `Bundle.main`'s `CFBundleDisplayName`/`CFBundleShortVersionString`/`CFBundleVersion`, app
  icon, one-line description), opened via a new `Window("About Audium", id: "about")` scene in
  `AudiumApp.swift` (same pattern as the existing Logs window). Includes a disabled "Check for
  Updates…" button with a `.help()` tooltip explaining it's not yet implemented — a labeled
  placeholder rather than a silent gap, same treatment as the DMG-packaging placeholder in
  `build.sh` (Section 7). A full auto-update mechanism (Sparkle or similar) is a separate,
  much bigger feature — explicitly out of scope for this pass, noted here as a future item.
- Verified live end-to-end via a real signed build and macOS Accessibility-driven clicks
  (`cliclick`/AppleScript `AXPress`, same class of tooling as the YouTube drag-and-drop tests
  in Section 3): toolbar icons render correctly next to the traffic lights; About opens and
  shows "Audium" / "Version 0.1 (1)" with the disabled Check-for-Updates button; Logs opens the
  existing `LogViewerView` unchanged; Settings opens via `openSettings()`. AI Chat header
  confirmed rendering "AI Chat" horizontally with the role picker (`role.name` + chevron,
  showing the persisted selection, e.g. "Coverage Report Writer") and provider picker
  side-by-side on the second row, title never squeezed.

### Keychain reset investigation — root-caused, not a persistent block (2026-07-23)

User report: suspected accidentally clicking Deny on a Keychain trust prompt left the app
unable to access saved API keys, with no prompt appearing at all on relaunch. Investigated
whether Deny created a persistent block vs. a transient one-off. **Reproduced live** (opening
Settings on a freshly rebuilt binary triggered a real `SecurityAgent` prompt for both the
`gemini` and `openai` items) and found two distinct, real things:

1. **Deny does not create a persistent block.** Each stale-ACL access attempt gets its own fresh
   prompt — confirmed by triggering the prompt, denying it, then reopening Settings and getting
   a fresh prompt again (not a cached/suppressed denial). The underlying mechanism: `save()`
   creates a self-only `SecAccess` (`SecAccessCreate(label, nil, &access)`) that, empirically,
   trusts the exact code identity of the process that created it — a fresh `swift build`/
   `build.sh` produces a new binary and thus invalidates previously-saved items' ACLs even
   though the binary is still signed with the same stable "Audium Local Dev" certificate
   (Section 3, Build & distribution). This is a broader/more general version of the
   already-documented "stale item ACL after cert regeneration" issue below — it turns out *any*
   rebuild can trigger it, not just an actual cert regeneration.
2. **The interactive prompt is a dead end for a human.** Its "Allow"/"Always Allow" buttons
   require typing "the 'Audium' keychain password" — but that password is never chosen by, or
   shown to, any human; it's re-derived on every launch via HKDF from a random salt
   (`KeychainStore.derivedPassword()`, by design, so there's nothing "at rest" to protect). Only
   "Deny" is a button a real user can meaningfully click. So the user's Deny wasn't a mistake —
   it was the only actionable option on a prompt that can't be affirmatively resolved. The real
   recovery path is re-entering and re-saving the key in Settings: `KeychainStore.save()` does a
   fresh `SecItemDelete`+`SecItemAdd` from inside the already-trusted running process, which
   sets a new self-only ACL without ever hitting that unsatisfiable prompt. Confirmed live:
   after re-saving through Settings, reopening Settings again read the key back with zero
   prompts.
3. **Real bug found and fixed as a result**: `SettingsView.loadExistingKeys()` used `try?` to
   swallow `KeychainStore.load()` errors, so a failed read (stale ACL, denied prompt, etc.)
   looked *identical* to "no key ever saved" — blank fields, no error, no indication anything
   needed fixing. This is almost certainly what the user actually experienced after their Deny:
   not "no prompt," but a prompt they had no way to satisfy, followed by silence. Fixed:
   `loadExistingKeys()` now distinguishes a failed read from an absent key and sets `status` to
   "Couldn't read saved keys from Keychain (access denied or out of date). Re-enter and Save
   Keys to fix." — confirmed live, this message appears exactly when expected and disappears
   once the keys are re-saved.

Net: no code change was needed for the ACL mechanism itself (re-saving through Settings already
recovers correctly, and did before this investigation too) — the fix is purely the
observability gap in Settings, which was the actual source of user-facing confusion.

### Permanent note: macOS Secure Input Mode blocks synthetic keystrokes into SecureFields

Any GUI-automation task (Claude Code driving the real app via Accessibility/`osascript`) that
needs to type into a `SecureField` — i.e. the API key fields in Settings — cannot use synthetic
keystroke injection (`System Events keystroke`, `cliclick` key events, etc.). macOS Secure Input
Mode blocks *all* synthetic keystroke delivery into a field marked secure, by OS design, as a
platform security guarantee against exactly this kind of injection (keyloggers/automation
reading or writing password fields). This is not a bug, not app-specific, and not scriptable
around by any Accessibility API trick — confirmed during the 2026-07-24 role-comparison session
after keystroke-based automation kept "fighting focus issues" against the API key fields.

**Implication for future sessions**: any task requiring API key entry into Settings needs a real
human at the keyboard. Don't spend time re-attempting keystroke automation against those fields.

Ordinary (non-secure) text fields are unaffected — `set value of <field> to "..."` via
Accessibility works fine for those (confirmed against the role-picker search field and the AI
Chat composer in the same session), as long as the target app is actually frontmost first
(`set frontmost of process "Audium" to true`); AX `set value`/`click` calls succeed against a
background window, but the app must be frontmost before relying on AX-reported focus state to
mean anything at the OS input level.

### Build sequencing (this is too large for one pass)

Rough phase order, to be refined as each lands:
1. AI Chat roles — **complete (2026-07-23)**: all 394 autopunk skills + filmcraft imported,
   grouped/searchable picker UI, human-readable display names. (Originally scoped as a curated
   ~14-file subset with a stock menu picker; expanded to the full set once the picker UI could
   handle grouping/search at that scale — see the Roles subsection above.)
2. Project data model + project browser UI (foundation everything else needs) — **complete
   (2026-07-26)**, real GUI smoke test passed end-to-end. See the dedicated subsection below
   ("Project data model + browser UI — smoke test complete") for full detail.
3. Video playback upgrade (AVPlayer)
4. Highlight marking in transcript panel
5. Paper Edit assembly view + reordering
6. `.docx` export (transcript + paper edit formats)

## 9. v2 Roadmap — Additional Items (not yet sequenced against Section 8 above)

- **NVIDIA Parakeet** as an alternative local ASR engine alongside WhisperKit — CoreML-viable
  on Apple Silicon, claimed ~20× faster than Whisper (per TranscribeX competitor research).
  Slots into the existing `TranscriptionProvider` protocol as a fourth implementation
  (`ParakeetProvider`) — no architecture change needed, same pattern as the existing four.
- **StoryToolkitAI-style features** — semantic/content search across transcripts, transcript
  groups, question detection. Deliberately deferred from v1 (see original scoping conversation)
  — revisit once core app is stable.
- **ScriptFixer integration** — export option for Avid ScriptSync-ready plain text, reusing
  ScriptFixer's existing parsing/formatting conventions (18-char dialogue indent, 52-char line
  width, `NAME:`/`NAME OS:` cue format, ASCII sanitization) as a fourth export format alongside
  TXT/SRT/VTT. Natural fit given both tools already live in the Ghost-Frames ecosystem.
- Batch/folder auto-detect transcription (competitor-validated as a common expectation, not
  currently in v1 scope)

