import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Detect a Mach-O file and report if it is Darwin arm64.
String? detectMachO(Uint8List data) {
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

  // Mach-O ARM64 CPU type is 0x0100000C.
  if (cpuType == 0x0100000C) return "Darwin arm64";

  return null;
}

/// Detect an ELF file and report Linux binaries.
String? detectELF(Uint8List data) {
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
  if (eMachine == 62) return "Linux amd64";

  // e_machine of 183 means ARM AArch64.
  if (eMachine == 183) return "Linux aarch64";

  return "Unknown ELF binary";
}

/// Detect compressed archive types.
String? detectCompressed(Uint8List data) {
  // ZIP: first 4 bytes are [0x50, 0x4B, 0x03, 0x04].
  if (data.length >= 4 &&
      data[0] == 0x50 &&
      data[1] == 0x4B &&
      data[2] == 0x03 &&
      data[3] == 0x04) {
    // Check if the zip file is an APK by searching for the APK specific file.
    String content = latin1.decode(data, allowInvalid: true);
    if (content.contains("AndroidManifest.xml")) {
      return "application/vnd.android.package-archive";
    }
    return "ZIP archive";
  }

  // GZip: first two bytes are 0x1F, 0x8B.
  if (data.length >= 2 && data[0] == 0x1F && data[1] == 0x8B) {
    try {
      // Decompress using GZipCodec.
      List<int> decompressed = GZipCodec().decode(data);

      // Check for tar archive by looking for "ustar" at offset 257.
      if (decompressed.length >= 262) {
        String ustar = String.fromCharCodes(decompressed.sublist(257, 262));
        if (ustar == "ustar") return "TAR.GZ archive";
      }
      return "GZIP compressed file";
    } catch (e) {
      return "GZIP compressed file";
    }
  }

  // Additional compressed file tests can be added here.
  return null;
}

/// Detect common image formats by their magic numbers and return the corresponding MIME type.
String? detectImage(Uint8List data) {
  // PNG: Bytes: 89 50 4E 47 0D 0A 1A 0A
  if (data.length >= 8 &&
      data[0] == 0x89 &&
      data[1] == 0x50 &&
      data[2] == 0x4E &&
      data[3] == 0x47 &&
      data[4] == 0x0D &&
      data[5] == 0x0A &&
      data[6] == 0x1A &&
      data[7] == 0x0A) {
    return "image/png";
  }

  // JPEG: Starts with FF D8 FF
  if (data.length >= 3 &&
      data[0] == 0xFF &&
      data[1] == 0xD8 &&
      data[2] == 0xFF) {
    return "image/jpeg";
  }

  // GIF: "GIF87a" or "GIF89a"
  if (data.length >= 6) {
    String header = String.fromCharCodes(data.sublist(0, 6));
    if (header == "GIF87a" || header == "GIF89a") {
      return "image/gif";
    }
  }

  // WebP: "RIFF" at bytes 0-3 and "WEBP" at bytes 8-11.
  if (data.length >= 12) {
    String riff = String.fromCharCodes(data.sublist(0, 4));
    String webp = String.fromCharCodes(data.sublist(8, 12));
    if (riff == "RIFF" && webp == "WEBP") {
      return "image/webp";
    }
  }

  // BMP: "BM" at the beginning.
  if (data.length >= 2 && data[0] == 0x42 && data[1] == 0x4D) {
    return "image/bmp";
  }

  return null;
}

/// Main detection function that calls individual detectors.
String? detectFileType(Uint8List data) {
  String? result;

  // Check for image types first.
  result = detectImage(data);
  if (result != null) return result;

  result = detectMachO(data);
  if (result != null) return result;

  result = detectELF(data);
  if (result != null) return result;

  result = detectCompressed(data);
  if (result != null) return result;

  return null;
}
