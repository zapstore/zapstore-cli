// ignore_for_file: constant_identifier_names

import 'dart:typed_data';
import 'dart:convert';

/// Events emitted by [AxmlParser] when reading through a binary XML stream.
enum AxmlEvent { startDoc, startTag, endTag, text, endDoc, error }

/// Internal attribute representation.
class _Attribute {
  final int uri;
  final int name;
  final int stringIndex;
  final int type;
  final int data;
  _Attribute(this.uri, this.name, this.stringIndex, this.type, this.data);
}

/// Internal attribute stack node.
class _AttrStack {
  final List<_Attribute> list;
  _AttrStack? next;
  _AttrStack(this.list, [this.next]);
}

/// Internal namespace record.
class _NsRecord {
  final int prefix;
  final int uri;
  _NsRecord? next;
  _NsRecord(this.prefix, this.uri, [this.next]);
}

/// A Dart port of AxmlParser.c for parsing Android binary XML (AXML) files.
/// https://github.com/mARTini2020/AxmlParser
class AxmlParser {
  // Chunk magic numbers
  static const int _CHUNK_HEAD = 0x00080003;
  static const int _CHUNK_STRING = 0x001c0001;
  static const int _CHUNK_RESOURCE = 0x00080180;
  static const int _CHUNK_STARTNS = 0x00100100;
  static const int _CHUNK_ENDNS = 0x00100101;
  static const int _CHUNK_STARTTAG = 0x00100102;
  static const int _CHUNK_ENDTAG = 0x00100103;
  static const int _CHUNK_TEXT = 0x00100104;

  // Attribute type constants
  static const int ATTR_NULL = 0;
  static const int ATTR_REFERENCE = 1;
  static const int ATTR_ATTRIBUTE = 2;
  static const int ATTR_STRING = 3;
  static const int ATTR_FLOAT = 4;
  static const int ATTR_DIMENSION = 5;
  static const int ATTR_FRACTION = 6;
  static const int ATTR_FIRSTINT = 16;
  static const int ATTR_DEC = 16;
  static const int ATTR_HEX = 17;
  static const int ATTR_BOOLEAN = 18;
  static const int ATTR_FIRSTCOLOR = 28;
  static const int ATTR_ARGB8 = 28;
  static const int ATTR_RGB8 = 29;
  static const int ATTR_ARGB4 = 30;
  static const int ATTR_RGB4 = 31;
  static const int ATTR_LASTCOLOR = 31;
  static const int ATTR_LASTINT = 31;

  static const int UTF8_FLAG = 1 << 8;

  static const List<double> _radixTable = [
    0.00390625,
    0.00003051758,
    0.0000001192093,
    4.656613e-10
  ];
  static const List<String> _dimensionTable = [
    'px',
    'dip',
    'sp',
    'pt',
    'in',
    'mm',
    '',
    ''
  ];
  static const List<String> _fractionTable = [
    '%',
    '%p',
    '',
    '',
    '',
    '',
    '',
    ''
  ];

  final Uint8List _buf;
  final ByteData _data;
  final int _size;
  int _cur = 0;

  int _stringCount = 0;
  late List<int> _stringOffsets;
  late Uint8List _stringData;
  late List<String?> _strings;
  bool _isUTF8 = false;

  _NsRecord? _nsList;
  bool _nsNew = false;

  int _tagName = -1;
  int _tagUri = -1;
  int _textIndex = -1;

  _AttrStack? _attrStack;
  bool _started = false;

  /// Constructs a parser over the raw AXML byte buffer.
  AxmlParser(Uint8List buffer)
      : _buf = buffer,
        _data = buffer.buffer.asByteData(),
        _size = buffer.length {
    _parseHeadChunk();
    _parseStringChunk();
    _parseResourceChunk();
  }

  int _getInt32() {
    final v = _data.getUint32(_cur, Endian.little);
    _cur += 4;
    return v;
  }

  void _skipInt32(int count) {
    _cur += 4 * count;
  }

  bool _noMoreData() => _cur >= _size;

  void _parseHeadChunk() {
    final magic = _getInt32();
    if (magic != _CHUNK_HEAD) {
      throw Exception('Invalid AXML file (missing CHUNK_HEAD)');
    }
    final fileSize = _getInt32();
    if (fileSize != _size) {
      throw Exception('Incomplete AXML file (size mismatch)');
    }
  }

  void _parseStringChunk() {
    final type = _getInt32();
    if (type != _CHUNK_STRING) {
      throw Exception('Not a valid string chunk');
    }
    final chunkSize = _getInt32();
    _stringCount = _getInt32();
    final styleCount = _getInt32();
    final flags = _getInt32();
    _isUTF8 = (flags & UTF8_FLAG) != 0;
    final stringOffset = _getInt32();
    final styleOffset = _getInt32();

    _stringOffsets = List<int>.filled(_stringCount, 0);
    for (var i = 0; i < _stringCount; i++) {
      _stringOffsets[i] = _getInt32();
    }
    _strings = List<String?>.filled(_stringCount, null);

    if (styleCount > 0) {
      _skipInt32(styleCount);
    }
    final dataLen =
        ((styleOffset != 0 ? styleOffset : chunkSize) - stringOffset);
    _stringData = _buf.sublist(_cur, _cur + dataLen);
    _cur += dataLen;
    if (styleOffset != 0) {
      _skipInt32((chunkSize - styleOffset) ~/ 4);
    }
  }

  void _parseResourceChunk() {
    final type = _getInt32();
    if (type != _CHUNK_RESOURCE) {
      throw Exception('Not a valid resource chunk');
    }
    final chunkSize = _getInt32();
    if (chunkSize % 4 != 0) {
      throw Exception('Invalid resource chunk size');
    }
    _skipInt32(chunkSize ~/ 4 - 2);
  }

  /// Returns the string at index [id] from the string pool, decoding UTF-8 or UTF-16LE as needed.
  String _getString(int id) {
    if (id < 0 || id >= _stringCount) return '';
    final cached = _strings[id];
    if (cached != null) return cached;
    final start = _stringOffsets[id];
    final end =
        (id + 1 < _stringCount ? _stringOffsets[id + 1] : _stringData.length);
    String str;
    if (_isUTF8) {
      final bytes = _stringData.sublist(start + 2, end);
      str = utf8.decode(bytes, allowMalformed: true);
    } else {
      final bd = ByteData.view(_stringData.buffer);
      final codeUnits = <int>[];
      for (var pos = start + 2; pos + 1 < end; pos += 2) {
        final cu = bd.getUint16(pos, Endian.little);
        if (cu == 0) break;
        codeUnits.add(cu);
      }
      str = String.fromCharCodes(codeUnits);
    }
    _strings[id] = str;
    return str;
  }

  /// Reads the next event from the stream.
  AxmlEvent next() {
    if (!_started) {
      _started = true;
      return AxmlEvent.startDoc;
    }
    if (_noMoreData()) {
      return AxmlEvent.endDoc;
    }

    final chunkType = _getInt32();
    _skipInt32(1); // skip chunk size
    _skipInt32(1); // skip line number
    _skipInt32(1); // skip unknown

    if (chunkType == _CHUNK_STARTTAG) {
      final uri = _getInt32();
      final name = _getInt32();
      _skipInt32(1); // flags
      final count = _getInt32() & 0xFFFF;
      _skipInt32(1); // classAttr

      final attrs = <_Attribute>[];
      for (var i = 0; i < count; i++) {
        final aUri = _getInt32();
        final aName = _getInt32();
        final aString = _getInt32();
        final aType = _getInt32() >> 24;
        final aData = _getInt32();
        attrs.add(_Attribute(aUri, aName, aString, aType, aData));
      }
      _attrStack = _AttrStack(attrs, _attrStack);
      _tagUri = uri;
      _tagName = name;
      return AxmlEvent.startTag;
    } else if (chunkType == _CHUNK_ENDTAG) {
      final uri = _getInt32();
      final name = _getInt32();
      _tagUri = uri;
      _tagName = name;
      if (_attrStack != null) {
        _attrStack = _attrStack!.next;
      }
      return AxmlEvent.endTag;
    } else if (chunkType == _CHUNK_STARTNS) {
      final prefix = _getInt32();
      final uri = _getInt32();
      _nsList = _NsRecord(prefix, uri, _nsList);
      _nsNew = true;
      return next();
    } else if (chunkType == _CHUNK_ENDNS) {
      _skipInt32(1);
      _skipInt32(1);
      if (_nsList != null) {
        _nsList = _nsList!.next;
      }
      return next();
    } else if (chunkType == _CHUNK_TEXT) {
      _textIndex = _getInt32();
      _skipInt32(2);
      return AxmlEvent.text;
    } else {
      return AxmlEvent.error;
    }
  }

  /// Returns the current tag's name.
  String getTagName() => _getString(_tagName);

  /// Returns the prefix for the current tag if any.
  String getTagPrefix() {
    var ns = _nsList;
    while (ns != null) {
      if (ns.uri == _tagUri) {
        return _getString(ns.prefix);
      }
      ns = ns.next;
    }
    return '';
  }

  /// Returns text content when event is [AxmlEvent.text].
  String getText() => _getString(_textIndex);

  /// Number of attributes in the current start tag.
  int getAttrCount() => _attrStack?.list.length ?? 0;

  /// Returns attribute prefix at index [i], if any.
  String getAttrPrefix(int i) {
    final a = _attrStack!.list[i];
    var ns = _nsList;
    while (ns != null) {
      if (ns.uri == a.uri) {
        return _getString(ns.prefix);
      }
      ns = ns.next;
    }
    return '';
  }

  /// Returns attribute name at index [i].
  String getAttrName(int i) => _getString(_attrStack!.list[i].name);

  /// Returns attribute value (string or formatted) at index [i].
  String getAttrValue(int i) {
    final a = _attrStack!.list[i];
    final type = a.type;
    final data = a.data;

    if (type == ATTR_STRING) {
      return _getString(a.stringIndex);
    } else if (type == ATTR_NULL) {
      return '';
    } else if (type == ATTR_REFERENCE) {
      final pfx = (data >> 24) == 1 ? '@android:' : '@';
      return '$pfx${data.toRadixString(16).toUpperCase().padLeft(8, '0')}';
    } else if (type == ATTR_ATTRIBUTE) {
      final pfx = (data >> 24) == 1 ? '?android:' : '?';
      return '$pfx${data.toRadixString(16).toUpperCase().padLeft(8, '0')}';
    } else if (type == ATTR_FLOAT) {
      final bd = ByteData(4)..setUint32(0, data, Endian.little);
      final f = bd.getFloat32(0, Endian.little);
      return f.toString();
    } else if (type == ATTR_DIMENSION) {
      final f = (data & 0xFFFFFF00) * _radixTable[(data >> 4) & 0x03];
      final u = _dimensionTable[data & 0x0F];
      return '$f$u';
    } else if (type == ATTR_FRACTION) {
      final f = (data & 0xFFFFFF00) * _radixTable[(data >> 4) & 0x03];
      final u = _fractionTable[data & 0x0F];
      return '$f$u';
    } else if (type >= ATTR_FIRSTCOLOR && type <= ATTR_LASTCOLOR) {
      return '#${data.toRadixString(16).padLeft(8, '0')}';
    } else if (type >= ATTR_FIRSTINT && type <= ATTR_LASTINT) {
      return data.toString();
    } else {
      return '<0x${data.toRadixString(16)}, type 0x${type.toRadixString(16).padLeft(2, '0')}>';
    }
  }

  /// Returns true if a new namespace was declared at this start tag.
  bool newNamespace() {
    if (_nsNew) {
      _nsNew = false;
      return true;
    }
    return false;
  }

  /// Returns current namespace prefix.
  String getNsPrefix() => _nsList != null ? _getString(_nsList!.prefix) : '';

  /// Returns current namespace URI.
  String getNsUri() => _nsList != null ? _getString(_nsList!.uri) : '';

  /// Converts the entire binary XML [bytes] into a UTF-8 XML string.
  static String toXml(Uint8List bytes) {
    final parser = AxmlParser(bytes);
    final sb = StringBuffer();
    int tabCnt = 0;

    AxmlEvent evt;
    while ((evt = parser.next()) != AxmlEvent.endDoc) {
      switch (evt) {
        case AxmlEvent.startDoc:
          sb.writeln('<?xml version="1.0" encoding="utf-8"?>');
          break;
        case AxmlEvent.startTag:
          sb.write(' ' * (tabCnt * 4));
          tabCnt++;
          final p = parser.getTagPrefix();
          final n = parser.getTagName();
          if (p.isNotEmpty) {
            sb.write('<$p:$n');
          } else {
            sb.write('<$n');
          }
          if (parser.newNamespace()) {
            var ns = parser._nsList;
            while (ns != null) {
              final pp = parser._getString(ns.prefix);
              final uu = parser._getString(ns.uri);
              sb.write(' xmlns:$pp="$uu"');
              ns = ns.next;
            }
          }
          for (var i = 0; i < parser.getAttrCount(); i++) {
            final ap = parser.getAttrPrefix(i);
            final an = parser.getAttrName(i);
            final av = parser.getAttrValue(i);
            if (ap.isNotEmpty) {
              sb.write(' $ap:$an="$av"');
            } else {
              sb.write(' $an="$av"');
            }
          }
          sb.writeln('>');
          break;
        case AxmlEvent.endTag:
          tabCnt--;
          sb.write(' ' * (tabCnt * 4));
          final p2 = parser.getTagPrefix();
          final n2 = parser.getTagName();
          if (p2.isNotEmpty) {
            sb.writeln('</$p2:$n2>');
          } else {
            sb.writeln('</$n2>');
          }
          break;
        case AxmlEvent.text:
          sb.writeln(parser.getText());
          break;
        case AxmlEvent.error:
          throw Exception('AXML parse error');
        default:
          break;
      }
    }
    return sb.toString();
  }
}
