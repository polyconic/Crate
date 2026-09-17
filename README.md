# Crate

This already exists, but I needed something that fit the way I organize better. 
Most apps don't function exactly how I need them to. Also resizing and 
file metadata removal is a nice bonus. - GE

This is a client delivery packager for macOS. Drop in a folder of final exports, and
Crate renames everything to a consistent pattern, optionally resizes it for
the platforms you deliver to, and zips it up.

Built because export file names are never clean by the time a job is done —
`FINAL_v3 (1)`, `copy 2`, `1920x1080` baked into the name — and every
delivery needs the same handful of sizes assembled the same way.

## Building

```
./build.sh
```

Produces `build/Crate.app`. Needs only the Xcode Command Line Tools — no
Xcode, no package manager, no dependencies (MP3 export needs `ffmpeg` on the
PATH, but everything else is native).

## How it works

Drop a folder onto the window (or press ⌘O). Crate cleans up each file name —
stripping junk words, `(1)`/`copy 2` suffixes, baked-in pixel sizes — and
shows you the result before anything is written. Fill in Client, Project and
Version, then export:

- **Package** (⇧⌥⌘P) — writes the delivery folder next to the source.
- **Zip** (⇧⌘↩) — same, then zips it with `ditto` (no `__MACOSX` junk).

Output is named `<Client> v<N>` (or `<Client> v<N>.zip`). If that name is
already taken, Crate offers to bump the version or replace the existing one.

### Resizing

Off by default — most jobs just need clean names. Turn on **Resize for
platforms** to export each file at one or more sizes (IG Square, Story, etc.,
plus custom ones), either cropped to fill or fit with letterboxing.

### Clean-up

- **Strip metadata** — removes location/camera/software info from photos and
  video without re-encoding or touching orientation/colour profile.
- **Web-friendly formats** — HEIC/TIFF/PSD → JPG or PNG; ProRes and other
  non-web codecs → H.264 MP4.
- **File size cap** — resized/converted files are squeezed under a limit;
  untouched originals over it are flagged, not silently dropped.

### Audio

Masters are always copied untouched. Optionally adds MP3 320 (via `ffmpeg`)
and a dithered 16-bit/44.1kHz WAV alongside them.

### Finder integration

Right-click a folder (or selection of files) → Services → **Package with
Crate** / **Package & Zip with Crate**. Runs immediately or opens the app
first, depending on the **Package straight away** setting.

### Headless

```
Crate.app/Contents/MacOS/Crate --package <folder> [--zip]
```

Uses the last settings saved in the app.

## Naming pattern

Default: `{project}_{name}_{format}_v{version}`. Tokens: `{project}` `{name}`
`{format}` `{size}` `{version}` `{date}` `{n}`. The client name is
deliberately not one of them — it only names the delivery folder/zip, never
individual files.
