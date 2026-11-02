# D-Brew

A macOS app for keeping Homebrew up to date. It lists the formulae and casks that have newer versions, shows how much disk space each one uses, and updates the ones you tick — or all of them.

## Using it

- **Scan** (⌘R, or the toolbar's arrow) — refreshes Homebrew's package lists with `brew update`, then lists everything `brew outdated` reports. D-Brew scans when it opens.
- **The list** — each package shows its type (formula or cask), the installed version, the latest version and its space on disk. Click a column heading to sort. "+2 older" means older versions are still installed too; hover to see them.
- **Update Selected** (⌘U) — tick packages, then update just those. **Select All** ticks everything. The footer shows how many are ticked and how much space they use.
- **Update All** (⇧⌘U) — updates every package in the list.
- While updating, Homebrew's output is shown live; afterwards D-Brew says whether everything succeeded and scans again. **Output** (⌘L, or the terminal button) shows the last output again, with **Copy Output**.
- **Options** (toolbar):
  - **Run brew update before scanning** (on by default). Off lists what the local Homebrew database already knows, which is faster but may miss new versions.
  - **Include casks that update themselves** (`brew outdated --greedy`, off by default). Apps like browsers update themselves, so Homebrew normally leaves them out.
- Pinned formulae (`brew pin`) are shown with a pin and can't be ticked; `brew upgrade` skips them.

## Disk space

- A formula's size is its folder in Homebrew's Cellar (e.g. `/opt/homebrew/Cellar/node`), including every installed version.
- A cask's size is its Caskroom folder plus the app it installed in `/Applications` or `~/Applications`.
- Sizes are the space files actually take on disk, as `du` reports.

## Administrator password

Some casks run an installer that needs administrator rights. Homebrew normally asks for the password in Terminal; D-Brew has no terminal, so it sets `SUDO_ASKPASS` to a small helper (`~/Library/Application Support/D-Brew/askpass.sh`) that asks with a standard macOS password dialog. The password goes straight to `sudo` and isn't stored. Cancelling the dialog makes that cask's update fail; the others carry on.

## Requirements

- macOS 13 or later.
- Homebrew in `/opt/homebrew` (Apple silicon) or `/usr/local` (Intel).

## Build

Requires the Swift toolchain (Xcode or Command Line Tools).

```sh
./build.sh          # builds a universal build/D-Brew.app
./build.sh --open   # builds and launches
./build.sh --dmg    # also packages dist/D-Brew-<version>.dmg (version from Resources/Info.plist)
```

The app is assembled and signed in a temporary folder, then copied to `build/`, because iCloud keeps re-adding Finder info to bundles inside `~/Documents`, which `codesign` rejects.
