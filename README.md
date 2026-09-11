# Typical Talk

Async video messaging, reimagined. Web demo of the Typical Talk iOS app concept.

- **Talks** — one-to-one and group conversations, newest first, large playable previews; **Find friends** via contacts with an invite flow lives here
- **Thread** — cinematic vertical message thread with speed control, transcript, chapters, bookmarks, reactions
- **Record** — tinted primary action; real camera capture via `getUserMedia` + `MediaRecorder`; record takes and send them into the thread as playable video
- **Archive** — on-device transcript search, bookmarks, highlights
- **You** — profile and app settings (no settings tab on the bar)
- Floating Liquid Glass bottom tab bar: Talks / Record / Archive / You

The demo opens in an iPhone portrait frame. Open `index.html` in a secure context (HTTPS or localhost) and allow camera/microphone access to test recording.

Built from Google Stitch screens, mounted in a phone viewport with a shared floating tab bar.

## Spec

The full product spec we planned lives in `spec/`:

- `spec/BRIEF.md` — decision graph, locked decisions, sequencing, pricing notes
- `spec/DESIGN.md` — product/UX design draft, including the 2026-09-10 web demo build decisions
- `spec/glass-spec/` — Liquid Glass reference specs (SwiftUI, CSS/SVG, tabs, adoption guide)
