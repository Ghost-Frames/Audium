# Audium

Native macOS transcription app (WhisperKit/Gemini/OpenAI transcription + multi-provider AI
chat), built zero-dependency/no-Xcode like the other Ghost-Frames tools.

Always read `docs/spec.md` first, before investigating or changing anything. Check its
"Known Issues" and "Resolved" sections (Section 5) before re-diagnosing something that may
already be documented there — several past issues (Keychain ACL bugs, WhisperKit model-lookup
errors, provider-default wiring) look like new bugs on first encounter but are already root-caused
there.
