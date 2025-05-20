import 'dart:io';

import 'dart:typed_data';
import 'package:collection/collection.dart';
import 'package:convert/convert.dart' as cv;
import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart';

Future<Set<String>> getSignatureHashes(String apkPath) async {
  // 1. read the complete signing-block (our fixed code from the last reply)
  final sigBlock = ApkSigningBlock.fromPath(apkPath);

  // 2. walk over every signature scheme that is present
  Iterable<Uint8List> certs = [];
  for (final sig in sigBlock.getSignatures()) {
    switch (sig) {
      case ApkSignatureV2(:final certificates):
        certs = certificates; // List<Uint8List>
      case ApkSignatureV3(:final certificates):
        certs = certificates;
    }
  }
  // 3. SHA-256 hash + hex encode
  return certs.map((cert) {
    final digest = sha256.convert(cert).bytes; // Uint8List(32)
    return cv.hex.encode(digest); // lowercase, same as Rust
  }).toSet();
}

//  Port of apk-signature parsing code from Rust  ➜  pure Dart
//
//  The code is intentionally written "line-by-line", i.e. every helper that
//  exists in the Rust version exists here under the same name and performs
//  the same low-level job.  Nothing new or "clever" was invented – only the
//  syntax had to change.
//
//  Usage (synchronous):
//
//      final apk = File('my.apk');
//      final signingBlock = ApkSigningBlock.fromPath(apk.path);
//      final sigBlocks     = signingBlock.getSignatures();
//
//      for (final b in sigBlocks) {
//        print(b);           // pretty print – identical to Rust
//      }
//
//  The two public classes you normally use:
//
//  • ApkSigningBlock.fromPath()       – reads the whole APK and finds the block
//  • ApkSigningBlock.getSignatures()  – returns V2 / V3 certificate blocks
//
//  This file has no external dependencies except "dart:io", "dart:typed_data"
//  and "package:convert" (for hex encoding).
//
// ---------------------------------------------------------------------------

class ApkException implements Exception {
  final String msg;
  ApkException(this.msg);
  @override
  String toString() => msg;
}

// ────────────────────────────────────────────────────────────────────────────
//  Low level little-endian helpers
// ────────────────────────────────────────────────────────────────────────────

int _leU32(Uint8List s, int off) =>
    ByteData.sublistView(s, off, off + 4).getUint32(0, Endian.little);

int _leU64(Uint8List s, int off) =>
    ByteData.sublistView(s, off, off + 8).getUint64(0, Endian.little);

Uint8List _slice(Uint8List src, int off, int len) =>
    Uint8List.sublistView(src, off, off + len);

// ────────────────────────────────────────────────────────────────────────────
//  Public  –  main container
// ────────────────────────────────────────────────────────────────────────────

class ApkSigningBlock {
  final List<(int /*u32*/, Uint8List)> data;
  ApkSigningBlock(this.data);

  // ---------------------------------------------------------
  //  Load the signing block directly from a file path
  // ---------------------------------------------------------
  factory ApkSigningBlock.fromPath(String path) {
    final bytes = File(path).readAsBytesSync();
    return ApkSigningBlock._fromBytes(bytes);
  }

  // ---------------------------------------------------------
  //  Load the signing block from raw bytes
  // ---------------------------------------------------------
  // ---------------------------------------------------------------------------
  //  ApkSigningBlock – corrected _fromBytes()
  // ---------------------------------------------------------------------------

  factory ApkSigningBlock._fromBytes(Uint8List bytes) {
    const magicString = 'APK Sig Block 42';
    const magicLen = 16;
    final magic = Uint8List.fromList(magicString.codeUnits);

    bool magicAt(int p) {
      for (var i = 0; i < magicLen; i++) {
        if (bytes[p + i] != magic[i]) return false;
      }
      return true;
    }

    // scan backwards
    for (int pos = bytes.length - magicLen - 1; pos > 16; pos--) {
      if (!magicAt(pos)) continue;

      // ── length field that sits right before the magic ──────────────────────
      final size1 = _leU64(bytes, pos - 8);
      if (size1 > bytes.length) {
        throw ApkException('Signing block is larger than entire file');
      }

      // ── identical length field at the start of the block ───────────────────
      final size2Offset = pos - size1 + 8; // <-- correct offset
      if (size2Offset < 0) throw ApkException('Corrupted signing block');

      final size2 = _leU64(bytes, size2Offset);
      if (size1 != size2) {
        throw ApkException('Invalid block sizes, $size1 != $size2');
      }

      // ── read all (id,value) pairs inside the block ─────────────────────────
      int p = size2Offset + 8; // first byte *after* size2
      var bytesLeft = size1 - magicLen - 8; // strip magic + size1
      final blocks = <(int, Uint8List)>[];

      while (bytesLeft > 0) {
        final kvLen = _leU64(bytes, p);
        final k = _leU32(bytes, p + 8);
        final vLen = kvLen - 4;
        final v = _slice(bytes, p + 12, vLen.toInt());
        blocks.add((k, v));

        p += 8 + kvLen.toInt();
        bytesLeft -= 8 + kvLen;
      }
      return ApkSigningBlock(blocks);
    }

    throw ApkException('Failed to find signing block');
  }

  // ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
  //  Parse V2 / V3 signatures
  // ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░

  List<ApkSignatureBlock> getSignatures() {
    const v2Id = 0x7109871a;
    const v3Id = 0xf05368c0;

    final sigs = <ApkSignatureBlock>[];

    for (final (k, v) in data) {
      switch (k) {
        case v2Id:
          {
            final v2Block = _getLvSequence(_removePrefixLayers(v));

            if (v2Block.length != 3) {
              throw ApkException(
                'Expected 3 elements in signing block got ${v2Block.length}',
              );
            }

            final signedData = _getLvSequence(v2Block[0]);
            final digests = _getSequenceKv(signedData[0]);
            final certificates = _getLvSequence(signedData[1]);
            final attributes = _getSequenceKv(signedData[2]);

            final signatures = _getSequenceKv(v2Block[1]);
            final publicKey = v2Block[2];

            final digestsM = {for (final (a, b) in digests) a: b};

            sigs.add(
              ApkSignatureBlock.v2(
                signatures: _parseSigs(signatures, digestsM),
                publicKey: Uint8List.fromList(publicKey),
                certificates:
                    certificates.map((e) => Uint8List.fromList(e)).toList(),
                attributes: {
                  for (final (a, b) in attributes) a: Uint8List.fromList(b),
                },
              ),
            );
          }
        case v3Id:
          {
            Uint8List vv = _slice(v, 4, v.length - 4);

            // ─────────────────────────────────────────────────────────────
            //  Correctly parse the v3 signer structure.
            //  The layout is (after the 4-byte version already skipped):
            //    • LV-prefixed signedData
            //    • u32  minSdk
            //    • u32  maxSdk
            //    • LV-prefixed signatures
            //    • LV-prefixed publicKey
            //
            //  We advance through the buffer with an explicit offset
            //  pointer to avoid the previous double-read problems that
            //  caused "Invalid LV sequence" exceptions.
            // -----------------------------------------------------------------

            final v3Block = _getLvU32(vv); // signer block (without version)

            int off = 0;
            Uint8List readLv() {
              final len = _leU32(v3Block, off);
              if (len > v3Block.length - off - 4) {
                throw ApkException(
                    'Invalid LV sequence $len > ${v3Block.length - off - 4}');
              }
              final data = _slice(v3Block, off + 4, len);
              off += 4 + len;
              return data;
            }

            // 1. signedData
            final signedData = readLv();

            // Parse signedData: digests, certificates, min/max sdk, attributes
            int sdOff = 0;
            Uint8List sdReadLv() {
              final len = _leU32(signedData, sdOff);
              if (len > signedData.length - sdOff - 4) {
                throw ApkException('Invalid LV sequence $len > '
                    '${signedData.length - sdOff - 4}');
              }
              final data = _slice(signedData, sdOff + 4, len);
              sdOff += 4 + len;
              return data;
            }

            final digests = _getSequenceKv(sdReadLv());
            final certificates = _getLvSequence(sdReadLv());

            // min/max sdk (u32)
            if (sdOff + 8 > signedData.length) {
              throw ApkException('Malformed signedData in v3 block');
            }
            final minSdkSigned = _leU32(signedData, sdOff);
            final maxSdkSigned = _leU32(signedData, sdOff + 4);
            sdOff += 8;

            // additional attributes
            final attributes = _getSequenceKv(sdReadLv());

            // 2. signer-level min/max sdk (must match signedData)
            if (off + 8 > v3Block.length) {
              throw ApkException('Malformed v3 signer block');
            }
            final minSdk = _leU32(v3Block, off);
            final maxSdk = _leU32(v3Block, off + 4);
            off += 8;

            if (minSdkSigned != minSdk) {
              throw ApkException(
                  'Invalid min_sdk in signing block V3 $minSdkSigned != $minSdk');
            }
            if (maxSdkSigned != maxSdk) {
              throw ApkException(
                  'Invalid max_sdk in signing block V3 $maxSdkSigned != $maxSdk');
            }

            // 3. signatures and public key
            final signatures = _getSequenceKv(readLv());
            final publicKey = readLv();

            final digestsM = {for (final (a, b) in digests) a: b};

            sigs.add(
              ApkSignatureBlock.v3(
                minSdk: minSdk,
                maxSdk: maxSdk,
                signatures: _parseSigs(signatures, digestsM),
                publicKey: Uint8List.fromList(publicKey),
                certificates:
                    certificates.map((e) => Uint8List.fromList(e)).toList(),
                attributes: {
                  for (final (a, b) in attributes) a: Uint8List.fromList(b),
                },
              ),
            );
          }
      }
    }
    return sigs;
  }
}

// ────────────────────────────────────────────────────────────────────────────
//  Signature parsing helpers  (1:1 port of Rust helpers)
// ────────────────────────────────────────────────────────────────────────────

List<ApkSignature> _parseSigs(
  List<(int, Uint8List)> signatures,
  Map<int, Uint8List> digests,
) {
  final out = <ApkSignature>[];
  for (final (k, v) in signatures) {
    if (v.length < 4) continue;
    final sigLen = _leU32(v, 0);
    if (sigLen > v.length - 4) {
      continue;
    }
    final algo = ApkSignatureAlgo.fromValue(k);
    if (algo == null) continue;

    final digestBytes = digests[k];
    if (digestBytes == null || digestBytes.length < 4) continue;

    out.add(
      ApkSignature(
        algo: algo,
        digest: Uint8List.fromList(
          _slice(digestBytes, 4, digestBytes.length - 4),
        ),
        signature: Uint8List.fromList(_slice(v, 4, sigLen)),
      ),
    );
  }
  return out;
}

// ────────────────────────────────────────────────────────────────────────────
//  V2 / V3  blocks  +  pretty printing (Display impl)
// ────────────────────────────────────────────────────────────────────────────

sealed class ApkSignatureBlock {
  const ApkSignatureBlock();

  factory ApkSignatureBlock.v2({
    required List<ApkSignature> signatures,
    required Uint8List publicKey,
    required List<Uint8List> certificates,
    required Map<int, Uint8List> attributes,
  }) = ApkSignatureV2;

  factory ApkSignatureBlock.v3({
    required List<ApkSignature> signatures,
    required Uint8List publicKey,
    required List<Uint8List> certificates,
    required Map<int, Uint8List> attributes,
    required int minSdk,
    required int maxSdk,
  }) = ApkSignatureV3;

  @override
  String toString() => switch (this) {
        ApkSignatureV2(:final signatures) => _fmt('v2', signatures),
        ApkSignatureV3(:final signatures) => _fmt('v3', signatures),
      };

  String _fmt(String h, List<ApkSignature> s) =>
      '$h: ${s.map((e) => e.toString()).join(' ')}';
}

class ApkSignatureV2 extends ApkSignatureBlock {
  final List<ApkSignature> signatures;
  final Uint8List publicKey;
  final List<Uint8List> certificates;
  final Map<int, Uint8List> attributes;
  const ApkSignatureV2({
    required this.signatures,
    required this.publicKey,
    required this.certificates,
    required this.attributes,
  });
}

class ApkSignatureV3 extends ApkSignatureBlock {
  final List<ApkSignature> signatures;
  final Uint8List publicKey;
  final List<Uint8List> certificates;
  final Map<int, Uint8List> attributes;
  final int minSdk;
  final int maxSdk;
  const ApkSignatureV3({
    required this.signatures,
    required this.publicKey,
    required this.certificates,
    required this.attributes,
    required this.minSdk,
    required this.maxSdk,
  });
}

// ────────────────────────────────────────────────────────────────────────────
//  Signature + Algorithm enum
// ────────────────────────────────────────────────────────────────────────────

class ApkSignature {
  final ApkSignatureAlgo algo;
  final Uint8List signature;
  final Uint8List digest;
  const ApkSignature({
    required this.algo,
    required this.signature,
    required this.digest,
  });

  @override
  String toString() =>
      'algo=$algo digest=${hex.encode(digest)} sig=${hex.encode(signature)}';
}

enum ApkSignatureAlgo {
  rsaSsaPssSha256(0x0101, 'RSASSA-PSS-SHA256'),
  rsaSsaPssSha512(0x0102, 'RSASSA-PSS-SHA512'),
  rsaSsaPkcs1Sha256(0x0103, 'RSASSA-PKCS1-SHA256'),
  rsaSsaPkcs1Sha512(0x0104, 'RSASSA-PKCS1-SHA512'),
  ecdsaSha256(0x0201, 'ECDSA-SHA256'),
  ecdsaSha512(0x0202, 'ECDSA-SHA512'),
  dsaSha256(0x0301, 'DSA-SHA256');

  final int value;
  final String pretty;
  const ApkSignatureAlgo(this.value, this.pretty);

  static ApkSignatureAlgo? fromValue(int v) {
    final z = ApkSignatureAlgo.values.firstWhereOrNull((e) => e.value == v);
    return z;
  }

  @override
  String toString() => pretty;
}

// ────────────────────────────────────────────────────────────────────────────
//  Byte-sequence helpers  (get_lv_*  etc.)   – identical logic to Rust
// ────────────────────────────────────────────────────────────────────────────

Uint8List _getLvU32(Uint8List slice) {
  final len = _leU32(slice, 0);
  if (len > slice.length - 4) {
    throw ApkException('Invalid LV sequence $len > ${slice.length}');
  }
  return _slice(slice, 4, len);
}

Uint8List _removePrefixLayers(Uint8List slice) {
  final l1 = _leU32(slice, 0);
  var s = slice;
  while (true) {
    s = _slice(s, 4, s.length - 4);
    final l2 = _leU32(s, 0);
    if (l1 != l2 + 4) {
      return s;
    }
  }
}

List<Uint8List> _getLvSequence(Uint8List slice) {
  final ret = <Uint8List>[];
  var s = slice;
  while (s.length >= 4) {
    final data = _getLvU32(s);
    final rLen = data.length + 4;
    s = _slice(s, rLen, s.length - rLen);
    ret.add(data);
  }
  return ret;
}

List<(int, Uint8List)> _getSequenceKv(Uint8List slice) {
  final seq = _getLvSequence(slice);
  return [for (final s in seq) (_leU32(s, 0), _slice(s, 4, s.length - 4))];
}
