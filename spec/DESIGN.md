# Typical Talk — Product/UX Design Draft
Working draft for chat review, 2026-09-09. Everything here derives from the resolved decision graph in BRIEF.md.

## Identity
**Typical Talk.** Async video messaging, done right: telephone ease, FaceTime warmth, none of the clunk. iOS-first, web companion, Android later as a web-derived app.

## Principles (locked)
1. Convenience beats fidelity. Recording must be startable with one hand or no hands; production quality is not the point.
2. Video is visually primary. Large, cinematic, never tiny thumbnails.
3. The archive is a product, not a graveyard. Every video is transcribed on-device, searchable, bookmarkable, summarizable.
4. Power features are free. Transcripts, speed, chapters, summaries, search, bookmarks cost nothing to give; only storage/sync may ever cost anything (pricing discussion deferred).
5. Liquid Glass done right (WWDC25 Sessions 219/323): glass only in the navigation layer, never stacked, regular glass default, clear glass only over media with a dimming scrim, tint only the record action, morphing transitions (no pops), monochrome toolbar icons.

## Proposed tab structure (iOS)
Glass tab bar, three tabs, floating tinted record button at center:
1. **Talks** — conversation list. 1:1 and groups. Rows are flat content with large video previews (newest message as a playable preview, not a thumbnail). Unread state is obvious at a glance. Subtle presence line under active threads ("Maya is watching"). A notification bell in the header covers reactions, mentions, and watch receipts (folded from the old Activity tab, 2026-09-09: the distinction didn't earn a tab).
2. **Archive** — dedicated search tab (Tab role .search, .searchable). Full-text search across on-device transcripts, bookmarks shelf, auto-generated highlights reel per thread and global.
3. **You** — profile, settings, storage management, notification prefs.

## Conversation view
- Cinematic thread: large video messages in a vertical flow, newest at the bottom (chat convention).
- Tap a video: plays inline with a glass playback toolbar — speed slider (tick marks, neutralValue), transcript toggle, chapters on the scrubber, bookmark button, share/react.
- Catch-up summary pinned at top of threads with unread backlog: "12 new videos, about 4 minutes. Maya's birthday plans are finalized." Generated on-device.
- React with quick emoji; reply with video or voice-only Talk.
- Watching-now presence: quiet line under the thread title, never a popup.

## Recorder (the morphing sheet)
- Floating tinted record button (the only tinted element in the app) expands into the recorder via navigation-zoom morph (Session 323). No pop-in.
- One tap to start, one tap to stop. Big stop target for one-hand use.
- Hands-free mode: start, then operate by voice ("stop") or a anywhere-tap; designed for propping the phone up.
- Framing guides: rule-of-thirds + face-centering overlay, subtle, dismissible.
- Retake stack: after stopping, swipe through takes, keep the best, delete the rest. Sending is a separate, deliberate tap: choose thread(s), send.
- Voice-only Talks: same sheet, camera off, waveform instead of viewfinder.

## Player details
- Speed: 0.75x–2x slider with tick marks, double-tap-hold for momentary fast-forward (platform convention).
- Auto-chapters: on-device segmentation shown as scrubber segments with labels.
- Transcript: on-device, toggleable panel under the video, tappable words seek.
- Bookmarks: one tap during playback, collected in Archive.

## Effects and extras (full feature set, not dog shit)
- Marco Polo's effects/voice filters survive but tasteful: a small, curated set, previewable live, never the main event.
- Text overlays, doodles: keep, simplified.

## Web companion
- Echoes the iOS design language. No Liquid Glass mimicry (Apple-only material); use flat surfaces and scrims.
- Scope (locked 2026-09-09): full-featured to the capabilities of the web. Everything the browser can do (watch, search, reply, record via browser capture APIs), just not as good as iOS. No artificial feature gating on web.

## Groups
- Adopted as-is from Marco Polo's model (locked 2026-09-09, Aniket: "sounds fine"): create from the Talks menu, members from phone contacts, name up to 25 characters, flat shared thread, no admins or roles, one group per circle. Plus-era scratchpad for drafting replies included in the free core (it costs nothing to give).

## Resolved shaping decisions (2026-09-09)
1. Notifications: a notification bell in the Talks header showing all notifications (reactions, mentions, watch receipts, who's watching). No separate Activity tab.
2. Ordering: newest at the top, everywhere. Talks list and inside threads.
3. Web companion: full-featured to the capabilities of the web, no artificial gating.
4. Groups: Marco Polo's flat model, adopted as-is (see above).

## Web demo build decisions (2026-09-10)

1. Tab bar (locked): exactly four items, Talks / Record / Archive / You. Record is the tinted primary action. No Settings tab; app settings live in You. Marco Polo's Home / Invite / For You / Settings layout was reviewed and explicitly rejected.
2. Find friends (added 2026-09-10): find friends via contacts plus an invite flow, placed in the Talks area (a Talks / Find friends segmented control), never a tab. Contacts-sync prompt, suggested contacts with Invite and Skip actions, invite-link share option, honest empty states.
3. Web demo: opens in an iPhone portrait frame (390x844) by default, centered on larger screens. Real camera capture through getUserMedia + MediaRecorder (preview, record, retake, send to thread as playable video). Find friends uses simulated contacts in the web build; the native app will use real device contacts.
4. UI audit (2026-09-10): full pass over every button, icon, text animation, and layout against the Liquid Glass philosophy (glass in the nav layer only, never glass on glass, dark warm cinematic, smooth animated transitions, no popping). Broken controls repaired, false/stale data removed, inert state transitions fixed.
