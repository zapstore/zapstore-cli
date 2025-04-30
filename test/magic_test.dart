import 'package:test/test.dart';
import 'package:zapstore_cli/parser/magic.dart';

void main() {
  test('Detect shit', () {
    print(detectFileType('test/assets/sample.apk'));
    print(detectFileType('test/assets/icon.png'));
    print(detectFileType('test/assets/hello'));
    print(detectFileType('test/assets/hello.tar.gz'));
    print(detectFileType('test/assets/hello.zip'));
    print(detectFileType('test/assets/jq-linux-arm64'));
    print(detectFileType('test/assets/jq-macos-arm64'));
  });
}
