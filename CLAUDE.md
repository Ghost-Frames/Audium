# Audium

Native macOS transcription app (WhisperKit/Gemini/OpenAI transcription + multi-provider AI
chat), built zero-dependency/no-Xcode like the other Ghost-Frames tools.

v1 (transcription core) is feature-complete and pre-release-cleaned. v2 is underway: pivoting
toward a project-based story-editing tool — screen dailies, transcribe, mark highlights, and
assemble a paper edit without opening Avid/Premiere/Resolve. See `docs/spec.md` Section 8 for
the full v2 architecture (Project/Daily/Highlight/Paper Edit data model, video playback, docx
export, AI Chat "Roles").

Always read `docs/spec.md` first, before investigating or changing anything. Check its
"Known Issues" and "Resolved" sections (Section 5) before re-diagnosing something that may
already be documented there — several past issues (Keychain ACL bugs, WhisperKit model-lookup
errors, provider-default wiring) look like new bugs on first encounter but are already root-caused
there.

**Standing practice (as of 2026-07-23): Claude Code owns updates to `docs/spec.md` and this
file directly** after every task — not just reporting changes back for the user to relay
through Claude.ai. Update both yourself, same level of detail as the existing entries, before
considering a task done.
