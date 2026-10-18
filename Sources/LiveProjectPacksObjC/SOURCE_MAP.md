# Live Project Packs Source Map

This folder is being split carefully from a single large Objective-C app file.
The rule for early refactors is behavior-preserving moves only: move one
cohesive helper area, update the build, run self-tests, then continue.

## Current Files

- `main.m` keeps `AppController`, window/view classes, storage wiring, drag/drop,
  Live Clips, Pack AI UI, and self-tests for now.
- `LPPAssetHelpers.h/.m` owns asset path/origin/payload resolution, asset search,
  selection ranges, drag pasteboard writers, response extensions, and kind
  icon/color helpers.
- `LPPPackExport.h/.m` builds the shareable ZIP of a Pack (files, notes as .txt, and an
  index.html that opens in any browser) without needing Packs to view it.
- `LPPWebParsing.h/.m` owns pure URL, HTML title, entity decoding, social-image,
  and whitespace helpers.
- `LPPLiveClipCore.h/.m` owns Live Clip rect/source models, source relocation,
  content signatures, refresh comparisons, OCR item sorting, and structured
  content classification.
- `AIExplainer.swift` bridges Apple's on-device Foundation Models framework for
  asset explanation/name suggestions.
- `build.sh` automatically compiles `LPP*.m` helper files, then `main.m`.
- `Tools/check-refactor.sh` is the one-command check after each file split.

## Next Safe Split Candidates

- `LPPVoltUI.h/.m`: Volt colors, animation frame math, and mascot image helpers.

## Guardrail

Keep `AppController` in `main.m` until helper/model code has been separated and
the test harness stays green after each move.

After every split, run:

```sh
Tools/check-refactor.sh
```
