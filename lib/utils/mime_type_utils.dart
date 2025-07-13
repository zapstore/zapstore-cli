import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:file_magic_number/magic_number_type.dart';
import 'package:mime/mime.dart';
import 'package:zapstore_cli/utils/utils.dart';
import 'package:file_magic_number/file_magic_number.dart';

Future<
  (
    String? mimeType,
    Set<String>? internalMimeTypes,
    Set<String>? executablePaths,
  )
>
detectMimeTypes(String filePath, {Set<String>? executablePatterns}) async {
  final data = Uint8List.fromList(await File(filePath).readAsBytes());
  return detectBytesMimeType(data, executablePatterns: executablePatterns);
}

Future<bool> acceptAssetMimeType(String assetPath) async {
  final (mimeType, _, _) = await detectMimeTypes(assetPath);
  return kZapstoreAcceptedMimeTypes.contains(mimeType);
}

Future<
  (
    String? mimeType,
    Set<String>? internalMimeTypes,
    Set<String>? executablePaths,
  )
>
detectBytesMimeType(Uint8List data, {Set<String>? executablePatterns}) async {
  String? mimeType;
  Set<String>? internalMimeTypes;
  Set<String>? executablePaths;

  mimeType = switch (MagicNumber.detectFileType(data)) {
    MagicNumberType.zip => 'application/zip',
    MagicNumberType.tar => 'application/x-gtar',
    MagicNumberType.elf => kLinux,
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

  // If type is still null or the default binary type, check if compressed
  if (mimeType == null || mimeType == 'application/octet-stream') {
    mimeType = getTypeForCompressed(data);
  }

  if (kArchiveMimeTypes.contains(mimeType)) {
    (internalMimeTypes, executablePaths) = await _detectCompressed(
      data,
      mimeType!,
      executablePatterns: executablePatterns,
    );
    if (executablePaths.isEmpty) {
      // If it has no matching executables, set type to null
      // which will make this asset be discarded
      mimeType = null;
    }
  }

  if (mimeType == kLinux) {
    mimeType = _detectELFMimeType(data);
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
  int cpuType = ByteData.sublistView(
    data,
    4,
    8,
  ).getInt32(0, isLittleEndian ? Endian.little : Endian.big);

  // Mach-O CPU types
  // ARM64 CPU type is 0x0100000C (CPU_TYPE_ARM64)
  if (cpuType == 0x0100000C) return kMacOSArm64;

  // x86_64 (64-bit) CPU type is 0x01000007 (CPU_TYPE_X86_64 = CPU_TYPE_I386 | CPU_ARCH_ABI64)
  if (cpuType == 0x01000007) return kMacOSAmd64;

  return null;
}

/// Detect a arch of ELF file
String? _detectELFMimeType(Uint8List data) {
  // Check for ELF magic: 0x7F 'E' 'L' 'F'
  if (data.length < 40 ||
      data[0] != 0x7F ||
      data[1] != 0x45 ||
      data[2] != 0x4C ||
      data[3] != 0x46) {
    return null;
  }

  // Byte 4 (EI_CLASS) tells us if it's 32-bit (1) or 64-bit (2)
  bool is64bit = (data[4] == 2);

  // Byte 5 (EI_DATA) tells us the endianness.
  bool isLittleEndian = (data[5] == 1);

  // Read e_type (2 bytes) at offset 16 from the ELF header.
  // ET_EXEC (2) = executable, ET_DYN (3) = shared object or PIE executable
  int eType = ByteData.sublistView(
    data,
    16,
    18,
  ).getUint16(0, isLittleEndian ? Endian.little : Endian.big);

  // Distinguish shared libraries from executables using header information
  if (eType == 3) {
    // For ET_DYN (3), attempt to distinguish shared libraries from PIE executables
    // Read program header entry size and number of entries
    int phentsize = ByteData.sublistView(
      data,
      54,
      56,
    ).getUint16(0, isLittleEndian ? Endian.little : Endian.big);
    int phnum = ByteData.sublistView(
      data,
      56,
      58,
    ).getUint16(0, isLittleEndian ? Endian.little : Endian.big);

    // If there are no program headers, it's likely a shared library
    if (phnum == 0) {
      return null;
    }

    // Look for an PT_INTERP segment (indicates it's an executable)
    bool hasInterp = false;
    int phoff = is64bit
        ? ByteData.sublistView(
            data,
            32,
            40,
          ).getUint64(0, isLittleEndian ? Endian.little : Endian.big)
        : ByteData.sublistView(
            data,
            28,
            32,
          ).getUint32(0, isLittleEndian ? Endian.little : Endian.big);

    // Search through program headers for PT_INTERP (type 3)
    // This isn't always reliable, but it's a good heuristic
    for (
      int i = 0;
      i < phnum && phoff + i * phentsize + 4 <= data.length;
      i++
    ) {
      int pType = ByteData.sublistView(
        data,
        phoff + i * phentsize,
        phoff + i * phentsize + 4,
      ).getUint32(0, isLittleEndian ? Endian.little : Endian.big);
      if (pType == 3) {
        // PT_INTERP
        hasInterp = true;
        break;
      }
    }

    // Check for ".so" in the entire data - a more thorough heuristic
    bool hasSoExtension = false;

    // Scan binary data for ".so" sequence
    for (int i = 0; i < data.length - 3; i++) {
      if (data[i] == 0x2E && // '.'
          data[i + 1] == 0x73 && // 's'
          data[i + 2] == 0x6F) {
        // 'o'
        hasSoExtension = true;
        break;
      }
    }

    // For shared libraries, return null
    // Shared libraries have '.so' in them and usually don't have an interpreter
    if (hasSoExtension && !hasInterp) {
      return null;
    }
  } else if (eType != 2) {
    // If not ET_EXEC (2) or ET_DYN (3), it's not an executable we care about
    return null;
  }

  // Read e_machine (2 bytes) at offset 18 from the ELF header.
  int eMachine = ByteData.sublistView(
    data,
    18,
    20,
  ).getUint16(0, isLittleEndian ? Endian.little : Endian.big);

  // e_machine of 62 means x86-64 => Linux amd64.
  if (eMachine == 62) {
    return kLinuxAmd64;
  }

  // e_machine of 183 means ARM AArch64.
  if (eMachine == 183) {
    return kLinuxArm64;
  }

  return null;
}

Future<(Set<String>, Set<String>)> _detectCompressed(
  Uint8List data,
  String mimeType, {
  Set<String>? executablePatterns,
}) async {
  final archive = getArchive(data, mimeType);
  return _findExecutables(archive, executablePatterns: executablePatterns);
}

Archive getArchive(Uint8List data, String mimeType) {
  return switch (mimeType) {
    'application/zip' => ZipDecoder().decodeBytes(data),
    'application/x-tar' => () {
      try {
        return TarDecoder().decodeBytes(data);
      } catch (_) {
        // Use our custom binary tar decoder if the regular one fails
        return BinaryTarDecoder().decodeBytes(data);
      }
    }(),
    'application/gzip' => () {
      final bytes = GZipDecoder().decodeBytes(data);
      final mimeType = getTypeForCompressed(bytes);
      return getArchive(bytes, mimeType!);
    }(),
    'application/x-xz' => () {
      final bytes = XZDecoder().decodeBytes(data);
      final mimeType = getTypeForCompressed(bytes);
      return getArchive(bytes, mimeType!);
    }(),
    'application/x-bzip2' => () {
      final bytes = BZip2Decoder().decodeBytes(data);
      final mimeType = getTypeForCompressed(bytes);
      return getArchive(bytes, mimeType!);
    }(),
    _ => throw UnsupportedError(mimeType),
  };
}

Future<(Set<String>, Set<String>)> _findExecutables(
  Archive archive, {
  Set<String>? executablePatterns,
}) async {
  // Default to everything: (.*)
  final executableRegexps = (executablePatterns ?? {'.*'}).map(RegExp.new);

  final internalMimeTypes = <String>{};
  final executablePaths = <String>{};

  for (final f in archive.files) {
    if (f.isFile) {
      for (final r in executableRegexps) {
        if (r.hasMatch(f.name)) {
          final bytes = f.readBytes()!;
          // Detect Linux or Mac mime type for executables inside this archive
          final mimeType =
              _detectELFMimeType(bytes) ?? _detectMachOMimeType(bytes);
          if (kZapstoreSupportedMimeTypes.contains(mimeType)) {
            executablePaths.add(f.name);
            internalMimeTypes.add(mimeType!);
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
String? getTypeForCompressed(Uint8List data) {
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

class BinaryTarDecoder extends TarDecoder {
  @override
  Archive decodeStream(
    InputStream input, {
    bool verify = false,
    bool storeData = true,
    ArchiveCallback? callback,
  }) {
    final archive = Archive();
    files.clear();

    while (!input.isEOS) {
      // End of archive when two consecutive 0's are found.
      final endCheck = input.peekBytes(2).toUint8List();
      if (endCheck.length < 2 || (endCheck[0] == 0 && endCheck[1] == 0)) {
        break;
      }

      // Read raw header bytes
      final headerBytes = input.readBytes(512).toUint8List();
      if (headerBytes.length != 512) {
        break;
      }

      // Extract filename from header (first 100 bytes)
      // Find the first null byte to trim the filename
      int nameEnd = 0;
      while (nameEnd < 100 && headerBytes[nameEnd] != 0) {
        nameEnd++;
      }
      final filename = String.fromCharCodes(headerBytes.sublist(0, nameEnd));

      // Extract size from header (octal string at offset 124, length 12)
      final sizeStr = String.fromCharCodes(
        headerBytes.sublist(124, 136),
      ).trim();
      final size = int.tryParse(sizeStr, radix: 8) ?? 0;

      // Read file data
      final data = size > 0
          ? input.readBytes(size).toUint8List()
          : Uint8List(0);

      // Skip padding
      if (size > 0) {
        final padding = (512 - (size % 512)) % 512;
        if (padding > 0) {
          input.skip(padding);
        }
      }

      // Create archive file with raw data
      final file = ArchiveFile(filename, size, data);
      archive.addFile(file);

      if (callback != null) {
        callback(file);
      }
    }

    return archive;
  }
}
