import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:file_magic_number/magic_number_type.dart';
import 'package:mime/mime.dart';
import 'package:zapstore_cli/utils/utils.dart';
import 'package:file_magic_number/file_magic_number.dart';

Future<
        (
          String? mimeType,
          Set<String>? internalMimeTypes,
          Set<String>? executablePaths
        )>
    detectMimeTypes(String filePath, {Set<String>? executablePatterns}) async {
  final data = Uint8List.fromList(await File(filePath).readAsBytes());
  return detectBytesMimeType(data, executablePatterns: executablePatterns);
}

Future<
        (
          String? mimeType,
          Set<String>? internalMimeTypes,
          Set<String>? executablePaths
        )>
    detectBytesMimeType(Uint8List data,
        {Set<String>? executablePatterns}) async {
  String? mimeType;
  Set<String>? internalMimeTypes;
  Set<String>? executablePaths;

  mimeType = switch (MagicNumber.detectFileType(data)) {
    MagicNumberType.zip => 'application/zip',
    MagicNumberType.tar => 'application/x-gtar',
    MagicNumberType.elf => 'application/x-elf',
    MagicNumberType.exe => 'application/x-msdownload',
    MagicNumberType.png => 'image/png',
    MagicNumberType.jpg => 'image/jpeg',
    MagicNumberType.gif => 'image/gif',
    MagicNumberType.mp4 => 'video/mp4',
    _ => null,
  };

  if (mimeType == 'application/zip' &&
      latin1.decode(data, allowInvalid: true).contains("AndroidManifest.xml")) {
    mimeType = kAndroidMimeType;
  }

  mimeType ??= lookupMimeType('', headerBytes: data);

  mimeType ??= _getTypeForCompressed(data);

  if (kArchiveMimeTypes.contains(mimeType)) {
    (internalMimeTypes, executablePaths) = await _detectCompressed(
      data,
      mimeType!,
      executablePatterns: executablePatterns,
    );
    if (executablePaths != null && executablePaths.isEmpty) {
      final hash = sha256.convert(data).toString().toLowerCase();
      throw UnsupportedError(
          'Executables $executablePatterns inside archive ${hashPathMap[hash]} ($mimeType) must match at least one supported executable');
    }
  }

  if (mimeType == 'application/x-elf') {
    mimeType = _detectELFMimeType(data)!;
  }

  mimeType ??= _detectMachOMimeType(data);

  return (mimeType, internalMimeTypes, executablePaths);
}

/// Detect a Mach-O file and report if it is Darwin arm64.
String? _detectMachOMimeType(Uint8List data) {
  if (data.length < 8) return null;

  // Read the magic number in big-endian order.
  int magic = ByteData.sublistView(data, 0, 4).getUint32(0, Endian.big);

  // Recognized Mach-O magic numbers:
  // Big-endian: 0xFEEDFACE (32-bit), 0xFEEDFACF (64-bit)
  // Little-endian: 0xCEFAEDFE (32-bit), 0xCFFAEDFE (64-bit)
  List<int> machMagics = [0xFEEDFACE, 0xFEEDFACF, 0xCEFAEDFE, 0xCFFAEDFE];
  if (!machMagics.contains(magic)) return null;

  // Determine endianness.
  bool isLittleEndian = (magic == 0xCEFAEDFE || magic == 0xCFFAEDFE);

  // CPU type is stored as a 4-byte field at offset 4.
  int cpuType = ByteData.sublistView(data, 4, 8)
      .getInt32(0, isLittleEndian ? Endian.little : Endian.big);

  // Mach-O CPU types
  // ARM64 CPU type is 0x0100000C (CPU_TYPE_ARM64)
  if (cpuType == 0x0100000C) return "application/x-mach-binary-arm64";

  // x86_64 (64-bit) CPU type is 0x01000007 (CPU_TYPE_X86_64 = CPU_TYPE_I386 | CPU_ARCH_ABI64)
  if (cpuType == 0x01000007) return "application/x-mach-binary-amd64";

  return null;
}

/// Detect a arch of ELF file
String? _detectELFMimeType(Uint8List data) {
  // Check for ELF magic: 0x7F 'E' 'L' 'F'
  if (data.length < 20 ||
      data[0] != 0x7F ||
      data[1] != 0x45 ||
      data[2] != 0x4C ||
      data[3] != 0x46) {
    return null;
  }

  // Byte 5 (EI_DATA) tells us the endianness.
  bool isLittleEndian = (data[5] == 1);

  // Read e_machine (2 bytes) at offset 18 from the ELF header.
  int eMachine = ByteData.sublistView(data, 18, 20)
      .getUint16(0, isLittleEndian ? Endian.little : Endian.big);

  // e_machine of 62 means x86-64 => Linux amd64.
  if (eMachine == 62) return "application/x-elf-amd64";

  // e_machine of 183 means ARM AArch64.
  if (eMachine == 183) return "application/x-elf-aarch64";

  return null;
}

Future<(Set<String>, Set<String>?)> _detectCompressed(
    Uint8List data, String mimeType,
    {Set<String>? executablePatterns}) async {
  final archive = getArchive(data, mimeType);
  return _findExecutables(archive, executablePatterns: executablePatterns);
}

Archive getArchive(Uint8List data, String mimeType) {
  return switch (mimeType) {
    'application/zip' => ZipDecoder().decodeBytes(data),
    'application/gzip' => () {
        final bytes = GZipDecoder().decodeBytes(data);
        return getArchive(bytes, _getTypeForCompressed(bytes)!);
      }(),
    'application/x-tar' => TarDecoder().decodeBytes(data),
    'application/x-xz' =>
      TarDecoder().decodeBytes(XZDecoder().decodeBytes(data)),
    'application/x-bzip2' =>
      TarDecoder().decodeBytes(BZip2Decoder().decodeBytes(data)),
    _ => throw UnsupportedError(mimeType),
  };
}

Future<(Set<String>, Set<String>)> _findExecutables(Archive archive,
    {Set<String>? executablePatterns}) async {
  // Default to everything: (.*)
  final executableRegexps = (executablePatterns ?? {'.*'}).map(RegExp.new);

  final supportedExecutablePlatforms = [
    'application/x-mach-binary-arm64',
    'application/x-elf-aarch64',
    'application/x-elf-amd64'
  ];

  final internalMimeTypes = <String>{};
  final executablePaths = <String>{};

  for (final f in archive.files) {
    if (f.isFile) {
      for (final r in executableRegexps) {
        if (r.hasMatch(f.name)) {
          final bytes = f.readBytes()!;
          final mimeTypes = await detectBytesMimeType(bytes);
          if (supportedExecutablePlatforms.contains(mimeTypes.$1)) {
            executablePaths.add(f.name);
            internalMimeTypes.add(mimeTypes.$1!);
          }
        }
      }
    }
  }
  return (internalMimeTypes, executablePaths);
}

/// Returns a MIME type for the supplied [bytes] or `null` if none matches.
///
/// Recognised types:
/// • application/gzip  (magic: 1F 8B)
/// • application/x-tar (ASCII "ustar" at offset 257)
/// • application/x-xz  (magic: FD 37 7A 58 5A 00)
/// • application/x-bzip2 (magic: 42 5A 68)
String? _getTypeForCompressed(Uint8List data) {
  if (data.length < 6) return null;

  bool startsWith(List<int> magic) {
    if (data.length < magic.length) return false;
    for (var i = 0; i < magic.length; i++) {
      if (data[i] != magic[i]) return false;
    }
    return true;
  }

  // GZIP (and any gzipped variant, e.g. .tar.gz, .bz2.gz, .xz.gz)
  if (startsWith([0x1F, 0x8B])) return 'application/gzip';

  // XZ
  if (startsWith([0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00])) {
    return 'application/x-xz';
  }

  // BZIP2
  if (startsWith([0x42, 0x5A, 0x68])) return 'application/x-bzip2';

  // TAR ("ustar" at offset 257)
  const tarMagic = [0x75, 0x73, 0x74, 0x61, 0x72]; // "ustar"
  if (data.length > 262) {
    var isTar = true;
    for (var i = 0; i < tarMagic.length; i++) {
      if (data[257 + i] != tarMagic[i]) {
        isTar = false;
        break;
      }
    }
    if (isTar) return 'application/x-tar';
  }

  return null;
}
