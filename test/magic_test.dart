import 'package:test/test.dart';
import 'package:zapstore_cli/parser/detect_types.dart';

void main() {
  test('Detect shit', () {
    print(detectFileTypes('test/assets/sample.apk'));
    print(detectFileTypes('test/assets/icon.png'));
    print(detectFileTypes('test/assets/hello'));
    print(detectFileTypes('test/assets/hello.tar.gz'));
    print(detectFileTypes('test/assets/hello.zip'));
    print(detectFileTypes('test/assets/jq-linux-arm64'));
    print(detectFileTypes('test/assets/jq-macos-arm64'));
  });
}
