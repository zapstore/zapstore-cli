import 'package:test/test.dart';
import 'package:zapstore_cli/utils/version_utils.dart';

void main() {
  group('getChangelogForVersion', () {
    final String testChangelog = '''
# Changelog
All notable changes to this project will be documented in this file.

## [1.1.0-rc1] - 2023-05-15
### Added
- New feature X
- New feature Y

### Changed
- Improved performance

## [1.0.1] - 2023-04-20
### Fixed
- Bug in login screen
- Crash on startup

## [1.0.0] - 2023-03-10
### Added
- Initial release
''';

    test('should extract changelog for existing version', () {
      final result = extractChangelogSection(testChangelog, '1.0.1');
      expect(
        result,
        contains('''### Fixed
- Bug in login screen
- Crash on startup'''),
      );
    });

    test('should extract changelog for first version', () {
      final result = extractChangelogSection(testChangelog, '1.0.0');
      expect(result, '''## [1.0.0] - 2023-03-10
### Added
- Initial release''');
    });

    test('should extract changelog for latest version', () {
      final result = extractChangelogSection(testChangelog, '1.1.0-rc1');
      expect(result, '''## [1.1.0-rc1] - 2023-05-15
### Added
- New feature X
- New feature Y

### Changed
- Improved performance''');
    });

    test('should return null for non-existent version', () {
      final result = extractChangelogSection(testChangelog, '2.0.0');
      expect(result, null);
    });

    test('should handle version with special regex characters', () {
      final specialChangelog = '''
# Changelog
## [1.0+1] - 2023-05-15
### Fixed
- Special version test

## [1.0.0] - 2023-03-10
### Added
- Initial release
''';
      final result = extractChangelogSection(specialChangelog, '1.0+1');
      expect(
        result,
        contains('''### Fixed
- Special version test'''),
      );
    });
  });
}
