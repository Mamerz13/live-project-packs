# Live Project Packs — Real Sharing & Persistence Design

Hand this document to your coding agent. It describes how to turn the current prototype's
simulated sharing into **real sharing with friends, with no server, accounts, or hosting** —
plus persistence (today, everything is lost when the app quits).

## The core idea

**Every pack becomes a normal folder on disk.** A pack that lives in a synced folder
(iCloud Drive, Dropbox, Google Drive) and is shared with friends becomes a live shared pack:
each person's app writes only its own metadata file, the sync service moves the files, and
every app polls the folder for changes. No two people ever write the same file, so there are
no sync conflicts.

## Pack folder layout

```
<PackFolder>/
  pack.json                     # {"name": "...", "createdBy": "<email>", "createdAt": <unix>}
  feed-<sanitized-email>.json   # ONE PER TEAMMATE — each app writes ONLY its own
  Assets/                       # the actual dropped files (copied in)
```

`sanitized-email` = the user's email lowercased with every non-alphanumeric char replaced by `_`.

### feed-*.json schema (the heart of the design)

```json
{
  "email": "friend@email.com",
  "entries": [
    {
      "id": "UUID string",
      "title": "photo.png",
      "kind": "Image",
      "uploader": "friend@email.com",
      "addedAt": 1787729000.123,
      "rel": "Assets/photo.png"      // EXACTLY ONE of: rel | url | text | abs
    }
  ],
  "removed": ["asset-uuid", "..."],   // tombstones — hide these ids for everyone
  "invited": ["other@email.com"]      // shown as pending teammates
}
```

Rules:
- **File assets store a RELATIVE path** (`rel`, e.g. `Assets/photo.png`) so they resolve on
  every teammate's machine. Absolute paths must never go into a feed (fallback key `abs` is
  only for a local-only edge case: a file that could not be copied into the pack).
- `url` for web links, `text` for notes.
- Write feeds **atomically** (write-to-temp + rename / `writeToURL:atomically:YES`).
- On load: merge `entries` from ALL `feed-*.json` files, drop any entry whose `id` appears in
  the UNION of all `removed` arrays, sort by `addedAt` descending.
- Teammates list = union of all feed `email`s + all `invited`, current user first.
- Deleting an asset = add its id to MY `removed`, remove it from MY `entries` if it was mine,
  delete the file under `Assets/` if the asset had a `rel`. Confirm first (it removes for everyone).

## App-level persistence

`~/Library/Application Support/LiveProjectPacks/config.json`:

```json
{"email": "me@email.com", "packs": ["/abs/path/to/PackFolder", "..."], "selected": 0}
```

- Load at launch; if `email` is set, skip the login screen (auto sign-in).
- Login becomes identity-only (email; the password field is fake today — drop it or make it
  optional). Save config on login, pack create/open/select.
- Local (unshared) packs live in `~/Library/Application Support/LiveProjectPacks/Packs/<Name>/`.
  Same folder format — so "share it later" is just moving the folder.
- First launch with no config: create default pack "Case Competition" and import any files
  found in the legacy `~/Library/Application Support/LiveProjectPacks/Uploads/` tree as
  entries (use file mtimes as `addedAt`).
- `storeFileInSelectedPack:` / `storeImageData:extension:` must write into
  `<PackFolder>/Assets/` (keep the existing unique-name collision loop).

## Live sync detection (no FSEvents needed)

A 2-second `NSTimer`. For each pack folder compute a cheap signature: for `pack.json` and
every `feed-*.json`, concatenate `name:mtime:size`. If the signature differs from the cached
one, reload that pack from disk, then:
- any asset id that is new and NOT uploaded by me → activity entry "<uploader> added <title>."
- any new feed author → "<email> joined <pack>."
- re-render only when something actually changed (so typing in fields isn't interrupted).
After the app writes its own feed, refresh the cached signature immediately so it doesn't
react to its own writes. `Assets/` contents are deliberately NOT in the signature.

## UI flows

**Pack picker popup** gains, after the pack names: separator, "New Pack…" (creates under the
local Packs dir), "New Shared Pack…" (name prompt, then NSOpenPanel to pick a parent folder —
default `~/Library/Mobile Documents/com~apple~CloudDocs` when it exists — then show the share
instructions), "Open Shared Pack…" (NSOpenPanel pick the folder a friend shared; create
`pack.json`/`Assets` if missing; dedupe by standardized path). Use explicit `NSMenuItem`s with
tags (e.g. -1/-2/-3) — `addItemWithTitle:` silently replaces duplicate titles.

**Share button** (replaces the fake `pack://share/...` link): copy the folder path to the
clipboard and show an alert:
1. Keep the pack folder in iCloud Drive, Dropbox, or Google Drive.
2. Share that folder with friends WITH EDIT ACCESS (iCloud Drive: right-click in Finder →
   Share → Collaborate).
3. Friends install the app and use "Open Shared Pack…" → choose the same folder.
Buttons: "Reveal in Finder", "Move to Synced Folder…" (only when the pack is under the local
Packs dir — moves the folder and updates config), "Done".

**Invite field**: append the email to MY feed's `invited`, save, then show the share alert
(the folder still has to be shared for the invite to mean anything).

**Status-bar menu**: add "Open Shared Pack…", "Share Current Pack…", "Sign Out"
(sign-out clears the email in config but must PRESERVE the pack path list).

**Asset tiles**: add a trash button (see delete rule above). Guard every add path with
"logged in + a pack exists". `selectedPack` needs a bounds/nil guard now that packs are dynamic.

## Distributing the app to friends

Run `./package.sh` to produce `outputs/dist/LiveProjectPacks.zip` plus an `INSTALL.txt`
to send with it.

The build is ad-hoc signed, not notarized, so macOS quarantines it on download and
Gatekeeper refuses it: "Apple could not verify ... is free of malware". Each friend has
to approve it once in System Settings → Privacy & Security → "Open Anyway". On macOS 15
and later the old right-click → Open bypass no longer works for un-notarized apps.

To remove the warning entirely, join the Apple Developer Program ($99/yr), then set
`DEVELOPER_ID` and `NOTARY_PROFILE` and re-run `package.sh` — it signs with the hardened
runtime, notarizes, and staples the ticket, after which the app just opens.

## Notes on current code (as of this doc)

- `main.m` already contains an extended `KindForURL` (audio/archive/spreadsheet/presentation/
  design/folder detection) and a `UniformTypeIdentifiers` import from an earlier merge attempt —
  both additive. If `UTType` ends up used (e.g. a generic "save unknown pasteboard data by its
  type's preferred extension" fallback), add `-framework UniformTypeIdentifiers` to build.sh.
- `RelativeTimeString`/`AssetSubtitle`/`ImmediatePreviewImage` exist but aren't wired into
  `AssetTile` yet; the feed's numeric `addedAt` pairs naturally with them (extend
  `RelativeTimeString` to accept an NSNumber).
- Asset dictionaries in memory should carry: `id`, `title`, `kind`, `uploader`, `source`
  (absolute path / url / text — resolved from `rel` against the pack folder), `addedAt`,
  and `rel` when applicable.
