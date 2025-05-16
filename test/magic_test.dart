import 'package:test/test.dart';
import 'package:zapstore_cli/utils/mime_type_utils.dart';

void main() {
  test('Detect shit', () {
    print(detectMimeTypes('test/assets/sample.apk'));
    print(detectMimeTypes('test/assets/icon.png'));
    print(detectMimeTypes('test/assets/hello'));
    print(detectMimeTypes('test/assets/hello.tar.gz'));
    print(detectMimeTypes('test/assets/hello.zip'));
    print(detectMimeTypes('test/assets/jq-linux-arm64'));
    print(detectMimeTypes('test/assets/jq-macos-arm64'));
  });
}
