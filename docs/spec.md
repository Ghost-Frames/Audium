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
- Four implementations, user-selectable per job or as a default in Settings:
  - `WhisperKitProvider` — local, on-device, free, private. Default on Apple Silicon. Package:
    `argmax-oss-swift` (formerly WhisperKit), product `WhisperKit`. CoreML/Metal-accelerated,
    replaces WhisperX/Python entirely. **Unsupported on Intel Macs** — SIGSEGVs before
    compute-unit dispatch (spec §5, Known Issues) — `WhisperCppProvider` below is the local
    fallback there.
  - `WhisperCppProvider` — local, on-device, CPU-only, added **2026-07-27** specifically to give
    Intel Macs (Zeus) a working local transcription option since `WhisperKitProvider` remains
    blocked there. **Architecture decision**: bundled as a static binary
    (`Resources/bin/whisper-cli`, built from `ggml-org/whisper.cpp` with
    `-DBUILD_SHARED_LIBS=OFF`), same pattern as `ffmpeg`/`yt-dlp` — **not** WhisperX/Python. This
    keeps the zero-dependency/no-Python principle intact (the same principle
    `WhisperKitProvider`'s own doc comment already invokes — "replaces WhisperX/Python
    entirely") rather than reversing it just because this one provider needed a CPU fallback.
    Full research/implementation detail, citations, and real Intel-hardware test results in the
    dedicated subsection below ("whisper.cpp local transcription provider — implemented").
  - `GeminiTranscriptionProvider` — cloud, via Gemini API's native multimodal audio input
    (Gemini accepts audio files directly as an input type). Uses user's Gemini API key.
  - `OpenAIWhisperAPIProvider` — cloud, via OpenAI's `/v1/audio/transcriptions` endpoint (or
    GPT-4o native audio input). Uses user's OpenAI API key.
  - **Claude is NOT a transcription provider** — the Anthropic Messages API has no audio input
    modality; Claude's consumer "voice mode" is a separate product feature, not an API
    capability. Claude stays in the `AIProvider` role only (cleanup/summarize/chat on
    already-transcribed text).
- Local WhisperKit model files downloaded on first use, not bundled in the `.app`/DMG (see
  Resolved Decisions) — same principle extended to whisper.cpp's GGML model files.
- Cloud providers (Gemini/OpenAI transcription) are a deliberate tradeoff against the
  local-first/private-by-default principle — clearly labeled as such in the picker UI, not
  defaulted to. whisper.cpp keeps that principle intact on hardware where WhisperKit can't.

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
- **SwiftUI `VideoPlayer` crashes on first render, real GUI (2026-07-26)** — dropping a video
  file crashed with `EXC_CRASH`/`SIGABRT`, a Swift runtime `fatalError` inside
  `getSuperclassMetadata`/generic metadata instantiation for `_AVKit_SwiftUI` (the private
  framework backing SwiftUI's `VideoPlayer`). Investigated across two separate crash reports
  before landing on the real cause:
  1. First report: the crashing main thread (first `VideoPlayer` render) coincided with a
     background "coremedia queue" thread running `AVAssetExportSession.init` from
     `extractedAudioURL(from:)` — looked like a Swift generic-metadata-cache race between two
     first-touches of overlapping AVFoundation/AVKit-SwiftUI metadata on different threads.
     Root cause of *that* specific concurrency: `extractedAudioURL` was a plain free function
     with no actor annotation, and per Swift concurrency rules, calling a non-isolated async
     function from `@MainActor` code (`ContentView.runTranscription`) runs the callee's body on
     the global concurrent executor, not the caller's thread — so it really was running
     concurrently with `runTranscription`'s prior `playback.load(url:)` call, which sets
     `AudioPlaybackController.avPlayer` and schedules `VideoPlayer`'s first render. Fixed by
     marking `extractedAudioURL` `@MainActor`, serializing both onto one thread.
  2. Retested (real GUI, same clip, multiple drops): crashed again, **same exact signature**,
     but the concurrent background activity was completely different this time
     (`AVCaptureProprietaryDefaultsSingleton`/CoreAudio HAL init, unrelated to Audium's own
     extraction code). This ruled out the race-with-extraction theory — two different concurrent
     culprits producing the identical crash signature means the crash is inside `VideoPlayer`'s
     own bridging layer itself on this OS build, not caused by anything Audium's code does
     concurrently around it. The `@MainActor` fix above is still correct (real race, real fix)
     but wasn't the cause of the crash — it just wasn't sufficient, since `VideoPlayer` itself is
     unsafe to first-render here regardless of what else is happening on other threads.
  **Fixed — confirmed via real drag-and-drop (2026-07-26)**: replaced SwiftUI's `VideoPlayer` with AppKit's `AVPlayerView`
  wrapped via `NSViewRepresentable` (`PlayerView` in `ContentView.swift`, next to
  `WaveformBarsView`) — `AVPlayerView` is the older, stable AppKit control and never touches the
  `_AVKit_SwiftUI` bridge at all. `controlsStyle = .inline` keeps AVKit's native floating
  play/pause/scrub-bar overlay, satisfying the "scrubbing carries over" requirement (spec §8)
  for free rather than reimplementing a custom drag-to-scrub gesture over raw video like
  `WaveformBarsView` does for audio bars. The underlying `AVPlayer` object, its periodic
  time-observer (transcript sync), and `timeControlStatus` KVO (keeps the custom play/pause
  button's icon in sync with AVKit's own native controls) are all unchanged — only the view
  layer wrapping the same player object changed.
- WhisperKit crashes with SIGSEGV on Intel Macs (no Neural Engine) — `TextDecoder.swift:139`,
  KV-cache tensor allocation via `.float16` IOSurface-backed initializer, happens before
  CoreML compute-unit dispatch so `ModelComputeOptions` can't route around it. Confirmed on
  Zeus (Intel iMac20,2), not yet confirmed working or broken on Apple Silicon (monkey-sign
  currently unreachable). Filed/to-file against `argmaxinc/argmax-oss-swift`. Fix plan once
  confirmed on Apple Silicon: runtime ANE detection, block WhisperKit selection on Intel with
  a clear message, or steer default to cloud transcription (Gemini/OpenAI) on unsupported
  hardware. Not blocking other work — proceeding with hardware-agnostic features in the
  meantime (SpeakerKit, cloud transcription providers, export, AI provider panel).
  **Local-fallback fix shipped 2026-07-27** — see the dedicated subsection below ("whisper.cpp
  local transcription provider — implemented") — WhisperKit on Intel itself stays broken
  (upstream, not something this app can fix), but Intel Macs now have a real working local
  option instead of only cloud providers.

### whisper.cpp local transcription provider — implemented (2026-07-27)

Gives Zeus (Intel) a working local transcription option since `WhisperKitProvider` remains
SIGSEGV-blocked there (above). Implementation in the new `WhisperCppProvider.swift`.

**Architecture decision** (made with the user before implementation, documented per spec §3):
bundle `whisper.cpp` as a static binary in `Resources/bin/`, same pattern as `ffmpeg`/`yt-dlp` —
explicitly **not** WhisperX/Python. Keeps the zero-dependency/no-Python principle intact rather
than reversing it for one provider's sake.

**Research performed before writing any code** (per explicit instruction, same discipline as the
EDL exporter's research — live-checked, not assumed):
- **No official prebuilt macOS CLI binary exists.** Checked directly against the GitHub Releases
  API (`api.github.com/repos/ggml-org/whisper.cpp/releases/latest`, not just the web page, which
  failed to render its asset list) — the actual asset list is Linux (arm64/x64), Windows
  (Win32/x64, BLAS/CUDA variants), and a `whisper-v1.9.1-xcframework.zip` (an Xcode-only Swift/
  ObjC library target, not a standalone CLI executable — doesn't fit "shell out to a bundled
  binary"). No macOS CLI archive, unlike `ffmpeg`/`yt-dlp` which do ship prebuilt static
  binaries. Confirms the task's anticipated fallback ("build instructions if no static binary is
  published") was the right path, not an assumption.
  **Built from source instead** — cloned `ggml-org/whisper.cpp`, configured with
  `cmake -B build -DBUILD_SHARED_LIBS=OFF -DCMAKE_BUILD_TYPE=Release -DGGML_METAL=OFF
  -DWHISPER_COREML=OFF` (confirmed via the project's own README: default CMake build is CPU-only,
  CoreML is opt-in only via `-DWHISPER_COREML=1`, never enabled here — the whole point is *no*
  ANE/CoreML dependency, the exact thing that crashes `WhisperKitProvider`), built with
  `cmake --build build -j --config Release`. `otool -L` on the resulting `whisper-cli` confirms
  it only links `libSystem`, `Accelerate.framework`, and `libc++` — all system frameworks, no
  bundled third-party dylibs needed alongside it, satisfying the "static binary" requirement the
  same way `ffmpeg`/`yt-dlp` already do (they also link only system libs, just ship no bundled
  dylibs). x86_64-only, same tradeoff `ffmpeg`'s own evermeet.cx build already has (runs on Apple
  Silicon via Rosetta 2 if ever needed there, though the point of this provider is Intel).
- **Audio format support**: whisper.cpp's built-in decoder (miniaudio) only reads flac/mp3/ogg/wav
  natively — confirmed by testing directly against a real `.aiff` file before writing any Swift
  code (`read_audio_data: failed to read audio data`). This app's actual inputs are AIFF
  (drag-and-drop) and M4A (`extractedAudioURL`'s video exports), neither supported. Fixed by
  pre-converting to 16kHz mono WAV via the already-bundled `ffmpeg` (same binary
  `YouTubeDownloader` already uses) before invoking `whisper-cli` — reuses existing bundled
  infrastructure rather than adding a second audio-decoding dependency.
- **CLI output format**: `-oj`/`--output-json` (not `-ojf`/full — per-token detail isn't needed,
  diarization is `SpeakerKit`'s job, not whisper.cpp's own `-di`/`-tdrz` flags) writes
  `<outputBase>.json` with a `{ transcription: [{ offsets: { from, to }, text }] }` shape,
  offsets in **milliseconds** — confirmed against whisper.cpp's own
  `examples/cli/cli.cpp` source (fetched directly, not assumed) and cross-checked by actually
  running `whisper-cli -oj` against the repo's own `samples/jfk.wav` and inspecting the real
  output file before writing the Swift parser.
- **GGML model hosting**: `https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-<model>.bin`
  — confirmed via the project's own `models/download-ggml-model.sh` script (its `src`/`pfx`
  variables), replicated as a plain `URLSession.download(from:)` in `WhisperCppModelManager`
  rather than shelling out to their bash script.

**Model handling**: `WhisperCppModel` (tiny/base/small/medium, `.en` and multilingual, plus
large-v1/v2/v3/v3-turbo — quantized variants left out, not requested) + `WhisperCppSettings`
(persisted default, same pattern as `WhisperModelSettings`) + `WhisperCppModelManager`
(download-on-first-use into `~/Library/Application Support/Audium/whisper-cpp-models/`, same
"not bundled" principle as WhisperKit's own models). Default `base.en` — reasonable speed/
accuracy balance for CPU-only inference with no GPU/ANE acceleration. Settings gained a
"whisper.cpp Model Size" section mirroring the existing WhisperKit one.

**Provider picker + default-suggestion logic**: added to both the Settings radio picker and the
runtime `switch` in `ContentView.runTranscription`. The existing "steer away from WhisperKit on
unsupported hardware" `onAppear` check (spec §5, already existed for the SIGSEGV) now steers to
**whisper.cpp**, not a cloud provider, when `HardwareCapability.hasNeuralEngine` is false — it's
the local/private-by-default option that actually works on that hardware, closer to the app's
local-first principle than defaulting to a cloud API key requirement. Only fires when the
*persisted* default is still `.whisperKit` (the original migration-safety-net condition,
unchanged) — doesn't override an already-deliberate Gemini/OpenAI choice a user made themselves.

**Real GUI test on Zeus (Intel iMac20,2)** — the actual point of this feature:
1. Confirmed `whisper-cli` signed correctly in the built app bundle (`codesign -dv`).
2. Settings → Default Transcription Provider: new "whisper.cpp (local, CPU)" option present,
   WhisperKit still correctly disabled/flagged unsupported, explanatory text updated. Selected
   whisper.cpp explicitly; confirmed persisted (`defaults read
   com.postproduction.Audium com.postproduction.Audium.defaultTranscriptionProvider` → `whisperCpp`).
3. Real end-to-end transcription via Browse… (human-completed `NSOpenPanel` confirm, per the
   established Powerbox-panel limitation) against a real `.aiff` test clip
   (`interview_clip.aiff`) — **succeeded**: correct transcript text matching the real spoken
   audio ("The first time I saw the building, I knew something was wrong." / "There was a light
   on a window that shouldn't have had power at all.") rendered in the real Transcript panel,
   `Speaker 0` labels present confirming `SpeakerKit` diarization ran successfully afterward,
   waveform loaded and playable. This is the exact clip/machine combination where
   `WhisperKitProvider` SIGSEGVs — whisper.cpp transcribed it cleanly.
4. Independently confirmed via two separate signals rather than relying on the screenshot alone:
   the GGML model landed at the exact expected path
   (`~/Library/Application Support/Audium/whisper-cpp-models/ggml-base.en.bin`, 147MB, timestamped
   right before completion), and `otool`/`codesign` confirmed the bundled binary itself was
   correct going in.
5. **`log show` anomaly, noted honestly rather than silently worked around**: `log show
   --predicate 'subsystem == "com.postproduction.Audium"'` returned *zero* lines for this test
   window (tried multiple time ranges up to 1 hour, with and without `--info`/`--debug`), despite
   `AudiumLog.transcription.info(...)` calls unconditionally firing at the very start of
   `WhisperCppProvider.transcribe(audio:)` — the same `Logger` pattern used successfully for
   `log`-based verification throughout every earlier phase this session. `log show --predicate
   'process == "Audium"'` for the same window *did* return over 1000 lines, all system-subsystem
   (CoreAudio, AppKit) — so unified logging itself was working for this process, just not
   surfacing this app's own subsystem's entries for reasons not root-caused. Not treated as
   blocking: the screenshot evidence (a genuinely correct transcript that could only have been
   produced by successfully running the real pipeline end-to-end) and the independent model-file
   confirmation are definitive on their own. Worth investigating in a future session if `log
   show` verification is needed again and comes up similarly empty.
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

### Video playback (upgraded from audio-only) — implemented (2026-07-26)

`AudioPlaybackController` (`AudioPlayback.swift`) now dual-mode: audio files still use the
original `AVAudioPlayer` + extracted-waveform path; video files (`.mp4`/`.mov`/`.m4v`/`.avi`/
`.mkv`/`.webm`, `AudioPlaybackController.videoExtensions`) use `AVPlayer` instead, with a periodic
time observer driving `currentTime` (transcript sync/click-to-seek reuses the same `seek(to:)`
API either way) and a `timeControlStatus` KVO observation keeping `isPlaying` accurate regardless
of whether playback was toggled via Audium's own button or AVKit's native controls.

Original plan called for SwiftUI's `VideoPlayer` as the view layer — **changed to AppKit's
`AVPlayerView` wrapped via `NSViewRepresentable`** (`PlayerView` struct in `ContentView.swift`)
after `VideoPlayer` crashed on first render with a SIGABRT inside `_AVKit_SwiftUI`'s generic
metadata instantiation on this OS build — see spec §5 Known Issues for the full investigation
(ruled out a race in Audium's own code; the bridging layer itself is unsafe to first-render here).
`AVPlayerView`'s `controlsStyle = .inline` gives native scrubbing/play-pause for free. Video and
audio dailies both drop into the same `WaveformPanel`/waveform-vs-preview area, switching on
`playback.isVideo`; the panel title switches between "Waveform" and "Preview" accordingly.

Transcription: every `TranscriptionProvider` reads its input as a plain audio file, which can't
open a multiplexed video container — `extractedAudioURL(from:)` (`TranscriptionProvider.swift`)
exports just the audio track to a temp `.m4a` via `AVAssetExportSession` first, for video dailies
only (audio dailies pass through unchanged). This function is `@MainActor`-pinned — not for UI
safety, but because a non-actor-isolated async function called from `@MainActor` code runs on the
global concurrent executor rather than the caller's thread (see spec §5 Known Issues); that
mattered while `VideoPlayer` was still in play, and is left in place as the correct fix for that
specific concurrency question even after moving off `VideoPlayer`.

### Highlight marking — implemented (2026-07-26)

`Highlight` (`Project.swift`, alongside `ProjectMetadata`/`Daily`) fleshed out from Phase 2's bare
`{ id: UUID }` stub to: `id`, `start`/`end` (`TimeInterval`), optional `note: String?`,
`createdAt: Date`. Anchored to `start`/`end` timestamps rather than `TranscriptSegment.id`
(regenerated fresh on every `Codable` decode — deliberately excluded from that type's own
encoding, see its doc comment) or an array index (unstable across a re-transcribe, which fully
replaces `Transcript.segments`). Single-segment for this pass — `start`/`end` mirror one
highlighted segment exactly, matching the simpler of the two selection mechanisms considered
(per-segment vs. drag-to-select a cross-segment range); a future multi-segment range is just a
wider `start`/`end` pair spanning several segments, no format change needed. No separate
`tag`/`color` field — the app's design language deliberately uses one accent color throughout (see
`WaveformBarsView`'s doc comment), so there's no second hue for a color picker to choose between.

**UI** (`ContentView.swift`):
- `SegmentRow` gained a star button (`star`/`star.fill`) toggling that segment's highlight —
  disabled/dimmed (not hidden, keeps row layout stable) for a standalone no-project file, since a
  Highlight needs a Daily to attach to (same constraint `Re-transcribe`'s `dailyID` already
  follows). Highlighted segments also get a 3pt leading accent-color stripe (`.overlay(alignment:
  .leading)`) — deliberately a *different* visual than the existing "currently playing" full-row
  tint (`isCurrent`, `Theme.accent.opacity(0.14)`), so a segment that's both playing and
  highlighted at once reads as two distinct states, not a double-strength version of one state.
- `HighlightsMenu`/`HighlightsListView` — a small "★ N" count badge in the Transcript panel header
  (next to `ExportMenu`, same "click to reveal a lightweight popover list" shape), listing every
  highlight for the current Daily sorted by `start`: timestamp (click to seek), the matched
  segment's text (looked up by `start`, same identity rule as the toggle), and a remove button.
  Not the full Paper Edit assembly view (spec's next phase) — just enough to see/navigate/remove
  what's been marked so far, per this phase's scope.
- `ProjectController.addHighlight(_:to:)`/`removeHighlight(_:from:)` — same
  find-folder-then-find-daily-then-mutate-then-`save()` shape as `updateDailyTranscript`.
  `ContentView.currentHighlights` is a computed property reading straight from
  `project.metadata` (not mirrored into separate `@State`) so it can't drift out of sync with the
  persisted data.

**Real GUI test** (signed `build/Audium.app`, same AXPress/positional-element-path methodology as
every other phase's smoke test): reused the Phase 2 smoke-test project
("Audium Smoke Test Project"), seeding one Daily's transcript with 3 segments directly on disk
(splitting its existing single-segment dialogue into 3 sentences with distinct timestamps —
legitimate test-data setup, not a shortcut around the feature under test, same precedent as
Phase 2 seeding a project's initial JSON since NSSavePanel confirmation isn't automatable).
Marked all 3 segments as highlights via their star buttons — confirmed via `log show`
(`Highlight added to daily ...` ×3) and on-disk JSON (`start`/`end` matching all 3 segments
exactly). Removed the middle highlight via the popover's trash button — confirmed via `log show`
(`Highlight removed from daily ...`) and on-disk JSON (2 remain, correct ones). Fully quit
(`osascript ... quit`, process confirmed gone) → relaunched → reopened via Recent → reselected the
Daily → reopened the Highlights popover: both surviving highlights present with correct text
("Where were you last night?" / "Ask anyone who was there.") and correct order, the removed one
("I told you, I was at the restaurant the whole time.") correctly still gone. Full round-trip
persistence confirmed, same rigor as Phase 2's project data-model test.

### Paper Edit assembly — implemented (2026-07-26)

The actual deliverable this whole v2 direction exists to produce (spec intro, §8). Data model in
`Project.swift`, UI in the new `PaperEditView.swift`.

**Data model**: `PaperEdit` (`id`, `name`, `entries: [PaperEditEntry]`) and `PaperEditEntry`
(`id`, `dailyID`, `highlightID`) — an entry references a Highlight by ID rather than copying its
text/timestamps, so edits to the underlying transcript/highlight propagate automatically.
`dailyID` is carried explicitly on the entry (not re-derived by scanning every folder) since it's
needed to resolve playback (source media URL) and display without ambiguity. **Multiple named
Paper Edits per project**, not just one — real editorial workflow wants more than a single
assembly from the same dailies (e.g. a "selects" reel vs. a tighter cut), and supporting an array
instead of a single value cost nothing extra in the model. `ProjectController` gained
`addPaperEdit`/`deletePaperEdit`/`addPaperEditEntry`/`removePaperEditEntry`/
`movePaperEditEntries` (the last matches `List.onMove`'s `(IndexSet, Int)` shape directly, no
translation needed at the view layer) — same find-then-mutate-then-`save()` shape as every other
`ProjectController` method.

**Cascade cleanup**: deleting a Highlight, Daily, or Folder now also removes any Paper Edit
entries that referenced it (`removeDanglingPaperEditEntries` helper, called from
`removeHighlight`/`deleteDaily`/`deleteFolder`) — otherwise a deleted Highlight would leave a
dangling entry with nothing to resolve its timestamp/text from. Removing an entry *from* a Paper
Edit does **not** delete the underlying Highlight — that direction stays independent, per spec.

**UI**: a separate window (`Window("Paper Edit", id: "paperEdit")` in `AudiumApp.swift`,
opened via a new toolbar button and Cmd+Shift+P), not a 5th bento panel — the existing 4-panel
layout (project tree · waveform/preview · transcript · AI chat) is already tight at the window's
minWidth, and reviewing/reordering a Paper Edit is a distinct editorial task rather than something
used moment-to-moment alongside transcription. Sidebar lists every Paper Edit in the project
(create/delete); the main area lists the selected one's entries (Daily name, timestamp range,
highlighted text), reorderable via SwiftUI's native `List.onMove` drag — the native platform
mechanism, not a hand-rolled drag gesture. "Add to Paper Edit" lives in the existing Highlights
popover (`ContentView.swift`) as a per-highlight menu: pick an existing Paper Edit or "New Paper
Edit…", which creates one inline.

**Playback reuses the existing wiring, not duplicated**: `ProjectController` and
`AudioPlaybackController` were promoted from `ContentView`'s own `@StateObject`s to
`AudiumApp`-level `@StateObject`s, injected into both the main `WindowGroup` and the new `Window`
via `.environmentObject` (SwiftUI's environment doesn't cross Scene boundaries on its own, so each
Scene's root needs its own `.environmentObject` call against the same instances). Clicking a Paper
Edit entry's play button calls the same `mediaURL(for:in:)` → `playback.load(url:)` →
`playback.seek(to:)` → `playback.play()` sequence any sidebar Daily click already goes through —
confirmed live via the shared engine: playing an entry from the Paper Edit window visibly loads
and plays in the *main* window's Waveform/Preview panel (real GUI test, see below).

**Deliberate v1 scope boundary** (not a bug): playing a Paper Edit entry does *not* also update
the main window's Transcript panel — `segments`/`currentDailyID` are private `@State` on
`ContentView`, not shared state, so only the Waveform/Preview panel (driven by the shared
`playback` object) follows along. Promoting that state too would be a bigger change than this pass
called for; noted here rather than silently left inconsistent.

**Deliberately not built this pass**: sequential "play the whole Paper Edit in order"
(auto-advance). Each entry can come from a different Daily/media file, so auto-advance means
detecting an entry's end via the time observer, then loading + seeking the *next* entry's file
gaplessly — a real state machine, not a one-line addition. Reasonable v2.1 addition; clicking an
entry to play from its start covers this pass's actual requirement.

**Frame rate groundwork** (spec: needed for the next phase, EDL export, without retrofitting
later): `Daily` gained `frameRate: Double?` — nil for audio-only dailies. Not left purely as an
inert field for later backfill: `ProjectController.addDaily` now `async` (was throws-only) and
opportunistically captures it for video dailies via `AVAssetTrack.load(.nominalFrameRate)`
(`Self.nominalFrameRate(of:)`), non-fatally (`try?`) so extraction failure doesn't block adding
the Daily. Capturing it now, rather than leaving every field nil until EDL export lands, avoids
every video Daily added in between needing a separate backfill pass.

**Bugs found via this live testing and fixed (both real, both in the same pass):**
- **Missing-key decode failure on older project files**: adding `ProjectMetadata.paperEdits:
  [PaperEdit] = []` broke opening *any* project JSON saved before this change — real GUI test,
  first attempt to open the Phase 2 smoke-test project threw and showed "The data couldn't be
  read because it is missing." Root cause: Swift's synthesized `Decodable` does **not** fall back
  to a stored property's `= []` default for a genuinely-missing key — only `Optional` properties
  decode a missing key as `nil` automatically. Every pre-existing project file lacked the
  `"paperEdits"` key outright. Fixed with a custom `init(from:)` using
  `decodeIfPresent(...) ?? []` for that one field (the rest stay on the synthesized path via an
  explicit memberwise `init` alongside it). `Daily.highlights`/`Daily.frameRate` didn't need the
  same fix — `highlights` predates any real project file ever written (always present), and
  `frameRate` is `Optional`, which synthesized decode already handles correctly.
- **Drag-to-reorder silently did nothing**: `PaperEditEntryRow` originally wrapped the *whole
  row* in `.contentShape(Rectangle()).onTapGesture { onPlay() }` (matching the "click entry to
  play" requirement) — but on macOS, a tap gesture covering a `List` row's full area blocks
  `.onMove`'s native reorder-drag from ever engaging, since both claim the same touch. Real GUI
  test confirmed: multiple careful drag attempts (varied speed, added an explicit focus click
  first) produced zero movement. Fixed by scoping the play action to a real `Button` around just
  the row's leading play icon, leaving the rest of the row free for the List's native drag.
  Confirmed fixed after a human performed the drag (`cliclick`-synthesized drags don't reliably
  trigger `List`'s native reorder session either — see the new permanent note below) — order
  change verified on disk and visually, then reconfirmed surviving a full quit/relaunch.

**Real GUI test** (signed `build/Audium.app`, same methodology as every other phase): reused the
Phase 2/3 smoke-test project. Seeded a 3rd highlight on `interview_clip` (starred its one segment)
so the Paper Edit could span two different Dailies, not just multiple highlights within one.
Added all 3 highlights to a newly-created "Paper Edit 1" via the Highlights popover's per-entry
menu (first entry: "New Paper Edit…"; remaining two: selecting the now-existing "Paper Edit 1" —
confirmed via `log show`: one `Paper Edit created` line, two `Paper Edit entry added` lines).
Opened the Paper Edit window (toolbar button): all 3 entries listed with correct Daily
name/timestamp range/text, in add order. A human performed the one drag-reorder (see permanent
note below); confirmed the resulting order both on-disk (`.audiumproject.json`) and visually.
Fully quit → relaunched → reopened project → reopened Paper Edit window: reordered sequence
identical to pre-quit state, full persistence round-trip confirmed. Clicked an entry's play
button: confirmed (screenshot) the main window's Waveform panel loaded that entry's Daily,
seeked to its start, and began playing (pause icon, elapsed time advancing) — the shared-engine
playback wiring works correctly end-to-end.

### Permanent note: SwiftUI `List` drag-to-reorder on macOS doesn't respond to synthetic (`cliclick`) drag events

Distinct from the existing Powerbox/Finder-drag limitation above (this is an ordinary in-app
control, not a system panel or cross-app drag) but empirically just as non-automatable in this
environment. Tried: a basic 3-step `cliclick dd/dm/du` drag; a slower multi-step drag with pauses
between each intermediate point; the same with an explicit window-focus click first. All produced
zero movement, identically, across every attempt — no partial/flaky success. AXPress-style
`.click()` isn't applicable here since reordering is inherently a drag, not a discrete
press. **Implication for future sessions**: any task requiring a `List`/table drag-reorder needs a
human at the mouse for that one step, same workflow as the Finder-drag note — ask directly, then
resume automated verification (on-disk JSON, screenshots, `log show`) once they confirm it's done.
Ordinary button/control clicks inside the same `List` (e.g. a row's own play/remove buttons)
remain fully automatable via AXPress — this is specific to the reorder-drag gesture itself. Also
worth noting for future AX automation in any `List`: each row is wrapped in an `AXCell` (standard
for `List`'s `NSTableView` backing on macOS) — a row's actual controls sit *one level deeper* than
they would in a plain `VStack`/`HStack` (`row → AXCell → actual button`), not directly at the row
level. Getting this depth wrong doesn't error, it just silently clicks the inert `AXCell` instead
of the real control — confirmed this exact mistake mid-session (see the Paper Edit playback bug
write-up above, which turned out to be a test-automation bug, not an app bug, once the correct
depth was used).

### EDL export (CMX3600) — implemented (2026-07-26)

Targets real Avid Media Composer import compatibility (spec §9's original wording). Implementation
in the new `EDLExporter.swift`, mirroring `Exporter.swift`'s render/write/`NSSavePanel` pattern in
its own file since the CMX3600 domain (timecode/drop-frame/reel-name math) is substantial. Export
button ("Export EDL…", `AccentButtonStyle`) lives in `PaperEditView`'s entries header.

**Research performed before writing any code** (per explicit instruction — this needed to be
right on a first real Avid import attempt, not trial-and-error). Live web research, not assumed
from training-data recollection, cross-checked across multiple independent sources:

- **Reel names**: CMX3600 reel/source names are limited to 8 characters, alphanumeric A-Z/0-9
  only (a holdover from physical tape-reel labeling on the original CMX hardware) — confirmed via
  [edlmax.com's EDL guide](https://edlmax.com/EdlMaxHelp/Edl/maxguide.html) and corroborated by
  [Wikipedia's EDL article](https://en.wikipedia.org/wiki/Edit_decision_list) (noting Final Cut
  Pro's CMX3600 export enforces the same 8-char limit even though Avid's own *native* project
  format allows up to 32 chars — the constraint is CMX3600's, not Avid's, but since we're writing
  CMX3600, 8 chars is what applies). "AX" is the documented placeholder for a clip with no usable
  reel name (a file rather than a tape/camera reel).
- **"* FROM CLIP NAME:" comment convention** for preserving the real name past the 8-char
  truncation — confirmed as a real, current convention (not invented) via
  [OpenTimelineIO's `otio-cmx3600-adapter`](https://github.com/OpenTimelineIO/otio-cmx3600-adapter)
  source, a maintained reference EDL writer used across the industry (Netflix and others). Its
  actual write-path format string: `"* {FROM|TO} CLIP NAME:  {name}"` (two spaces after the
  colon) — replicated verbatim.
- **Event line layout**: event number (3-digit) · reel (8-char field) · track/channel code ·
  edit type · source in/out · record in/out, cross-checked against the same OTIO source's literal
  format string (`"{edit:03d}  {reel:8} {kind:5} C        {src_in} {src_out} {rec_in} {rec_out}"`,
  cut-only — no dissolve/wipe support needed since a Paper Edit is a straight assembly, no
  transition data exists in the model) and against
  [CutConvert's EDL guide](https://cutconvert.com/guides/what-is-an-edl). Track/channel codes
  confirmed: `V` video-only, `A`/`A2` audio channel(s), `B` video+audio1 (the standard code for a
  plain synced video+audio cut) — this app emits `A` for audio-only Dailies, `B` for video Dailies
  (every video Daily has an embedded audio track; there's no video-only case to emit `V` for).
- **FCM (Frame Code Mode) line**: `FCM: NON-DROP FRAME` / `FCM: DROP FRAME`, confirmed via
  CutConvert's guide ("Get this wrong and every record timecode drifts") and Wikipedia. SMPTE
  258M allows FCM to appear again before any later event to switch modes mid-document, not just
  once at the top — confirmed by OTIO's reader parsing per-event FCM — which this exporter uses:
  it emits a new FCM line only when an event's drop/non-drop mode differs from the previous one,
  not unconditionally per event.
- **Drop-frame timecode conversion**: CMX3600/SMPTE timecode has **no numeric frame-rate field
  anywhere in the format** — only the DF/NDF mode flag, since the receiving system's own project
  settings supply the actual numeric rate, and DF/NDF is the *only* thing that changes how frame
  numbers are counted (relevant solely to the 29.97/59.94 NTSC family, which isn't exactly 30/60fps
  and drifts from wall-clock time by ~3.6 sec/hour if not corrected — confirmed via multiple
  sources including a [SMPTE timecode explainer](https://www.davidheidelberger.com/2010/06/10/drop-frame-timecode/)).
  Drop-frame timecode conventionally uses a semicolon (`;`) before the frames field instead of a
  colon, visually flagging DF at a glance — confirmed via a
  [Blackmagic forum thread](https://forum.blackmagicdesign.com/viewtopic.php?t=96031) on
  DF/NDF conversion workflows. **Conversion algorithm**: Andrew Duncan's drop-frame algorithm as
  published by [David Heidelberger](https://www.davidheidelberger.com/2010/06/10/drop-frame-timecode/)
  — frame numbers 0 and 1 are skipped at the start of every minute except every 10th, computed via
  `framesPer10Minutes`/`framesPerMinute`/`dropFramesPerMinute` — implemented verbatim in
  `EDLExporter.dropFrameComponents`. Naively treating 29.97 as flat 30fps (skipping this
  correction) is exactly the "EDL imports with wrong timing" bug class called out in the task —
  avoided by implementing the real algorithm, not a shortcut.

**Design decision, not explicitly covered by research**: a Paper Edit can span Dailies of
different (or absent, audio-only) frame rates, but CMX3600 fundamentally has no way to declare a
numeric rate at all (per the point above) — so "mixed frame rates in one EDL" isn't really a
format feature to support or fail to support, it's a non-concept. Each event's *own* rate governs
both its source and record timecode columns (keeping one event line internally FCM-consistent);
real elapsed record time is tracked in seconds and only converted to frame notation per event, so
consecutive events at different rates still line up exactly in real time at their cut points —
only the FF digits differ there, which is exactly how a real mixed-rate EDL looks, not a bug.
Entries with no captured `frameRate` (audio-only Dailies) fall back to 30fps non-drop, the
conventional safe default for audio-only EDL content.

**Bugs found via live testing and fixed (three, all in this pass):**
- **Drop-frame tolerance too loose**: `isDropFrame(rate:)`'s original `0.05` tolerance
  misclassified an exact `30.0`fps rate as drop-frame (`|30 − 29.97| = 0.03 < 0.05`). Caught
  *before* ever touching the GUI, via a standalone command-line harness
  (`swiftc EDLExporter.swift AudiumLog.swift main.swift`, synthetic entries covering audio/video/
  drop-frame/collision cases, run outside the app) — exactly the kind of naive-DF-handling bug the
  task called out as a real risk. Fixed by tightening to `0.01`.
- **Double file extension**: `NSSavePanel.nameFieldStringValue` was pre-set to `"<name>.edl"`
  *and* `allowedContentTypes` was also set to append `.edl`, producing `"Paper Edit 1.edl.edl"` in
  the real save panel — caught via real GUI test (screenshot of the actual panel). Fixed by
  passing just the base name and letting `allowedContentTypes` supply the one extension, matching
  how `NSSavePanel` is meant to be driven.
- **Same Daily got a different reel name each time it appeared** (a Paper Edit commonly pulls
  multiple highlights from one Daily) — the reel-name allocator treated every `allocate` call as
  needing a fresh unique slot rather than reusing what that Daily was already assigned, so two
  highlights from `scene1_take2` exported as reels `SCENE1TA` and `SCENE101` instead of both being
  `SCENE1TA`. This would actively break a real Avid relink (two different reel names read as two
  different source files). Caught via the real exported file's content, not just structural
  skimming. Fixed by keying the allocator on `Daily.id` (added to `EDLExporter.Entry`) and
  memoizing the assigned name per Daily, only disambiguating collisions between *different*
  Dailies.

**Real GUI test** (signed `build/Audium.app`): exported from the existing 3-entry/2-Daily Paper
Edit (`interview_clip` + `scene1_take2` ×2, all audio-only `.aiff` — this project's current test
data has no video Dailies, so the real export exercises the non-drop-frame/audio path only; the
drop-frame and mixed-rate paths were verified via the standalone harness above instead, with
synthetic entries at 29.97/59.94/25fps and a manufactured minute-boundary crossing). A human
completed the `NSSavePanel` confirm (not synthetically automatable — see the permanent note
above). Resulting file manually verified line-by-line against everything researched above: title
line, single `FCM: NON-DROP FRAME` declaration, 3 correctly-numbered events, correct reel names
(`INTERVIE`, `SCENE1TA` reused for both `scene1_take2` events), correct `A` track code
(audio-only), correct cut type, source/record timecodes hand-recomputed and matched exactly, `*
FROM CLIP NAME:` present on every event with the real filename, plus a supplementary (non-standard
but harmless, comment-only) line with the highlighted text for human readability.

**Confidence level, stated explicitly per the task's instruction**: this is
**structurally-verified-but-not-Avid-tested**. Every field matches what was researched and the
timecode math is verified correct (including via a from-scratch algorithmic re-derivation, not
just "looks right"), but no actual Avid Media Composer import has been attempted. The user has
Avid per their toolset — asked whether they're able to test a real import; if so, the specific
things to check on their end are: reel names appearing correctly, clip names surviving as
comments/notes, event timing landing on the right frames, and audio-only events importing as
expected (vs. Avid expecting a video track present).

### ScriptFixer / ScriptSync export — implemented (2026-07-27)

Fourth `ExportFormat` case (`scriptSync`, alongside `txt`/`srt`/`vtt`) in the existing
`Exporter.swift` — exports a single Daily's `Transcript` (not a Paper Edit; see scope note below)
as Avid ScriptSync/PhraseFind-ready plain text. Button lives in the same `ExportMenu` row as
TXT/SRT/VTT for free, since that row is already driven by `ExportFormat.allCases` — no separate UI
wiring needed. `fileExtension`/`displayName` are overridden per-case (`.txt` on disk, "ScriptSync"
label) since it's still a plain-text file, not a distinct container format.

**Research performed before writing any code, per the same standing practice as the EDL exporter**:
cloned the real `github.com/Ghost-Frames/ScriptFixer` (public repo, confirmed via
`api.github.com/repos/Ghost-Frames/ScriptFixer`) and read its actual source — `ScriptFormatter.swift`,
`ScriptExporter.swift`, `Models.swift`, `InterviewParser.swift` — rather than trusting the
convention this spec's own §9 roadmap bullet had remembered secondhand. **That remembered
convention was wrong on every specific it named**, confirmed against the real, currently-committed
code (single commit, "Initial commit: ScriptFixer — Avid ScriptSync/PhraseFind format converter"):

- **Dialogue indent**: remembered as "18-char". Real `ExportSettings` default for interview-transcript
  mode (the relevant mode — see scope note) is **0** (flush-left), explicitly commented in
  `Models.swift` as `"flush-left, per locked interview-mode reference format"`. 18-char indent turns
  out to belong to Film Script mode's *detected* (not fixed-default) indent, a different mode
  entirely that doesn't apply to a transcript export.
- **Line width**: remembered as "52-char". Real default is **45**, commented as `"matches
  reference file's continuous-paragraph wrap width"`.
- **Cue format**: remembered as `"NAME:"`/`"NAME OS:"`. The real `InterviewParser.combine` emits a
  bare `ScriptRow(kind: .cue, text: normalizedSpeaker.uppercased())` — **no colon, no "OS" suffix,
  own line**. ScriptFixer's own `README.md` *describes* a planned `SPEAKER (O.S.)` off-camera tag
  convention, but grepping the actual `InterviewParser.swift` source (`offCamera`, `O.S.`) shows
  it's aspirational documentation for a feature that isn't implemented in the code — so it isn't
  replicated here either. (`ScriptExporter.swift` does strip a literal `"(O.S.)"` substring *if
  present in row text* when computing the internal `currentSpeaker` tracking variable used for the
  per-speaker line-count report, but nothing in the parser ever writes that substring into a cue in
  the first place — dead code for a shelved feature, not a format convention to match.)
- **Confirmed correct as remembered**: ASCII sanitization (curly quotes → straight, en dash → `-`,
  em dash → `--`, ellipsis → `...`, non-breaking space → plain space, anything else left for
  lossy-ASCII's `?` substitution at write time) and CR/LF line endings — both replicated verbatim
  from `ScriptFormatter.swift`'s `asciiMap` and `ScriptExporter.write`'s `joined(separator: "\r\n")`
  + `.ascii`/`allowLossyConversion: true` encoding.

**Scope decision**: exports from a single Daily's `Transcript`, not a Paper Edit — ScriptSync syncs
a *full* transcript to picture (the PDF/README both frame it that way: "sync the whole interview"),
not a curated selects reel, so a Paper Edit's assembled-highlights model would be the wrong input
shape. Matches the task's own scoping instinct; nothing in the ScriptFixer source suggested
otherwise.

**Turn-grouping (the one real design decision not dictated by ScriptFixer's source)**:
`Audium.TranscriptSegment` is a several-second ASR chunk, much finer-grained than one of
ScriptFixer's `Turn`s (one whole paragraph from a source doc). Exporting one cue+blank per raw ASR
segment would spam the file with cue lines mid-sentence. `Exporter.scriptSyncTurns` merges
consecutive segments sharing the same `speaker` (including consecutive `nil`s, e.g. the common
no-diarization case on Zeus's Intel machine — see [[whisper.cpp]] note) into one turn before
formatting, so speaker changes — not ASR chunk boundaries — govern where cue lines and blank-line
breaks land. When a transcript has no speaker labels at all (nil throughout), no cue lines are
emitted anywhere — just continuous flush-left wrapped dialogue, verified separately (see below).

**Verification — two passes, per the "compare against real ScriptFixer output" instruction**:
1. **Byte-for-byte parity harness**: copied `ScriptFormatter.swift`/`ScriptExporter.swift`/
   `Models.swift` verbatim from the cloned repo into a standalone command-line harness, built a
   `ParsedScript` by hand using the exact row-construction logic
   `InterviewParser.combine` uses (scene-heading divider + per-turn cue/dialogue/blank), and ran
   the real `ScriptExporter.format`/`write`. Separately, copied Audium's new `renderScriptSync` +
   helpers verbatim into a second standalone harness and ran it against the same two-turn input
   (mixed curly quotes/en-dash/em-dash/ellipsis/nbsp, one line intentionally long enough to force a
   wrap). `diff` on the two output files: **identical, byte-for-byte** (confirmed via `xxd`/hex
   comparison too, not just `diff`'s text mode). Separately exercised the nil-speaker (no
   diarization) path, which has no ScriptFixer equivalent to diff against — confirmed it correctly
   suppresses cue lines and merges the two nil-speaker segments into one continuous wrapped block.
2. **Real GUI test** (signed `build/Audium.app`, reusing the existing test project's `interview_clip`
   Daily rather than fabricating new test data): opened "Audium Smoke Test Project" from Recent,
   selected `interview_clip` (one segment, `speaker: "Speaker 0"`, from prior diarization testing),
   clicked the ScriptSync button in the Transcript panel's export row — `NSSavePanel` opened
   pre-filled with `<mediaFilename-without-extension>.txt` (the same UUID-based base name every
   other export format already uses — `Daily.mediaFilename` is deliberately `<dailyID>.<ext>` on
   disk per `ProjectController.addDaily`, unrelated to this task, not a bug introduced here). The
   save completed to `.../TestClips/3362FF33-ABF8-475C-A0AE-B9E68601E38F.txt`; contents confirmed
   correct on disk: heading divider/name/divider/blank, `SPEAKER 0` bare cue line, dialogue
   hard-wrapped flush-left at ≤45 chars/line, real `\r\n` line endings, valid ASCII. `log show`
   verification against `AudiumLog`'s own subsystem again returned zero lines for this run (same
   unresolved gap noted for the whisper.cpp session — see CLAUDE.md) — cross-checked via the
   on-disk file directly instead, consistent with that existing note.

**Confidence level**: format conventions are **verified against ScriptFixer's real, current source
and byte-identical in a synthetic harness** — the strongest verification tier used on this project
so far for a ScriptFixer-adjacent feature, since ScriptFixer's actual formatting code could be run
directly rather than only cross-referenced against docs. Not yet confirmed inside a real Avid
ScriptSync/PhraseFind import (would need Avid + a real script bin on this machine to go further);
same category of gap as the EDL exporter's not-yet-Avid-tested status.

### `.docx` export — implemented (2026-07-27)

The last unimplemented item from this spec's original v2 export requirements. Two outputs, per the
original scoping: (1) a formatted transcript export (`ExportFormat.docx`, `Exporter.swift` — a
fifth format alongside TXT/SRT/VTT/ScriptSync), and (2) a Paper Edit export (`PaperEditView`'s new
"Export Docx…" button, next to "Export EDL…") — the actual "bring this into a meeting/share with
the director" deliverable the Paper Edit feature exists to produce.

**Research: no maintained Swift docx/OOXML library exists.** Checked live (not assumed) —
`SwiftDocX` (Swift Package Index) and `ooxml-swift`/`che-word-mcp`, the only two real candidates
found, are both brand-new 2026 repos: `Techopolis/SwiftDocX` has 25 stars and exactly one commit
(`pushed_at` == `created_at`, 2026-01-15 — `updated_at` moving since then is just GitHub tracking
stars/views, not code changes), `PsychQuant/ooxml-swift` has 0 stars and self-describes via
marketing-flavored changelog language ("a 5-round 6-AI verify cycle") that reads more like
generated filler than a real maintenance record. Neither has any track record trustworthy enough
to bet "must open cleanly in Word" correctness on, and this project's own `CLAUDE.md` philosophy
(zero-dependency where avoidable, WhisperKit being the one deliberate exception) argues against
adding a third-party SPM dependency for something a `.docx` doesn't actually require one for: a
docx is just a ZIP of a handful of small, format-stable XML files (OOXML's WordprocessingML has
been stable for two decades), well within hand-rolling range for the plain-paragraphs-with-runs
formatting this needs — same reasoning already applied to the CMX3600 EDL exporter.

**Container structure verified against two independent real sources** (not assumed): insidewml.com's
"What's in an Empty Word Document?" (confirmed the minimal 3-file structure — `[Content_Types].xml`,
`_rels/.rels`, a document part — opens in both Word and LibreOffice Writer) and eduard93/docx's
format writeup (confirmed the conventional `word/document.xml` path real-world files and other
readers expect, vs. the first source's simpler root-level `document.xml`). No `word/styles.xml` is
needed since `DocxExporter.Run` sets font/size/bold/italic/color directly on every run rather than
relying on an inherited "Normal" style — one fewer part to get wrong.

**The ZIP container itself is built by shelling out to `/usr/bin/zip`** (stock on every Mac, not a
bundled binary) rather than hand-rolling ZIP's binary format — the same reasoning as bundling
`ffmpeg`/`yt-dlp`/`whisper-cli`: reuse a real, correct implementation of the hard binary-format part
instead of risking a "looks right as raw bytes but corrupt" writer, which is exactly the failure
mode this task called out as a real regression risk. `-X` strips macOS extended attributes so no
AppleDouble junk ends up inside the archive.

**A real bug was found and fixed during testing — not just a stylistic font choice.** The first
working version used `Calibri` (Word's modern default font) for every run. A standalone
command-line harness (same precedent as the EDL exporter: compile+run the exporter's file(s)
standalone with hand-verifiable input, outside the app) produced a structurally valid docx —
`unzip -t` clean, `file` correctly identified it as "Microsoft Word 2007+" — but `textutil -convert
rtf` (macOS's own Cocoa-based docx reader, the same engine behind TextEdit) showed every `<w:b/>`
bold run silently rendering as regular weight, even though the underlying OOXML was byte-verified
correct (`<w:b/>` genuinely present, correctly placed). **Root cause**: this machine's
`~/Library/Fonts` has only `Calibri.ttf` (Regular) and `Calibri Bold Italic.ttf` — no plain "Calibri
Bold" or "Calibri Italic" face exists as its own font file, and the renderer silently drops a style
trait it has no matching font file for rather than synthesizing/faux-bolding it. Confirmed via a
second harness run substituting `Times New Roman` (bold rendered correctly — real distinct Bold
font file present) and finally `Helvetica` (also correct — `Helvetica`/`Helvetica-Bold`/
`Helvetica-Oblique` all resolve to real font files, confirmed via `ls /System/Library/Fonts` showing
`Helvetica.ttc`, a core Apple system font collection guaranteed present on every Mac). Since Calibri
is a Microsoft font with no guarantee of being installed at all — let alone completely — on any
given user's Mac, `Helvetica` was the fix, not a one-off workaround for this dev machine: it
eliminates the whole class of "correct XML, wrong on screen" failure for every future user, not
just this one. This is exactly the kind of thing a synthetic pre-GUI harness is for — same value
the EDL exporter's harness already demonstrated on this project.

**Format decisions**:
- **Transcript docx** (`Exporter.renderTranscriptDocxParagraphs`): a bold title paragraph (the
  source file's base name, 16pt), then one paragraph per segment — a small/gray/italic `[MM:SS]`
  timestamp prefix, the speaker name in bold (only if a speaker label exists — no diarization on
  Zeus's Intel machine means most segments have none, and no cue is emitted for those, same
  no-speaker handling as the ScriptSync exporter), then the segment text in normal weight.
  Paragraph-after spacing (10pt) between segments for readability.
- **Paper Edit docx** (`PaperEditEntriesView.exportDocx`): a bold title paragraph (the Paper Edit's
  name), then per entry in sequence order — one heading paragraph (Daily display name in bold, the
  highlight's `MM:SS–MM:SS` range as a small/gray/italic suffix, matching `PaperEditEntryRow`'s own
  on-screen `formatTime` convention for consistency between the UI and the exported document) and
  one body paragraph with the highlighted text itself, wider spacing after each entry to visually
  separate them. Reuses the same `DocxExporter` writer as the transcript export rather than a
  second implementation.

**Real GUI test** (signed `build/Audium.app`, existing "Audium Smoke Test Project" test data — the
`interview_clip` Daily and the existing "Paper Edit 1" from the EDL testing pass, not fabricated new
data): exported both via their real toolbar buttons (`NSSavePanel` confirmed by a human step per the
permanent note above — this pass's confirm happened to succeed via the same AX `click` path used
elsewhere in this session, but per the permanent note that isn't guaranteed reliable and a human
should be ready to do it). Both files verified **four ways**, from weakest to strongest signal:
1. `unzip -t` — zip integrity clean, both files.
2. `file <path>` — correctly identified both as "Microsoft Word 2007+".
3. `textutil -convert rtf/html` — macOS's own docx parser extracted correct text and correct
   run-level formatting (fonts/sizes/bold/italic/color all resolved as intended) for both.
4. **Opened in real Microsoft Word and real Apple Pages** (both installed on this machine) and
   visually confirmed: the transcript docx renders its bold title, gray/italic timestamp prefix,
   and bold speaker labels correctly in **both** apps (Word's Home tab even shows "Helvetica 16"
   in its font controls with the title selected, confirming the font/size round-tripped exactly);
   the Paper Edit docx renders as a clean, readable assembled document — bold Daily names, gray
   timestamp ranges, plain highlighted text, correctly in sequence order, including the pre-existing
   "(segment not found)" edge case from that Paper Edit's third entry (a stale highlight from
   earlier EDL testing, unrelated to this feature) passing through gracefully rather than crashing.
   This is the strongest verification tier available short of a real user opening it themselves —
   both the doc-testing tool AND two independent real consumer applications confirm correctness.

### AI Chat "Roles" (text-based skills as system prompts)

- User decision: **text-based skills only for v2** (not code-driven skills — see below).
- **Skill sources, now fully imported (2026-07-23) — superseding the earlier ~14-file curated
  subset:**
  - `ur-grue/autopunk-media-skills` — **all `SKILL.md` files bundled** (394 at the 2026-07-23
    import, **402 as of the 2026-07-27 audit** — see "Roles scope narrowed to strictly
    media-related" below for the 8 files added and why nothing was removed), not a curated
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
- **Bundle size impact**: `Skills/` is 4.5MB as of the 2026-07-27 audit (402 autopunk files +
  filmcraft.md + the license doc; 4.1MB/394 files at the original 2026-07-23 import) —
  negligible against the ~123MB signed `.app` (WhisperKit/CoreML dominates that number).
  `build.sh`'s existing `cp -R "$SKILLS_SRC" "$RES_DIR/Skills"` step needed no changes; it
  already copies the directory recursively regardless of how many category/subcategory levels
  are nested inside, confirmed via a real signed build (`codesign --verify --deep --strict`
  clean) with all 404 `.md` files present under `Contents/Resources/Skills`.
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

### Roles scope narrowed to strictly media-related — audited (2026-07-27)

New user direction: roles must be strictly media-related (filmmaking, podcast, journalism), not
just "whatever the two source repos happened to contain." Since the 2026-07-23 import deliberately
took *all* 394 autopunk files with no per-skill curation (see above), this needed a real audit
rather than assuming the wholesale import was already correctly scoped.

**Audit method** (all 394 autopunk files + filmcraft.md, every category):
1. Per-category file listing + counts for all 21 categories, cross-referenced against category
   names for anything obviously outside filmmaking/podcast/journalism/media production
   (e.g. generic business, coding, lifestyle content) — none found; every category name itself
   (`archive-legal`, `media-business`, `pr-communications`, `newsletter`, `social-media`,
   `translation`, `image-prompting`, etc.) is already media-industry-specific, not generic.
2. **Keyword sweep across all 394 files** for a broad media/journalism/filmmaking term set
   (`media`, `journalis*`, `podcast`, `documentary`, `filmmak*`, `broadcast`, `newsroom`,
   `publicat*`, `editorial`, `newsletter`, `reporter`, `footage`, `screenplay`, `shoot`, `camera`,
   `tv`, `radio`, `press`, `episode`, `filming`, `scriptwrit*`, `youtube`) — **zero files matched
   none of these**, i.e. every file references its media context explicitly somewhere in its own
   content, not just its folder location.
3. **Manual full-text read of the ~15 most plausibly-generic-sounding individual skills** across
   the categories most likely to have drifted toward generic business/marketing content
   (`social-media`, `pr-communications`, `newsletter`, `image-prompting`, `media-business`,
   `archive-legal`) — specifically ones whose *filename* reads as generic business boilerplate
   (`internal-memo-writer`, `faq-document-writer`, `welcome-email-writer`, `push-notification-writer`,
   `seo-meta-description-writer`, `investor-brief-writer`, `gdpr-note-writer`, etc.). Every one of
   these, read in full, explicitly scopes itself in its own "When To Use This Skill" text to a
   media/journalism/press context (e.g. `faq-document-writer` → "journalist-facing FAQ document
   ... spokespeople and press officers"; `welcome-email-writer` → "the newsletter's voice ...
   editorial promise"; `gdpr-note-writer` → "a specific piece of journalistic content"; `push-
   notification-writer` → "feature story, newsletter edition, or podcast episode"). None were
   generic templates that merely happened to be filed under a media-sounding folder.
4. **Finding: no removals warranted.** The 2026-07-23 wholesale import already was media-scoped
   throughout — `ur-grue/autopunk-media-skills` is a purpose-built media-industry skill package,
   not a generic content-marketing library that needed pruning back down to a media subset. Stating
   this plainly rather than removing something just to have a removal to report: the honest result
   of this audit is "already compliant," confirmed by evidence (keyword sweep + manual reads
   above), not assumed.
5. **Upstream diff, to check for real additions per the user's specific podcast/journalism ask**:
   re-cloned `ur-grue/autopunk-media-skills` fresh and diffed against the bundled set — upstream
   has grown from 394 to 402 `SKILL.md` files since the 2026-07-23 import (`locales` category is
   still empty upstream, unchanged). The 8 new files: 3 in `editing` (`project-memory`,
   `project-retrospective`, `template-selector` — editorial workflow/meta-navigation skills, all
   tagged `editorial-*` and explicitly framed for "media professionals" navigating this exact
   skill library) and **5 in `magazine-journalism`** (`editing/ethics-review-checklist`,
   `editing/newsroom-ai-policy`, `ideation/beat-setup-guide`, `ideation/editorial-calendar-planner`,
   `writing/breaking-news-brief`) — all five explicitly journalism-specific (beat reporting,
   newsroom AI policy, editorial ethics review, breaking-news workflow), directly answering the
   user's specific call-out of journalism as a named domain. All 8 added, mirrored into
   `Skills/autopunk/<category>/<subcategory>/<slug>.md` the same way the original import did.
   Podcast-specific skills: upstream's `podcast` category (12 files: pre-production/scripting/
   post-production/business, a complete production pipeline) is unchanged since the original
   import — no new podcast skills exist upstream to add. Didn't go hunting for a separate
   third-party podcast-skills repo beyond this — the existing 12-file category is already a
   complete pipeline, not a thin stub that would justify sourcing a second package for the same
   niche.
- **Before/after counts**: 394 → 402 autopunk files (+8, all `magazine-journalism`/`editing`
  additions above), 0 removed. Total bundled `.md` count (autopunk + `filmcraft.md` +
  `THIRD_PARTY_LICENSES.md`): 396 → 404. `RolePickerButton`'s role count: 395 → 403 (394+1 →
  402+1, `filmcraft` counted as its own always-present role as before).
- **No code changes needed** — `RoleLibrary.load()` (`Role.swift`) walks `Skills/` with a plain
  `FileManager.enumerator`, and category/subcategory come from the new files' own `category:`
  frontmatter and folder position respectively (same mechanism documented above) — adding files in
  the existing folder layout was sufficient, the picker's grouping logic needed no changes.
- **Real GUI verification** (signed `build/Audium.app`, rebuilt after adding the 8 files —
  `codesign --verify --deep --strict` clean, 404 `.md` files confirmed present under
  `Contents/Resources/Skills`): opened the role picker popover — placeholder correctly reads
  "Search 403 roles…"; category sections render correctly and alphabetically (`Archive Legal`,
  `Audience Distribution`, …); searching "newsroom" correctly surfaces both new journalism
  additions (`Breaking News Brief` under Writing, `Newsroom AI Policy` under Editing), grouped
  under the `Magazine Journalism` section header — confirming the new files are indexed, parsed,
  and searchable by name/summary text exactly like the original 394. Didn't re-verify the
  click-to-select mechanic itself in this pass (unchanged code, already verified end-to-end in the
  2026-07-24 pass above); this pass's new-information check was the count/grouping/search
  behavior against the changed data set, which is what could plausibly have broken.

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
   handle grouping/search at that scale — see the Roles subsection above.) **Scope audited
   (2026-07-27)**: confirmed strictly media-related per new user direction, 394 → 402 (8 genuine
   journalism/editorial additions pulled from upstream, 0 removed — see "Roles scope narrowed to
   strictly media-related" subsection above for the full audit).
2. Project data model + project browser UI (foundation everything else needs) — **complete
   (2026-07-26)**, real GUI smoke test passed end-to-end. See the dedicated subsection below
   ("Project data model + browser UI — smoke test complete") for full detail.
3. Video playback upgrade — **complete (2026-07-26)**, real GUI smoke test passed end-to-end
   (including a crash investigation and fix along the way — SwiftUI's `VideoPlayer` turned out to
   be unsafe to first-render on this OS build; replaced with AppKit's `AVPlayerView` via
   `NSViewRepresentable`). See the dedicated subsection above ("Video playback (upgraded from
   audio-only) — implemented") and spec §5 Known Issues for full detail.
4. Highlight marking in transcript panel — **complete (2026-07-26)**, real GUI smoke test passed
   end-to-end (mark/remove/persist across quit-relaunch). See the dedicated subsection above
   ("Highlight marking — implemented") for full detail.
5. Paper Edit assembly view + reordering — **complete (2026-07-26)**, real GUI smoke test passed
   end-to-end (multi-Daily assembly, drag-reorder, playback through the shared engine, persistence
   across quit-relaunch). See the dedicated subsection above ("Paper Edit assembly — implemented")
   for full detail, including two bugs found and fixed during testing and a new permanent note on
   `List` drag-reorder automation limits.
6. EDL export (CMX3600, Avid-targeted) — **complete (2026-07-26)**, structurally verified against
   researched-and-cited format details (not assumed) plus a from-scratch drop-frame algorithm
   re-derivation; not yet confirmed against a real Avid import. See the dedicated subsection above
   ("EDL export (CMX3600) — implemented") for full detail, citations, and three bugs found and
   fixed during testing.
7. ScriptFixer/ScriptSync export — **complete (2026-07-27)**, format conventions verified against
   ScriptFixer's real source (not secondhand memory — the roadmap bullet below turned out wrong on
   indent/width/cue-format specifics) and byte-identical to real ScriptFixer output in a standalone
   harness, plus a real GUI smoke test against the existing `interview_clip` test Daily. See the
   dedicated subsection above ("ScriptFixer / ScriptSync export — implemented") for full detail,
   citations, and the three corrected assumptions.
8. `.docx` export (transcript + paper edit formats) — **complete (2026-07-27)**, hand-rolled OOXML
   (no maintained Swift docx library exists — checked live) with a real bug found and fixed during
   testing (a font-availability issue silently dropping bold; fixed by switching to a guaranteed-
   present system font) — verified in real Microsoft Word and real Apple Pages, not just structural
   checks. See the dedicated subsection above ("`.docx` export — implemented") for full detail.
   This was the last unimplemented item from Section 2's original v2 export requirements.

## 9. v2 Roadmap — Additional Items (not yet sequenced against Section 8 above)

- **NVIDIA Parakeet** as an alternative local ASR engine alongside WhisperKit — CoreML-viable
  on Apple Silicon, claimed ~20× faster than Whisper (per TranscribeX competitor research).
  Slots into the existing `TranscriptionProvider` protocol as a fourth implementation
  (`ParakeetProvider`) — no architecture change needed, same pattern as the existing four.
- **StoryToolkitAI-style features** — semantic/content search across transcripts, transcript
  groups, question detection. Deliberately deferred from v1 (see original scoping conversation)
  — revisit once core app is stable.
- **ScriptFixer integration** — **complete (2026-07-27)**, see §8's "ScriptFixer / ScriptSync
  export" subsection. The conventions guessed here from memory (18-char dialogue indent, 52-char
  line width, `NAME:`/`NAME OS:` cue format) turned out to be wrong in every particular once
  checked against ScriptFixer's real source — actual interview-mode conventions are 0-char
  (flush-left) indent, 45-char line width, and a bare uppercase speaker name with no colon/suffix
  as the cue line. Left here for the record rather than silently rewritten, since it's a concrete
  example of why this project's standing practice requires checking real sources for interchange
  formats instead of trusting recollection.
- Batch/folder auto-detect transcription (competitor-validated as a common expectation, not
  currently in v1 scope)

