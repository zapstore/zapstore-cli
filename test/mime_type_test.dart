import 'dart:io';

import 'package:test/test.dart';
import 'package:zapstore_cli/utils/mime_type_utils.dart';
import 'package:zapstore_cli/utils/utils.dart';

void main() {
  test('Detect mime types', () async {
    expect(await detectMimeTypes('test/assets/sample.apk'),
        (kAndroidMimeType, null, null));
    expect(await detectMimeTypes('test/assets/icon.png'),
        ('image/png', null, null));
    expect(
        await detectMimeTypes('test/assets/hello'), (kMacOSArm64, null, null));

    final r1 = await detectMimeTypes('test/assets/hello.zip');
    expect(r1.$1, 'application/zip');

    final r2 = await detectMimeTypes('test/assets/hello.tar.gz');
    expect(r2.$1, 'application/gzip');
    expect(r2.$2, {kMacOSArm64});
    expect(r2.$3, {'hello'});

    expect(await detectMimeTypes('test/assets/jq-linux-arm64'),
        (kLinuxArm64, null, null));
    expect(await detectMimeTypes('test/assets/jq-macos-arm64'),
        (kMacOSArm64, null, null));

    final bytes = await File('test/assets/fluffychat').readAsBytes();
    final mimeType = await detectBytesMimeType(bytes);
    expect(mimeType.$1, kLinuxArm64);

    final bytes2 =
        await File('test/assets/libwindow_to_front_plugin.so').readAsBytes();
    final mimeType2 = await detectBytesMimeType(bytes2);
    expect(mimeType2.$1, isNull);
  });
}
