import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:zapstore_cli/utils/file_utils.dart';

// Usage in
// final sqlite = DynamicLibrary.open(ensureEmbeddedSqliteExtracted()!);
// print(sqlite.lookupFunction<Uint32 Function(), int Function()>(
//     'sqlite3_libversion_number'));

const _kMagic = 'DLIB_SQLITE3'; // 11 bytes – MUST match the loader
final _magicBytes = ascii.encode(_kMagic);

void main(List<String> args) {
  if (args.length != 2) {
    stderr.writeln('Usage: dart run pack.dart <exe> <libsqlite3.so>');
    exit(64); // EX_USAGE
  }

  final exePath = args[0];
  final libPath = args[1];

  final exeFile = File(exePath);
  final libFile = File(libPath);

  if (!exeFile.existsSync()) {
    stderr.writeln('❌ Executable not found: $exePath');
    exit(66); // EX_NOINPUT
  }
  if (!libFile.existsSync()) {
    stderr.writeln('❌ Library not found: $libPath');
    exit(66);
  }

  final libBytes = libFile.readAsBytesSync();
  final libSize = libBytes.length;

  // Prepare 8-byte little-endian length field
  final lengthField = ByteData(8)..setUint64(0, libSize, Endian.little);
  final lengthBytes = lengthField.buffer.asUint8List();

  // Append everything in one go
  final raf = exeFile.openSync(mode: FileMode.append);
  try {
    raf.writeFromSync(libBytes); // raw library
    raf.writeFromSync(lengthBytes); // 8-byte length
    raf.writeFromSync(_magicBytes); // marker
    raf.flushSync();
  } finally {
    raf.closeSync();
  }

  stdout
      .writeln('✅ Packed ${exeFile.path} (+$libSize bytes, magic "$_kMagic")');
}

// ---------- constants --------------------------------------------------------

const _kTrailerLength = 8 + _kMagicLength; // 8 (u64 len) + 11 = 19
const _kMagicLength = 11;

// -----------------------------------------------------------------------------
/// Returns the path of a temporary copy of the embedded libsqlite3 and ensures
/// it exists on disk.  If the executable has no embedded library, `null` is
/// returned.
String? ensureEmbeddedSqliteExtracted() {
  final exePath = Platform.resolvedExecutable;
  final exeFile = File(exePath);
  final raf = exeFile.openSync(mode: FileMode.read);
  try {
    final fileSize = raf.lengthSync();
    if (fileSize < _kTrailerLength) return null;

    // 1.  Seek to where the trailer *should* start and read it.
    raf.setPositionSync(fileSize - _kTrailerLength);
    final trailer = raf.readSync(_kTrailerLength);

    // 2.  Validate magic.
    final magic = String.fromCharCodes(trailer.sublist(8));
    print('magic $magic $_kMagic');
    if (magic != _kMagic) return null;

    // 3.  Fetch length (little endian u64).
    final lengthBytes = trailer.sublist(0, 8);
    var libLength = 0;
    for (var i = 7; i >= 0; i--) {
      libLength = (libLength << 8) | lengthBytes[i];
    }

    // 4.  Seek to start of embedded library and read it.
    final libStart = fileSize - _kTrailerLength - libLength;
    raf.setPositionSync(libStart);
    final libBytes = raf.readSync(libLength);

    // 5.  Write to a temp file (once per run).
    final tmpDir = Directory.systemTemp.createTempSync('dart_sqlite_');
    final libFile = File('${tmpDir.path}/libsqlite3.dylib');
    libFile.writeAsBytesSync(libBytes, flush: true);
    // On UNIX we must ensure it is readable.
    final mode = libFile.statSync().mode;
    Posix().chmod(libFile.path, mode | 0x124); // 0o444

    return libFile.path;
  } finally {
    raf.closeSync();
  }
}
