# Live Project Packs

A native macOS prototype for a desktop utility that keeps shared project assets available above any app.

## What is included

- Menu bar utility named `Packs`
- Draggable Volt-only closed state with remembered position and file-catching feedback
- Floating always-on-top pack window
- Global shortcut: `Command + Shift + P`
- Create and switch between Packs
- Drag files, images, links, and text into a Pack
- Paste screenshots, copied links, and copied text into a Pack
- Drag Pack assets back out into other apps when the source is a file or URL
- Native asset selection, range selection, keyboard shortcuts, quick preview, and contextual actions
- Soft asset Trash with a six-second Undo action
- Library and Board views over the same assets
- Online teammate list, asset status, comments/reactions, and activity feed
- Simulated real-time teammate updates every few seconds

## Run

```sh
./build.sh
open outputs/LiveProjectPacks.app
```

The prototype is local-first and uses simulated sync. The next production step would be adding a small cloud service for Packs, signed asset URLs, websocket presence/activity, and conflict-safe metadata updates.
