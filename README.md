# ANNOT (PoC)

**Double-tap ⌥** (or press ⌥⌘O) anywhere on your Mac, click what you mean, type. Figma-style comments, saved locally with the page URL, the element and a screenshot. You'll find them all under **Comments…** in the menu bar.

- **In Chrome, Arc and Safari:** pins and threads right on the page. Hover a pin to preview, click to open the thread, reply, resolve.
- **Anywhere else:** comment mode highlights the element under the mouse (Accessibility), click to drop a pin, type. Saves app, window and AX element (plus a cropped screenshot if enabled).
- **For developers:** web comments store the element itself: id, classes, `data-*`/`aria-*` attributes, an HTML snippet, the DOM path, CSS selector, size, font and colors. **Copy for Developer** puts all of it, plus the screenshot path, on the clipboard as Markdown.
- **Annotate screenshots:** click a screenshot in the Comments window (or **Annotate**) to draw arrows, boxes, text and freehand lines, each with a label. The original is kept; the drawing is saved next to it and can be edited again.
- **Comments window (⌘K from the menu):** every comment with screenshot, thread and context. Filter Open / Resolved / All, search, reply, resolve, reopen the page in the browser it came from, copy as Markdown or JSON for an agent, delete.

## Install

Download `ANNOT-x.y.z.zip` from the [latest release](https://github.com/KLIXPERT-io/annot/releases/latest), unzip it and move **ANNOT.app** to Applications. ANNOT then updates itself: it checks once a day and shows **Update Available…** in its menu (or use **Check for Updates…**).

The app isn't notarized yet, so macOS blocks the first launch once:

- **macOS 15 and later:** open ANNOT, click **Done** on *“ANNOT” Not Opened*, then go to **System Settings › Privacy & Security**, scroll down to *“ANNOT” was blocked…*, click **Open Anyway**, confirm with your password or Touch ID, and click **Open**.
- **macOS 14:** right-click ANNOT › **Open** › **Open**.
- **Or in Terminal:** `xattr -dr com.apple.quarantine /Applications/ANNOT.app`

Updates don't ask again.

## Build it

```bash
./build.sh                         # → build/ANNOT.app (universal, signed with your dev cert if present)
open build/ANNOT.app
```

To always sign with the same certificate, put `CODESIGN_IDENTITY="…"` in `signing.env` next to `build.sh` (git-ignored).

On first launch the settings window opens (later: **Settings…**, ⌘, in the menu). It has three tabs: **General** (name, shortcuts, where comments are stored), **Account** (Rome, see below) and **Permissions**:

| Permission | Why |
| --- | --- |
| Accessibility | identify the element you click in other apps |
| Automation → Chrome / Arc / Safari | talk to the active tab (macOS asks once per browser) |
| **Allow JavaScript from Apple Events** in each browser | Chrome: View › Developer (German UI: Darstellung › Entwickler › *JavaScript von Apple Events zulassen*), per profile. Arc: its own setting of the same name. Safari: Settings › Advanced › *Show features for web developers*, then Settings › Developer |
| Screenshots *(optional)* | off by default and never prompted for by itself; turn on in Settings. macOS calls this “Screen & System Audio Recording”; no audio is recorded |

The icon is `app/AppIcon.icon`, an Icon Composer document (Xcode 26: open it in Icon Composer to edit). `build.sh` compiles it with `actool`: Liquid Glass on macOS 26, a flat icon on 14 and 15.

## Tickets (Rome)

In **Settings › Account** (or **Connect to Rome…** in the menu), each person enters their Rome server's address and connects their own personal token: **Open Rome** goes to Settings › API tokens, where you create a token and copy it, and pasting it into the field connects. Rome only creates tokens from a browser session, so the app can't make one itself. The token is kept in the Keychain. Your name, picture and projects then come from the account (`GET /me`, `/me/tokens`, `/projects`), and you pick the project new comments go to. Disconnecting can also revoke the token in Rome. Every new comment then lands in that project's **Triage queue** as an annotation note (`POST /projects/{key}/notes`): the text and element details as Markdown, the page URL, the click context, and the screenshot plus the annotated one once you draw. Switching projects is one click: every comment box (web and native) has a **Send to** picker, and whatever you pick there becomes the default for the next comment. The menu bar has the same choice under **Send Comments To**. "Keep on This Mac" sends nothing. Comments made before you connected, or ones that failed, can be sent from the Comments window (**Send to Triage…** / **Retry**).

From then on it stays in sync both ways:

| Here | Rome, note in Triage | Rome, after triage into its own issue |
| --- | --- | --- |
| Reply | the note body is rewritten with the thread | issue comment (and issue comments come back as replies) |
| Details (added after posting) | part of the note body | one "Details" issue comment, edited on each change |
| Resolve / Reopen | dismiss / restore the note | transition to a Done status / back to To Do |

A note merged into an existing issue as a comment still syncs replies, but resolving it doesn't close that issue. When both sides changed, Rome wins.

**@mentions:** typing `@` in any comment or reply box lists the people who can see the chosen project (`GET /principals?project=KEY`; ↑↓ and ↩ or Tab to pick). Mentions are written as `@handle`; the note gets a `For: @anna, @bob` line and `context.mentions`, so triage sees who should help. Rome doesn't notify from Triage notes, only from issue comments: once the note is an issue, replies with `@handle` notify those people.

Rome's changes arrive live over the WebSocket (`wss://…/ws`, subprotocol `rome.v1`, one `project:<KEY>` topic per project). Events only trigger a re-read over REST; after sleep or a dropped connection the stream resumes from the last `seq`, and a `resync` re-reads every linked comment. The server is the address entered in Settings › Account.

## Shortcuts

| | |
| --- | --- |
| double-tap ⌥ | comment mode (again to leave). Can be turned off in Settings |
| ⌥⌘O | the same as a key combo. Configurable in Settings |
| Esc, right-click or **Cancel** | leave comment mode (outside the browser Esc works even after ⌘-Tab) |
| Enter / ⇧Enter | post / new line |
| ⌘Enter or the pen button | post and draw on the screenshot |
| Esc | cancel or close the thread |

## Where comments live

```
~/Library/Application Support/ANNOT/
  comments.sqlite      one row per comment; `data` holds the full JSON (anchor, replies, screenshot_path)
  Screenshots/<id>.png
  Screenshots/<id>-annotated.png   with arrows/boxes/labels (`annotated_screenshot_path`; the marks as JSON in `annotations`)
```

Anything local, such as an agent or a script, can read it:

```bash
sqlite3 ~/Library/Application\ Support/ANNOT/comments.sqlite \
  "select json_extract(data,'$.text'), json_extract(data,'$.anchor.url'), json_extract(data,'$.anchor.selector'), json_extract(data,'$.anchor.dom.html'), coalesce(json_extract(data,'$.annotated_screenshot_path'), json_extract(data,'$.screenshot_path')) from comments where status='open'"
```

The app keeps the comments in memory. Edit them through the app; rows written to the database from outside show up after the app restarts.

## How it fits together

```
Mac app (Swift, menu bar)                     Browser tab
 ├─ HotKey (Carbon)                            └─ overlay.js — shadow-root UI, pins, capture,
 ├─ BrowserBridge ─ AppleScript `execute` ──►      anchor resolution, event queue
 │    poll: 1 Apple Event / 2 s idle, 0.3 s busy
 ├─ NativeCapture (AX hit test + SwiftUI composer)
 ├─ Screenshot (ScreenCaptureKit, cropped)
 ├─ CommentStore (SQLite) ── changes refresh the open tab
 ├─ InboxView (Comments window)
 └─ Updater (Sparkle, GitHub releases)
```

The overlay never touches the network or the disk. It only exchanges events with the app. In Chrome and Arc it runs in the AppleScript isolated world, so the page can't see `window.__annot`. Safari's `do JavaScript` runs in the page's own world: same overlay, but the page could see it.

More Chromium browsers with Chrome's AppleScript dictionary (Brave, Edge, Vivaldi) are one line each in `Browser.all` (`BrowserBridge.swift`).

## PoC limits

- **Local pins:** comments live on this Mac, so teammates don't see each other's pins. Rome syncs the thread and status, not the pins.
- **Open tabs keep the old overlay** until reloaded, so element details only appear in tabs loaded after an update.
- **Not handled:** iframes, Shadow DOM targets, `position: fixed` pins (as in the PRD).
- **Distribution:** a zip on GitHub releases, notarized only when built with a Developer ID certificate.

## Releasing

```bash
./release.sh 0.2.0
```

It bumps the version in `app/Info.plist` (`CFBundleVersion` +1, which is what Sparkle compares), builds, signs the zip with the Sparkle key, writes `appcast.xml`, commits, tags `v0.2.0` and creates the GitHub release with both files. Installed apps read `releases/latest/download/appcast.xml` (`SUFeedURL`), so the newest release is always the feed. The release notes are the commit subjects since the last tag.

- **Sparkle key:** the private EdDSA key is in the login Keychain of whoever set it up (`generate_keys --account annot`, from `app/.build/artifacts/sparkle/Sparkle/bin`). The public key is `SUPublicEDKey` in `Info.plist`. Without the private key nobody can publish an update the installed apps accept, so keep a backup: `generate_keys --account annot -x annot-sparkle.key`, stored somewhere safe, never in the repo.
- **Notarizing:** with a *Developer ID Application* certificate and `NOTARY_PROFILE` set (`xcrun notarytool store-credentials`, e.g. in `signing.env`), `release.sh` notarizes and staples. Without it, first installs need `xattr -dr com.apple.quarantine /Applications/ANNOT.app`. Updates install either way.
- **Same signature on every release:** macOS keeps Accessibility, Automation and Screen Recording permissions only while the app is signed by the same team, so switching certificates means granting them again once.
