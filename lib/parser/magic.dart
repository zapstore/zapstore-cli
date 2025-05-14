import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:mime/mime.dart';
import 'package:zapstore_cli/utils.dart';

Future<String?> detectFileType(String filePath) async {
  final data = Uint8List.fromList(await File(filePath).readAsBytes());
  return lookupMimeType(filePath, headerBytes: data) ??
      await detectBytesType(data);
}

Future<String?> detectBytesType(Uint8List data) async {
  String? result;

  // ZIP: first 4 bytes are [0x50, 0x4B, 0x03, 0x04].
  if (data.length >= 4 &&
      data[0] == 0x50 &&
      data[1] == 0x4B &&
      data[2] == 0x03 &&
      data[3] == 0x04) {
    // Check if the zip file is an APK by searching for the APK specific file.
    String content = latin1.decode(data, allowInvalid: true);
    if (content.contains("AndroidManifest.xml")) {
      return kAndroidMimeType;
    }
    return "application/zip";
  }

  // GZip: first two bytes are 0x1F, 0x8B.
  if (data.length >= 2 && data[0] == 0x1F && data[1] == 0x8B) {
    // Decompress using GZipCodec.
    List<int> decompressed = GZipCodec().decode(data);

    // Check for tar archive by looking for "ustar" at offset 257.
    if (decompressed.length >= 262) {
      String ustar = String.fromCharCodes(decompressed.sublist(257, 262));
      if (ustar == "ustar") return "application/gzip";
    }
    return "application/gzip";
  }

  // if (filePath.endsWith('.tar.gz')) {
  //   return "application/gzip";
  // }

  result = _detectMachO(data);
  if (result != null) return result;

  result = _detectELF(data);
  if (result != null) return result;

  return null;
}

/// Detect a Mach-O file and report if it is Darwin arm64.
String? _detectMachO(Uint8List data) {
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

/// Detect an ELF file and report Linux binaries.
String? _detectELF(Uint8List data) {
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
