# hkg-climate-page

A NEMESIS plugin for Hyundai/Kia/Genesis Gen5W head units that adds a **climate page** to
the right-side split screen: one-tap driver and passenger seat buttons (heating below a
switch temperature, cooling above it), the outside temperature, and preset buttons that
apply several climate settings at once. A small settings app sets the switch temperature
and builds the presets.

![The climate page on the right split screen, beside Android Auto](docs/images/panel-in-car.jpg)

| The page up close | The settings app beside the page |
|---|---|
| ![Seat buttons in heat mode with swap buttons, and the Cold and Hot presets](docs/images/panel-close-up.jpg) | ![Climate Page settings on the left with the page on the right](docs/images/settings-beside-panel.jpg) |

**Status: release v1.2.0, running on the owner's car (2026-10-31): presets land reliably (commands
spaced out, and a temperature or fan step the car missed is pressed again, at most twice), Save
no longer crashes, every editor dropdown scrolls, a preset sets the driver and passenger
temperatures separately, up to six presets, the preset in effect is highlighted, a redesigned
panel (gear button, seat icons that show the mode, swap and off buttons), and presets and
settings are kept across updates.** Install from the GitHub release (`hkg-climate-usb.zip`).
v1.2.1 is 1.2.0 with the package descriptor in the NEMESIS Package Store format (1.1) and a store
zip (`hkg-climate-page-store.zip`); the app and the page are unchanged.
Earlier releases: v1.0.0 (seat buttons, outside temperature and presets of the seats).
The owner's on-car checklist is
[docs/testing/2026-10-31-version-1-2.md](docs/testing/2026-10-31-version-1-2.md). Earlier checklists:
[climate presets (1.1.0)](docs/testing/2026-10-31-climate-presets.md),
[presets of the seats (v1.0.0)](docs/testing/2026-10-30-presets.md),
[version 1](docs/testing/2026-10-30-version-1.md),
[test build 2](docs/testing/2026-10-30-test-build-2.md),
[test build 1](docs/testing/2026-10-30-test-build-1.md).

## Updating

NEMESIS won't install over an installed package while the head unit is running (it asks you to
uninstall first; dismiss that message). To update, plug the stick with the new version in and
restart the head unit with the stick still in: NEMESIS runs the update while the head unit
starts (the old version's uninstall step, then the new install), and the head unit restarts once
more by itself when it's done. If the climate page is missing after that, restart once more with
the stick in (an update can need a restart to free space on /system).

Presets and settings (switch temperature, page on or off) are kept: from 1.2.0 on, the uninstall
step saves them to the NEMESIS folder and the install puts them back. An update from 1.1.0 or
older loses them once, because the older uninstall step doesn't save them. Uninstalling in
NEMESIS, restarting and installing again also keeps them (the saved copy stays in the NEMESIS
folder).

## Build

Prerequisites (Linux host):

- Android SDK at `~/Android/sdk` (or set `ANDROID_SDK`) with platform `android-19` and
  build-tools `30.0.3`
- JDK 11 or newer (`javac`, `java`, `keytool`)
- `clang` and `ld.lld`
- `qemu-user` (`qemu-arm`), for the tests
- for `tools/build-panel.sh` only: a Python venv at `private/toolchain/venv` with
  `bsdiff4==1.3.1`
- optional: `mksh`, so the package tests run the hooks under the head unit's shell

Then:

1. `tools/toolchain.sh fetch` (smali, baksmali and JUnit jars into `private/toolchain/`)
2. `tools/toolchain.sh check`: every line should say `ok` (the venv line only matters for the
   panel build)
3. `tools/build-app.sh`, then `tools/build-package.sh` (writes `dist/hkg-climate-page.zip`)
4. Optional: `tools/build-kit.sh` and `tools/build-usb.sh` (writes `dist/hkg-climate-usb.zip`:
   the package plus the read-only kit on one USB stick; a first install runs on insert, an
   update when the head unit restarts with the stick in (see "Updating"), the kit from NEMESIS
   Manager's "Run USB NEMESIS.sh")

`tools/build-store.sh` writes `dist/hkg-climate-page-store.zip`, the bare package for the
[NEMESIS Package Store](https://xwtk.cloud/services/nemesis#package-store) (`NEMESIS.data` at the
root, descriptor format 1.1): the same bytes as `packages/hkg.climate.page.zip` inside the install
zip. Upload it at [portal.xwtk.cloud/nemesis](https://portal.xwtk.cloud/nemesis/) (a new version
needs a higher `package-version`), or install it on the unit with `nemesis install <zip>`.

`tools/build-capture.sh` writes `dist/hkg-climate-capture.zip`, a read-only tool that records the
Android log on a USB stick while the stock climate controls are used (checklist:
[docs/testing/2026-10-31-climate-capture.md](docs/testing/2026-10-31-climate-capture.md)).
`tools/build-voicekit.sh` writes `dist/hkg-climate-voicekit.zip`, a read-only kit that copies the
stock voice software (voice apps, engine libraries, US-English recognizer data) to a USB stick.

The first `build-app.sh` run creates the signing key in `private/keys/`: back it up. The panel
patch files are committed, so `tools/build-panel.sh` is not needed to package.

CI (`.github/workflows/build.yml`) runs the same tests and builds on every push and uploads the
zips as a build artifact. The package mock test needs the stock panel files, so CI skips it.

- Branches and pull requests are signed with a throwaway key made on each run, so their zips
  can't update an install signed with the release key. Use them to check the build only.
- Tags `v<version>` (for example `v1.0.0`) are signed with the release key from the repository
  secrets `HKGCLIMATE_KEYSTORE_B64` (the keystore, base64; alias `hkgclimate`) and
  `HKGCLIMATE_KEYSTORE_PASSWORD`. The tag must match `versionName` in `app/AndroidManifest.xml`
  and `package-version` in `package/NEMESIS.data`, and the zips are attached to the GitHub
  release for the tag.

To release: set the version in both files (and `versionCode` one higher), commit, then `git tag v<version>` and
`git push origin v<version>`. To store the key in the secrets:

    base64 -w0 private/keys/hkgclimate.jks | gh secret set HKGCLIMATE_KEYSTORE_B64
    gh secret set HKGCLIMATE_KEYSTORE_PASSWORD < private/keys/password

## About

Target car: 2023 US Hyundai Ioniq 5 (`NEEV23.USA.`, firmware 260507).

- Commands and settings found so far, for the community:
  [docs/community/gen5w-climate-commands.md](docs/community/gen5w-climate-commands.md)
- Design: [docs/superpowers/specs/2026-10-30-hkg-climate-page-design.md](docs/superpowers/specs/2026-10-30-hkg-climate-page-design.md);
  climate presets: [docs/superpowers/specs/2026-10-31-climate-presets-design.md](docs/superpowers/specs/2026-10-31-climate-presets-design.md);
  version 1.2: [docs/superpowers/specs/2026-10-31-version-1-2-design.md](docs/superpowers/specs/2026-10-31-version-1-2-design.md)
- Current plan: [docs/superpowers/plans/2026-10-31-version-1-2.md](docs/superpowers/plans/2026-10-31-version-1-2.md)

Licence: GPL-3.0 (see `LICENSE`). Credits: `NOTICE.md`.
