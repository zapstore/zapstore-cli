[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/zapstore/zapstore-cli)

# zapstore-cli

The permissionless package manager.

## Download binaries

If you have `zapstore` already installed, run:

```bash
zapstore install zapstore
```

Or download an executable for your platform here: https://zapstore.dev/download or https://github.com/zapstore/zapstore-cli/releases. Make sure to verify hashes published in zapstore.dev.

You need to run the executable once, follow instructions and it will auto-install itself. After that simply call `zapstore`.

Note for Linux users: you must have `libsqlite3.so` in your library path. You can install via `apt install libsqlite3-dev` or similar.

## From source

Download and select release:

```bash
git clone https://github.com/zapstore/zapstore-cli
cd zapstore-cli
git checkout <tag> # select a release from here: https://github.com/zapstore/zapstore-cli/tags
```

Please do not run it from `master` or any other feature branch.

Install dependencies:

```bash
dart pub get
```

Build and run:

```bash
dart compile exe lib/main.dart -o zapstore
./zapstore
```

## New version 0.2.0

This major refactor removes most external dependencies, so `apktool` and `apksigner` are no longer necessary on your system.

## Install or update a package

```bash
zapstore install <package>
# or zapstore i
```

Attempting to install will trigger a web of trust check via [Vertex DVMs](https://vertexlab.io) if the signer is not known. You can skip this by: passing the `-t` argument, or by having no `SIGN_WITH` env var to sign the DVM request with.

## Discover new packages

An experimental command recently added:

```bash
zapstore discover
# or zapstore d
```

It will show recommended packages that are currently not installed.

## List installed packages

```bash
zapstore list <optional-filter>
# or zapstore l
```

If filter is provided it is treated as a regex to filter down installed packages.

## Remove a package

```bash
zapstore remove <package>
# or zapstore r
```

Run `zapstore --help` for more information.

## Publishing apps or packages

**Currently supported platforms**:
 - Android arm64-v8a (`android-arm64-v8a`)
 - MacOS arm64 (`darwin-arm64`)
 - Linux amd64 (`linux-x86_64`)
 - Linux aarch64 (`linux-aarch64`)

Run `zapstore publish` in a folder with a `zapstore.yaml` config file. Alternatively supply its location via the `-c` argument.

### Quickstart: ship your first Android release

1. **Build your APK**  
   `./gradlew assembleRelease` or `flutter build apk --release`.
2. **Create `zapstore.yaml`** in the same directory:

   ```yaml
   name: Sample
   repository: https://github.com/sample/android
   assets:
     - build/app/outputs/flutter-apk/.*arm64-v8a\.apk
   icon: assets/images/icon.png
   summary: Sample summary shown in Zapstore
   ```

3. **Export a signer**  
   `export SIGN_WITH=nsec1xxxx` (or `NIP07`, `bunker://...`, etc.).
4. **Publish**  
   `zapstore publish --config zapstore.yaml --overwrite-app --overwrite-release`.
5. **Verify in Zapstore Android**  
   Confirm metadata, screenshots, and install/update flows before announcing the release.

### CI/CD example (GitHub Actions)

```yaml
name: Publish to Zapstore
on:
  workflow_dispatch:
  release:
    types: [published]

jobs:
  publish:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: subosito/flutter-action@v2
        with:
          flutter-version: '3.24.0'
      - run: flutter build apk --release --split-per-abi
      - run: dart pub get
      - name: Download zapstore-cli
        run: curl -sL https://zapstore.dev/download/linux-x86_64 -o zapstore && chmod +x zapstore
      - name: Publish release
        env:
          SIGN_WITH: ${{ secrets.ZAPSTORE_SIGNER }}
        run: ./zapstore publish --config zapstore.yaml --indexer-mode --overwrite-release
```

Tips:
- Use `--indexer-mode` in CI to disable interactive prompts.
- Prefer `--no-overwrite-app` when only release assets change.
- Store `SIGN_WITH` in encrypted secrets; never echo it to logs.

### `zapstore.yaml` reference

| Field | Required | Applies to | Description |
| ----- | -------- | ---------- | ----------- |
| `name` | Optional | All | Display name in Zapstore. Derived from identifier or metadata when omitted. |
| `identifier` | Optional (Android) / Recommended (CLI) | All | Populates the `d` tag. Auto-extracted from APK manifest or repo slug. |
| `version` | CLI-only | CLI | Semantic version string. Android versions are read from APKs. |
| `summary` | Optional | All | Short tagline for cards. Defaults to `description` or remote metadata. |
| `description` | Optional | All | Markdown detail section. |
| `repository` | Optional but recommended | All | Source repo URL. Required for GitHub/GitLab asset scraping. |
| `release_repository` | Optional | All | Secondary repo for releases (useful for closed-source builds). |
| `homepage` | Optional | All | Marketing/landing page URL. |
| `images` | Optional | All | Relative paths or absolute URLs to screenshots. |
| `icon` | Optional | All | Relative path or absolute URL to the icon shown in listings. |
| `changelog` | Optional | All | Local path to release notes (defaults to `CHANGELOG.md`). |
| `tags` | Optional | All | Space-delimited keywords aiding discovery. |
| `license` | Optional | All | SPDX identifier rendered in the detail view. |
| `remote_metadata` | Optional | All | List of sources (`playstore`, `fdroid`, `github`, `gitlab`) used to fill missing fields. |
| `blossom_server` | Optional | All | Blossom upload endpoint (default `https://cdn.zapstore.dev`). |
| `assets` | **Required** | All | Regex list of binaries to ship. Local paths must include `/`. |
| `executables` | Optional | CLI archives | Regex list of in-archive executables exposed when installing CLI apps. |

Parser behavior:
- If an `assets` entry contains `/`, the **local parser** is used and paths are resolved relative to the config directory.
- Entries without `/` are treated as remote assets pulled from GitHub/GitLab releases (requires `repository`).
- HTTP(S) entries trigger the **Web parser**.
- Omitting `assets` defaults to a single `.*`, meaning “attach every asset from the remote release.”

Convention over configuration remains the goal. The main `AssetParser` extracts as much as possible—especially for Android APKs—so you only override fields the parser cannot infer.

Supported archive formats: ZIP and TAR (optionally gz/bz2/xz compressed). Use `executables` to restrict which files inside an archive become install targets.

If you need assistance producing a `zapstore.yaml`, reach out via nostr.

### Real world examples

This program:

```yaml
name: zapstore
version: 0.2.0-rc1
description: The permissionless package manager
repository: https://github.com/zapstore/zapstore-cli
license: MIT
assets:
  - bin/.*
```

Zapstore Android app:

```yaml
name: Zapstore
repository: https://github.com/zapstore/zapstore
icon: assets/images/logo.png
license: MIT
```

Alby Go:

```yaml
name: Alby Go
summary: The easiest mobile app to use bitcoin on the Go!
repository: https://github.com/getAlby/go
homepage: https://albygo.com/
assets:
  - alby-go-v\d+\.\d+\.\d+-android.apk
remote_metadata:
  - github
  - playstore
```

nak:

```yaml
repository: https://github.com/fiatjaf/nak
assets:
  - nak-v\d+\.\d+\.\d+-darwin-arm64
  - nak-v\d+\.\d+\.\d+-linux-amd64
  - nak-v\d+\.\d+\.\d+-linux-arm64
```

Phoenix for servers (includes `phoenixd` and `phoenix-cli` inside the archive):

```yaml
repository: https://github.com/acinq/phoenixd
assets:
  - phoenixd-\d+.\d+.\d+-macos-arm64.zip
  - phoenixd-\d+.\d+.\d+-linux-x64.zip
  - phoenixd-\d+.\d+.\d+-linux-arm64.zip
```

### Signing and publishing

Supported signing methods:
 - nsec
 - NIP-07 (opens a web browser with an extension)
 - NIP-46 (requires `nak` which can be installed with `zapstore i nak`)
 - sending unsigned events to stdout (see section below)

The method is passed via the `SIGN_WITH` environmental variable and it is required for publishing.

The `.env` file approach is supported and recommended. Example:

```bash
SIGN_WITH=176fa8c7a988df001bc062ce1443e5b8d3f24913b54ec49d322ddd638d0c17aa
# or SIGN_WITH=nsec1zah633af3r0sqx7qvt8pgsl9hrflyjgnk48vf8fj9hwk8rgvz74q6xaqee
SIGN_WITH=NIP07
SIGN_WITH=bunker://9fb1f82f03c40b6063e95f18ce9006d5a3b15fc05dd244d230c12a4e21fe304c?relay=wss%3A%2F%2Frelay.primal.net%2F&secret=87412ffe-4e3e-551e-97fc-5686ac74bf23
```

Note that uploading to Blossom servers will also require signing Blossom authorization events of kind 24242.

The ability of pasting an nsec found in previous versions was removed. If you don't want to include your nsec in an `.env` file, here is the recommended command:

```bash
 SIGN_WITH=176fa8c7a988df001bc062ce1443e5b8d3f24913b54ec49d322ddd638d0c17aa zapstore publish
```

(Notice the leading space, this will prevent your shell from saving this command in history.)

The program does not save any `SIGN_WITH` value or send it anywhere.

Signed events are only published to `relay.zapstore.dev` for now (this will change in the near future). Your pubkey must be whitelisted by Zapstore in order for your events to be accepted. Get in touch!

#### Sending unsigned events to stdout

Events can be produced and printed to stdout unsigned, so it's possible to pipe to `nak` or other signers:

`zapstore publish | nak event --sec 'bunker://...' relay.zapstore.dev`

This approach has a few limitations:
  - An npub MUST be passed as the `SIGN_WITH` environment variable
  - The provided npub MUST match the resulting pubkey from the signed events
  - Blossom assets (if any) MUST be manually uploaded

### Program arguments

Can be found with `zapstore publish --help`.

```bash
Usage: zapstore publish [arguments]
-h, --help                      Print this usage information.
-c, --config                    Path to the YAML config file
                                (defaults to "zapstore.yaml")
    --[no-]overwrite-app        Fetches remote metadata and overwrites latest app on relays
                                (defaults to on)
    --[no-]overwrite-release    Overwrites latest release on relays
    --[no-]indexer-mode         Run publish in indexer mode (non-interactively and without spinners)
    --[no-]honor                Indicate you will honor tags when external signing
```

If the release exists on relays, the program will show a warning and exit unless `--overwrite-release` was passed.

To prevent repeated fetches of remote metadata, use `--no-overwrite-app`.
