# AGENTS.md

## What this is

Flutter app for **Android car head units**. Streams music from NAS servers via WebDAV with lyrics, album art theming, and foreground-service keep-alive. Chinese-language UI. Target: car screens with wildly varying sizes.

## Architecture

- **Single-file app**: all logic is in `lib/main.dart` (~1050 lines). No `lib/` subdirectories, no routing, no state management library.
- `MainHomeScreen` (StatefulWidget) holds everything: UI, WebDAV, audio, lyrics, caching, settings.
- `CarAudioHandler` (extends `BaseAudioHandler`) wraps `just_audio` AudioPlayer for Android notification/media-session integration.
- UI scaling: every pixel value goes through `s(double value) => value * _uiScale`. Don't hardcode pixel sizes.

## Key commands

```bash
# Build (Windows) — produces fat APK + split-per-abi APKs
build_apk.bat

# Equivalent manual commands:
call flutter build apk --release --dart-define=BUILD_TIME="<timestamp>"
call flutter build apk --split-per-abi --release --dart-define=BUILD_TIME="<timestamp>"
```

The `call` keyword in .bat is critical — without it the script exits after the first `flutter` command.

## Dependencies worth knowing

| Package | Purpose |
|---|---|
| `just_audio` | Audio playback engine (supports background MediaSession control) |
| `audio_service` | Android foreground service + notification controls |
| `dio` | HTTP client (WebDAV PROPFIND, downloads, API calls) |
| `shared_preferences` | Persistent settings (WebDAV accounts, UI prefs, playback state) |
| `palette_generator` | Extract dominant color from album art for UI theming |

## Platform integration

- **MethodChannel** `com.nascarplayer/app_retain`: native Android methods — `checkOverlayPermission`, `requestOverlayPermission`, `sendToBackground`, `listInstalledApps`, `launchAppByPackage`.
- Android manifest has `audio_service` notification channel config; `androidNotificationOngoing: true` is deliberate for car head-unit keep-alive.
- `onTaskRemoved` does NOT call `stop()` or `exit(0)` — intentional, keeps MediaSession active for background steering wheel controls.

## Data flow

- **WebDAV accounts**: stored in SharedPreferences as JSON array under `webdavAccounts` key.
- **Song list**: fetched via WebDAV `PROPFIND` with `Depth: 1`, filtered by audio extensions (mp3/flac/wav/m4a/aac).
- **Caching**: songs downloaded to `<appDocumentsDir>/nas_cache/`, evicted oldest-first when total exceeds `_maxCacheGB` (default 2GB). Playback checks cache before streaming.
- **Lyrics**: tries local `.lrc` on NAS first, falls back to `tools.rangotec.com/api/anon/lrc` API.
- **Cover art**: fetched from iTunes Search API; fallback to a hardcoded Unsplash default.

## Gotchas

- External API Dio clients use `badCertificateCallback = (_, __, ___) => true` to bypass TLS cert validation — this is intentional for self-hosted NAS certs.
- `audioHandler` uses **function callbacks** (`onNextCallback`/`onPrevCallback`) instead of Streams for next/prev — Streams get suspended when app is backgrounded on Android car units.
- Song name parsing: `Artist - Title` format expected for metadata extraction. If no `-` is found, artist defaults to "私人乐库".
- The `_checkDebounce()` method (250ms threshold) guards next/prev actions — respect it to avoid double-triggers from hardware buttons on car head units.
