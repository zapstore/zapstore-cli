import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zapstore_cli/parser/axml_parser.dart';

void main() {
  test('AXML to XML conversion yields proper XML string', () {
    final file = File('test/assets/AndroidManifest.xml');
    expect(file.existsSync(), isTrue,
        reason: 'Binary AndroidManifest.xml must exist');

    final bytes = file.readAsBytesSync();
    final xml = AxmlParser.toXml(Uint8List.fromList(bytes));
    print(xml);

    // Basic sanity checks
    expect(xml.trim().startsWith('<?xml'), isTrue);
    expect(xml, contains('<manifest'));
    expect(xml, contains('</manifest>'));
    expect(xml, contains('xmlns:android'));
    expect(xml, contains('<application'));
    expect(xml, contains('</application>'));
  });
}
