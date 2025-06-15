## [0.2.0-rc4]

  - Bugfix: Auto-update failure based on Platform.script reported path

## [0.2.0-rc3]

  - Feature: Implement Gitlab parser (#15)
  - Feature: Implement F-Droid/Izzy metadata fetcher (#9)
  - Feature: Preview release in HTML
  - Feature: Skip remote metadata flag
  - Improvement: Use new `apk_parser` package, auto-extracts icon, name, and more
  - Improvement: Better messaging, spinners
  - Improvement: non-arm64-v8a filtering
  - Bugfix: Web parser issues, JSONPath
  - Improvement: Retrieve license from Github
  - Bugfix: Events printed to stdout missing links
  - Bugfix: Broken daemon mode

## [0.2.0-rc2]

  - Improvement: Sending events to stdout
  - Bugfix: WoT failure upon install
  - Bugfix: Install now works on Linux x86
  - Improvement: Add signer in install
  - Feature: Zap a package: `zapstore zap`

## [0.2.0-rc1]

  - Feature: New `AssetParser` base class for streamlined local and web asset handling
  - Improvement: Implement metadata fetchers for various sources (GitHub, Play Store, etc)
  - Feature: Support for NIP-07 signing
  - Feature: Support for NIP-46 signing (requires `nak` for now)
  - Improvement: All file operations through Dart (removed shell calls) (faster, more portable)
  - Improvement: Add `SIGN_WITH` environment variable as only way of specifying signing method
  - Improvement: Ability to send unsigned events to stdout
  - Feature: Support for parsing various archive formats (zip, tar, gzip, xz, bzip2)
  - Feature: Automatic detection of executables within archives
  - Feature: Add AXML parser for AndroidManifest.xml processing (removed `apktool` dependency)
  - Feature: Add APK signature parser for verifying package authenticity (removed `apksigner` dependency)
  - Feature: Enhanced MIME type detection for various file types, including types inside compressed archive formats
  - Feature: Implemented a Blossom client for managing asset uploads
  - Improvement: Introduce robust version comparison logic (`canUpgrade`)
  - Feature: Add utility for extracting changelog sections for specific versions
  - Improvement: Vertex integration for Web of Trust checks
  - Improvement: Checks to prevent parsing existing releases (correctly handling updated Github releases)
  - Improvement: Simpler format for `zapstore.yaml` config file
  - Feature: Add `discover` command to find new packages
  - Feature: Show release notes in `install`
  - Feature: Add filtering capabilities to the `list` command
  - Improvement: `remove` command now provides better user feedback with a spinner
  - Improvement: Optimized local binary installation and linking

## [0.1.2]

  - Migration: zap.store to zapstore.dev
  - Bugfix: Use innerHTML for app description scraped from Play Store
  - Other minor bugfixes

## [0.1.1]

  - Feature: Add app pointer to latest release
  - Feature: Allow passing config file via argument
  - Feature: Web support
  - Feature: Daemon mode
  - Bugfix: Normalize identifiers
  - Bugfix: Silent env loading
  - Bugfix: Proper name parsing

## [0.1.0]

  - Bugfix: Stringify versions to generate valid nostr tags
  - Bugfix: Do not require identifier
  - Bugfix: Do not capture %v, always require version argument
  - Bugfix: Failing with pre-releases
  - Other minor bugfixes
  - Feature: Run in daemon mode (zapstore indexing is now done with this program)
  - Feature: Support `.env` file
  - Feature: Introduce `release_repository` attribute for closed-source apps
  - Feature: Allow passing icon and images as arguments

## [0.0.6]

  - Fix issue installing apktool
  - Make release version optional, add release notes argument
  - Allow adding license
  - Handle WoT service failure
  - Better messaging
  - Upgrade dependencies

## [0.0.5]

  - Fix missing icon, now properly extracted from APK
  - Fix APK path failure when pulling from Github
  - Introduce `--overwrite-app` and `--overwrite-release` flags (#2)
  - Warn if binary already in PATH (#6)
  - Improve documentation (in program output and README.md)
  - Various minor fixes

## [0.0.4]

  - Add local parser
  - APK parsing and Play Store scraping
  - Fix auto-install/update

## [0.0.3]

  - Publish packages from the CLI
  - New basedir structure
  - Lots of validation and prompt fixes

## [0.0.2]

  - Initial version, rewritten in Dart
