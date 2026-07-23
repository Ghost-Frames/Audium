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

## 8. v2 Roadmap (not in scope now, captured for later)

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

