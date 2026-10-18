# Typical Talk for iOS

The native SwiftUI app built from `spec/BRIEF.md`, `spec/DESIGN.md` and the
Google Stitch screens mounted in the web demo at the repository root.

Requires Xcode 27 and iOS 26 or later. Open `TypicalTalk.xcodeproj` and run.

## Structure

- `TypicalTalkApp.swift`, `RootView.swift` — the four locked tab items
  (Talks, Record, Archive, You). Archive takes `Tab(role: .search)`; Record is a
  pass-through that expands into the recorder via a zoom transition.
- `Design/Theme.swift` — the palette. Exactly one tint, on the record action.
- `Models/`, `Store/AppStore.swift` — talks, messages, transcripts, chapters,
  bookmarks, and the on-device search over them.
- `Features/Talks/` — the list, the notifications bell, and Friends
  (handles and `ShareLink` invites, no contact matching).
- `Features/Thread/` — the cinematic thread, the glass playback toolbar,
  chapter scrubber, tappable transcript, and speed detents.
- `Features/Recorder/` — `AVCaptureSession` capture, framing guides, hands-free
  countdown, the retake strip, and the destination picker.
- `Features/Archive/`, `Features/You/` — search, bookmarks, highlights,
  settings, and storage.
- `Store/AppStore.swift` — the one store. It mirrors the server into
  `state.json` in Application Support, so the app opens instantly and works
  offline, and merges `GET /v1/talks` into it.
- `Services/TransferManager.swift` — uploads and downloads on a background
  `URLSession`, so a send survives leaving the app. Takes are named by a
  client chosen id, which makes a retried upload harmless.
- `Services/TakeFiles.swift` — where takes live on disk.
- `Services/Push.swift` — APNs registration and the app delegate.
- `Services/Transcriber.swift` — on-device transcription through the iOS 26
  `SpeechAnalyzer` and `SpeechTranscriber`. Nothing leaves the phone.

## Liquid Glass

Glass is confined to the navigation layer and is never stacked: the tab bar,
the playback toolbar, the recorder HUD and control bar, and the floating reply
pills. Content cards are flat. `Glass.clear` appears only over media, always
with a dimming scrim. All of it is `glassEffect` and `GlassEffectContainer`
from the iOS 26 SDK, verified against the installed SDK interfaces.

## Known limits

- The Simulator has no camera, so the recorder shows its voice-only state
  there. Video capture needs a real device.
- Transcription downloads a language model the first time it runs, and returns
  nothing if the model or permission is unavailable. Sending a take never
  blocks on it.
- Push needs an APNs key set as a Worker secret (see `server/README.md`).
  Without it the app still syncs: on launch, on returning to the foreground,
  and every twenty seconds while open.
