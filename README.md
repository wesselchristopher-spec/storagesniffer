# Storage Sniffer

A native macOS app that shows where your disk space goes. Scan your whole disk, your home
folder or any folder, then click through a treemap to find the big rocks and move them to the Trash.

- **Treemap + ranked list.** Every rectangle is sized by the space it really takes on disk.
  Click a folder to zoom in; breadcrumbs, ⌘↑ or the back button go up.
- **Live while scanning.** Tiles spring into place and grow as data is discovered.
- **Actions.** Right-click for Reveal in Finder, Copy Path, Rescan Folder and Move to Trash
  (⌘Z or Finder's Put Back undoes it).

## Install

On an Apple Silicon Mac with macOS 15 or later, paste this into Terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/wesselchristopher-spec/storagesniffer/main/install.sh | bash
```

It downloads the latest release into /Applications and opens it. Run it again to update. Because
the download goes through Terminal, macOS doesn't show its "unidentified developer" warning.

## Build and run

Needs macOS 15+ and Swift 6 (Xcode or just the Command Line Tools).

```bash
scripts/bundle.sh --open        # builds build/Storage Sniffer.app and launches it
swift test                      # scanner and layout tests
swift run -c release sniff ~    # command-line scan: timings and largest items
scripts/release.sh 2.0.1        # build, zip and publish a GitHub release (needs `gh`)
```

For complete results grant **Full Disk Access** (System Settings › Privacy & Security). Without
it macOS hides Mail, Messages, Safari and other apps' data. Builds are signed ad hoc unless you
set `CODESIGN_IDENTITY`, so macOS treats each rebuild as a new app and you need to grant access
again.

## How sizes are measured

The goal is that the numbers add up to what the disk actually uses.

| Situation | Handling |
| --- | --- |
| Sparse, compressed and iCloud-evicted files | Counted by allocated bytes, not logical length |
| Hard links | Counted once |
| APFS clones (Finder copies, `cp -c`) | Shared blocks counted once per clone family; other copies count only their private bytes |
| Grafted disk images (OS cryptexes in Preboot) | Skipped, because the image file is already counted |
| Firmlinks (`/Users` ↔ `/System/Volumes/Data/Users`) | Followed once |
| Other disks, network shares, mounted images | Not crossed; sibling volumes of the same APFS container (Data, Preboot, VM) are included |
| Space the scan can't see | Shown at the disk root as **Purgeable space** and **Hidden & system data** (snapshots, protected data), so totals match the disk's used space |
| iCloud placeholders | Never downloaded: the scan disables dataless materialization |

Totals match `du -skx` exactly on folders without clones, and come in lower where `du`
double-counts clones.

## Layout

```
Sources/SnifferCore/     scanner (getattrlistbulk, one thread per core), tree model, treemap math
Sources/StorageSniffer/  SwiftUI app
Sources/sniff/           CLI for benchmarking and accuracy checks
Tests/SnifferCoreTests/  Swift Testing suite
scripts/                 app bundling and icon generation
```
