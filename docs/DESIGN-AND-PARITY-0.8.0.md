# Circle Windows Native 0.8.0 — UI/UX and desktop parity

## Design system
- Graphite #101113 and #191B1F, restrained gold #C6A15B and #E2C17C.
- Animated CTA buttons: gold gradient, subtle hover scale, press compression, glow only on interaction.
- Sidebar navigation: animated active rail and hover gradients, compact icon-only mode.
- Messenger: animated selected chat tiles, saved chat avatar; responsive body.
- Cards, avatar, form controls, empty/error/loading states share visual tokens.
- `MediaQuery.disableAnimations` reduces optional motion; offscreen screens are wrapped in `TickerMode`.
- Feed uses a single lazy sliver list to avoid nested scrolling and excess widget builds.
- Background message polling only on an active, resumed screen; background presence heartbeat every 45 seconds.

## Web-to-desktop additions in this release
- Presence (online/away/DND) and user presence list restricted to friends and shared communities.
- Personal «Избранное» chat backed by one-member DM, with normal text/attachment API.
- API returns one- and two-member conversations in the native messenger.
- Native message search: channel results and DM results filtered by author/date; SQL queries limited by membership and server feature toggles.
- Native community activity dashboard: member-authorized counts and daily activity for the last week.

## Known parity gaps, no false claims of completeness
- Full web admin dashboard, cinema management / all playback workflows, some voice conference moderation actions and Windows OS notifications remain to be tested/ported.
- This update needs the companion FTP patch `api/mobile.php` and `api/desktop_ext.php`. No SQL migration for schema v5.2.3.
- CI must run `flutter analyze --no-fatal-infos`, `flutter test` and signed update tests. A successful CI build is **not** proof of LiveKit, media or API behavior against live MySQL.

## Upgrade order
1. Back up site files and MySQL. Apply the two PHP files by FTP.
2. Overlay the GitHub source patch onto the existing 0.7.1 repository; **do not delete unchanged files**.
3. Ensure the same `CIRCLE_UPDATE_PRIVATE_KEY_PEM` GitHub secret remains configured.
4. Run `Circle Windows build` and verify `v0.8.0` Release and its signed manifest.
5. Verify login, presence, saved chat, feed scroll, media, LiveKit and update from 0.7.1 on a Windows test PC.
