import 'package:test/test.dart';
import 'package:zapstore_cli/utils/version_utils.dart';

void main() {
  group('canUpgrade - table-driven tests', () {
    // Each entry: [installed, current, expectedResult]
    const cases = <List>[
      // ───────────────────────────── basic numeric ────────────────────────────
      ['1.0.0', '1.0.1', true],
      ['1.0.1', '1.0.0', false],
      ['1.0.10', '1.0.2', false], // numeric, not lexicographic
      ['0.9.9', '1.0.0', true],
      ['1.2', '1.2.0', false], //  missing patch treated as 0
      ['1.2', '1.3', true],

      // ─────────────────────────── length mismatches ──────────────────────────
      ['1', '1.0.1', true],
      ['1.0.5', '1', false],
      ['2024.05', '2024.5.1', true],
      ['2024.05.14', '2024.10', true], // more segments in installed

      // ─────────────────────────────── prefixes ──────────────────────────────
      ['v1.2.3', '1.2.4', true],
      ['V2.0.0', 'v2.0.0', false],

      // ────────────────────────────── prerelease ─────────────────────────────
      ['1.0.0-alpha', '1.0.0', true], // stable beats prerelease
      ['1.0.0', '1.0.0-alpha', false],
      ['1.0.0-alpha', '1.0.0-beta', true],
      ['1.0.0-beta', '1.0.0-alpha', false],

      // numeric vs alphanumeric identifiers (SemVer §11)
      ['1.0.0-alpha.1', '1.0.0-alpha.beta', true],
      ['1.0.0-alpha.beta', '1.0.0-alpha.1', false],
      ['1.0.0-alpha.9', '1.0.0-alpha.10', true], // numeric comparison
      ['1.0.0-rc.1', '1.0.0-rc.1.1', true],
      ['1.0.0-rc.1.1', '1.0.0-rc.1', false],

      // ─────────────────────────── build metadata (+) ─────────────────────────
      ['1.0.0+build1', '1.0.0+build2', false], // build tags ignored
      ['1.0.0-alpha+exp.1', '1.0.0-alpha+exp.2', false],

      // ───────────────────────────── stable vs prerelease with zeros ─────────
      ['1.0', '1.0.0-alpha', false],
      ['1.0.0-alpha', '1.0.0-alpha', false], // identical

      // ───────────────────────────── big jumps ───────────────────────────────
      ['1.0.0', '2', true],
      ['2', '1.9.9', false]
    ];

    for (final c in cases) {
      final installed = c[0] as String;
      final current = c[1] as String;
      final expected = c[2] as bool;

      test('$installed → $current  ⇒  $expected', () {
        expect(canUpgrade(installed, current), expected);
      });
    }
  });

  group('canUpgrade – symmetry sanity checks', () {
    test('if upgrade is possible one way, reverse must be false', () {
      const a = '1.2.3-beta.2';
      const b = '1.2.3';
      expect(canUpgrade(a, b), isTrue);
      expect(canUpgrade(b, a), isFalse);
    });

    test('identical versions never upgrade', () {
      const versions = ['1.0.0', 'v1.2.3', '2.0.0-rc.1', '3.4.5+nightly'];
      for (final v in versions) {
        expect(canUpgrade(v, v), isFalse, reason: v);
      }
    });
  });
}
