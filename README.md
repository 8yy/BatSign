<div align="center">

<img title="BatSign" alt="BatSign" height="180" src="Feather/Resources/Assets.xcassets/AppIcon.appiconset/feather.png">

# BatSign

**0.0.3** — an on-device signer for iOS that behaves like the App Store.

[![Release](https://img.shields.io/github/v/release/8yy/BatSign?style=for-the-badge&color=0a84ff)](../../releases/latest)
[![Downloads](https://img.shields.io/github/downloads/8yy/BatSign/total?style=for-the-badge&color=34c759)](../../releases)
[![Platform](https://img.shields.io/badge/iOS-16.0%2B-blue?style=for-the-badge&logo=apple)](../../releases/latest)
[![License](https://img.shields.io/badge/License-GPL--3.0-lightgrey?style=for-the-badge)](LICENSE)
[![Telegram](https://img.shields.io/badge/Telegram-t.me%2Fbatsigner-26A5E4?style=for-the-badge&logo=telegram)](https://t.me/batsigner)

[Download the latest IPA](../../releases/latest) · [Join the signer group](https://t.me/batsigner)

</div>

---

BatSign signs, installs and updates apps on your iPhone, the same way the App Store
does it. You pick an app from a repository, tap Get, and that's the whole job — it
downloads in the background, signs itself with your certificate, installs, and lands
on your home screen. Updates do the same thing without you touching anything.

It started as a fork of [Feather](https://github.com/claration/Feather), and most of
the credit for the base belongs to clARATION, Nyasami and llsc12. Everything on top
of that — the background signing engine, the update system, the install hand-off —
is written from scratch. There is no server of mine in the middle of it and no
analytics anywhere in the app. The one network call the app makes on its own behalf
is a check against your own repositories.

## What it does

**Automatic updates**

- Update checks in the background on a schedule you pick, from hourly to daily
- Updates download, sign and install themselves — zero taps after the toggle
- Install prompts that fire themselves, plus tap-to-install notifications
- Fully silent installs over the paired-device (tunnel) method
- Wi-Fi-only downloads and a night-only install window if you want them
- Skip This Version and Hold Updates, per app
- Auto-update toggles per app and per source
- Live download progress on the Dynamic Island and Lock Screen, with speed and ETA
- What's New text from the source, carried into the update notification
- Update All, a Recently Updated row, and a home screen badge for pending updates

**Background signing**

- A serial signing queue — every import and every download signs itself
- Certificate continuity: apps keep the certificate they were signed with, so your
  data survives every update
- Self-Heal — a revoked certificate is detected and affected apps are re-signed
  automatically with your healthiest certificate
- Certificate Health dashboard with expiry rings, revocation status and Renew All
- Keep Apps Signed — apps are renewed before their certificate expires
- Auto-retry when a signing job fails for a transient reason

**The store side**

- Discover tab with featured apps and source cards
- Search across every added source, with recent searches
- Library with filters and quick actions
- OneView install — Get, progress, signing and Open, all on one screen
- Rich app pages: screenshots, What's New, version history, permissions
- App Store-style Settings with icon tiles

**Signing tools**

- App Cloner — run two accounts of the same app side by side
- Tweak Vault — save your .deb and .dylib tweaks once, inject them in one tap
- Bulk sign — queue the whole Library in one run
- Pending-sign tray — apps that arrived while you were busy wait there
- PPQ protect, Liquid Glass patching, appearance changes, minimum iOS version
- Injection path and folder configuration
- ElleKit for tweak injection, including extensions
- Manage existing dylibs and frameworks
- Per-app certificate pins

**Everything else**

- Live Activities for download, signing and install — watch the whole pipeline
- Install ledger: an install that landed while the app was dead is caught up on
  the next launch, not lost
- Download rescue: transfers survive force-kills, network handovers and lock
  screens, and pick up from the bytes they already had
- Activity timeline with timestamps for every background action
- Backup and restore for sources and preferences
- Face ID lock
- Shortcuts actions: Check for Updates, Install Pending Updates
- Storage manager with superseded-copy and duplicate cleanup
- Import and export folder support
- AltStore-compatible sources and the `batsign://` URL scheme
- Default launch tab
- Liquid Glass design on iOS 26

## Install

Grab `BatSign.ipa` from [Releases](../../releases/latest) and install it with
SideStore, Sideloadly, AltStore, TrollStore — or with BatSign itself, once you have
it. Every push to `main` builds a fresh IPA in Actions, and tagged versions become
releases automatically. The app can also update itself from its own repository.

For auto-updates to work you need a signing certificate in the app. Free Apple
accounts work, with the usual 7-day limits.

## Building

```
make iphoneos
```

produces `packages/BatSign.ipa`. You need Xcode 26 or newer on a Mac. The Zsign and
IDeviceKitten dependencies come in as submodules, so clone with
`--recurse-submodules` or run `git submodule update --init --recursive` first.

## Adding the source

The built-in source points at this repository:

```
https://raw.githubusercontent.com/8yy/BatSign/main/app-repo.json
```

Any AltStore-format source works the same way.

## Community

Questions, certificates talk, feature ideas, whatever else — the signer group is at
**[t.me/batsigner](https://t.me/batsigner)**. That's also where release notes land
first.

## Credits

- [claration](https://github.com/claration) and the Feather contributors — the base
- [Nyasami](https://github.com/Nyasami) — Feather lineage
- [llsc12](https://github.com/llsc12) — AltStore repository work
- [khcrysalis](https://github.com/khcrysalis) — Zsign and IDeviceKit

BatSign is free software under the GPL-3.0, same as Feather. See [LICENSE](LICENSE).

## The honest bit

This is a sideloading tool. It signs apps with certificates you provide and nothing
else. If you use it to pirate paid apps, that's on you, not on this project — and
it's not what it's for.
