# edith:map — Reimagining Marco Polo

## Destination
A shipping-quality reimagining of Marco Polo (async video messaging) that pushes the concept somewhere new: designed idea-first in this chat, then business model, then Google Stitch screens (MOBILE), then a built artifact. Native iOS feel, Liquid Glass per WWDC25 Sessions 219/323 transcripts, dark mode, full-width layouts, smooth animated transitions, no em dashes in copy.

## Notes
- Domain: async video messaging ("video walkie-talkie") by Joya Communications. Record a video message, the other person watches when convenient and replies in kind.
- Standing: scope DECIDED 2026-09-09 = push the concept somewhere new, not a faithful rebuild.
- Sequencing constraint (Aniket 2026-09-09): design idea-wise first, business model only after design is settled, Stitch only once everything is decided. No money talk until then.
- Key insight (locked): localize to kill cloud costs. Transcripts on-device (iOS Speech framework / Live Captions style), speed controls client-side, bookmarks/notes local data. Charge only for what actually costs server money (storage, sync).
- Grilling tickets: ask Aniket directly and wait. Research tickets: resolve unattended, can run in parallel. Never start coding while a ticket is open. Never resolve more than one Grilling ticket per session.

## Decisions so far (resolution order)
1. A1 (2026-09-09): Scope = push the concept somewhere new. Forced by Aniket, auto-resolved.
2. A2 (2026-09-09): Power features (speed controls, transcripts, bookmarks, search) free and on-device; paywall only for cost-bearing items. Forced by the localize-to-kill-cloud-costs insight, auto-resolved. Pricing details deferred.
3. A3 (2026-09-09): Liquid Glass per WWDC25 Session 219 + 323 transcripts. Glass = tab bar, floating record button, playback toolbar (one GlassEffectContainer). Thumbnails get Clear with dimming scrim + bold glyphs. Lists/sheets Regular and flat. Exactly one tint: the record action. Dedicated search tab for the archive. Speed = slider with tick marks + neutralValue. Sheets morph out of their trigger. Monochrome toolbar icons. No glass on glass.
4. A4 (2026-09-09): Work sequence = design → business model → Stitch screens → artifact build. Forced by Aniket, auto-resolved.
5. R1 (2026-09-09): Stitch generation path verified. create_project → generate_screen_from_text (projectId, prompt, deviceType MOBILE) → get_screen / generate_variants → edit_screens. Auth via custom.stitch connector. Test project "Video Messenger" exists but does not count; real design starts after the graph resolves.
6. T1 (2026-09-09): Concept direction = keep the video-messaging principle; make it actually good with modern technology and fair, non-predatory pricing. (Aniket's own direction; archive-first, thread-intelligence, and rethought-social-shape pivots rejected as concept changes.) PROPAGATION: A1 refined, "push somewhere new" now means execution/technology/business model, not the fundamental concept. A2 reinforced. T3/T4/T5: no options eliminated.
7. T3 (2026-09-09): Full feature set, redesigned. Every Marco Polo feature survives, executed well ("not dog shit"). PROPAGATION: T5 unblocked (recording improvements now apply across the full set). T2/T4: no options eliminated.
8. T2 (2026-09-09): iOS-native SwiftUI + web companion. Android explicitly deferred; when it ships it will be a web-derived app (React Native / web wrapper), never native. PROPAGATION: design target is iOS-first (Stitch MOBILE, Liquid Glass per transcripts). Derived: the web companion echoes the design language but cannot use Liquid Glass (Apple-only material); no glass mimicry on web. T5/T4: no options eliminated.
9. T5 (2026-09-09): Morphing sheet. The tinted record button expands into the recorder (Session 323 navigation zoom). Optimized for convenience, not production quality: one-tap start/stop, one-hand and hands-free operation, framing guides and a swipeable retake stack inside. PROPAGATION: full-screen capture mode eliminated (out of scope). Recording ease is the guiding principle; fidelity is secondary.
10. T4 (2026-09-09): Fresh name, no lineage. The Marco Polo name is dead (pool theme, "stupidest fucking name ever heard"). Naming direction: presence, conversation, connectivity; modern; descriptive of what the app actually does. PROPAGATION: none (last ticket). Sub-decision open: the specific name (creative).

## Decision graph (charted 2026-09-09, nothing resolved at chart time)
- T1 [Grilling]: The new concept direction. What does "push the concept somewhere new" mean? Options: (a) Archive-first video memory: Polos auto-organize into a searchable video memory of your people; the app sells remembering, not messaging. (b) Thread intelligence: long async conversations become browsable, auto-chapters, transcript-first reading, catch-me-up summaries as the core; the app sells never being lost. (c) Rethought social shape: keep async video but change the conversation model (channels/topics over 1:1 threads, ambient hands-free recording, video-first feed). (d) Aniket's own direction. | Downstream: T2, T3, T4, T5. H = 2.00 bits. IG = 2.00 * (1+4) = 10.0
- T2 [Grilling]: Platform scope. Options: (a) iOS-native SwiftUI only (~70% likely given TestFlight infra + Liquid Glass spec), (b) iOS + Android, (c) iOS + web companion. | Upstream: T1. Downstream: build tooling (later). H = 1.00 bits. IG = 1.00 * (1+2) = 3.0
- T3 [Grilling]: Which Marco Polo features survive the reimagining? Options: (a) full feature set, redesigned; (b) async-video core only, drop the rest (watching-now presence, effects, etc.); (c) Aniket's call. | Upstream: T1. Downstream: T5, player details. H = 1.58 bits. IG = 1.58 * (1+2) = 4.74
- T4 [Grilling]: App identity/name. Options: (a) new brand, (b) nod to Marco Polo lineage, (c) Aniket's call. | Upstream: T1. Downstream: none. H = 2.00 bits. IG = 2.00
- T5 [Grilling]: Recording interaction shape (concept-dependent specifics: one-tap, hands-free, framing guides, retakes). | Upstream: T1, T3. Downstream: none yet. H = 1.50 bits. IG = 3.00

## Frontier (IG order, unblocked first)
_(empty: all tickets resolved)_

## === ALL DECISIONS RESOLVED ===
Next: expand the resolved graph into the product/UX design in chat (per the agreed sequence: design first, pricing after, then Stitch, then the artifact build). Open creative sub-decision: the specific app name (direction locked: presence / conversation / connectivity).

## Out of scope
- Full-screen dedicated capture mode (eliminated by T5: convenience-first morphing sheet chosen; ease beats fidelity).

## Not yet specified
- Sync/storage architecture (local-first vs cloud archive): sharpens after the deferred business model decision.
- Notification and presence model for the new concept.
- Onboarding: how a new user meets the new concept.

## Out of scope
(empty)
11. NAME (2026-09-09): **Typical Talk**. Aniket's own pick, figured out solo. Brand-consistent (Typical ___), telephone-flavored, conversation-first. Locked.

## Pricing (parked 2026-09-09; Aniket deferred it twice, do not design around pricing assumptions)
- Aniket's idea: free version has limited features; unlock via opt-in ads OR pay. Ads as a feature-unlock lever is unusual ("fucking genius" per Aniket).
- TENSION LOGGED: this revises A2 (power features free for everyone, charge only for server costs) and the "not predatory" T1 constraint. Not resolved. Settle when pricing is actually discussed.
