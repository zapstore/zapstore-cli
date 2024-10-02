## 0.1.0

 - Bugfix: Stringify versions to generate valid nostr tags
 - Bugfix: Do not require identifier
 - Bugfix: Do not capture %v, always require version argument
 - Bugfix: Failing with pre-releases
 - Other minor bugfixes
 - Feature: Run in daemon mode (zap.store indexing is now done with this program)
 - Feature: Support `.env` file
 - Feature: Introduce `release_repository` attribute for closed-source apps
 - Feature: Allow passing icon and images as arguments

## 0.0.6

 - Fix issue installing apktool
 - Make release version optional, add release notes argument
 - Allow adding license
 - Handle WoT service failure
 - Better messaging
 - Upgrade dependencies

## 0.0.5

 - Fix missing icon, now properly extracted from APK
 - Fix APK path failure when pulling from Github
 - Introduce `--overwrite-app` and `--overwrite-release` flags (#2)
 - Warn if binary already in PATH (#6)
 - Improve documentation (in program output and README.md)
 - Various minor fixes

## 0.0.4
 
 - Add local parser
 - APK parsing and Play Store scraping
 - Fix auto-install/update

## 0.0.3

 - Publish packages from the CLI
 - New basedir structure
 - Lots of validation and prompt fixes

## 0.0.2

 - Initial version, rewritten in Dart
