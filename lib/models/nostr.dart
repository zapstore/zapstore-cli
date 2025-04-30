import 'package:purplebase/purplebase.dart';

typedef App = BaseApp;
typedef Release = BaseRelease;
typedef FileMetadata = BaseFileMetadata;

/// A class similar to the actual PartialApp, using
/// it as a placeholder until we migrate to the new purplebase
class PartialApp {
  String? name;
  String? identifier;
  String? version;
  String? description;
  String? summary;
  String? license;
  String? icon;
  String? repository;
  String? releaseRepository;
  Set<String>? images;
  Set<String>? tags;
  String? releaseNotes;
  String? url;
  Set<PartialFileMetadata> artifacts = {};

  Map<String, dynamic> toMap() {
    return {
      'name': name,
      'identifier': identifier,
      'version': version,
      'description': description,
      'summary': summary,
      'license': license,
      'icon': icon,
      'repository': repository,
      'releaseRepository': releaseRepository,
      'url': url,
      'tags': tags?.toList(),
      'images': images?.toList(),
      'releaseNotes': releaseNotes,
      'artifacts': artifacts.map((artifact) => artifact.toMap()).toList(),
    };
  }
}

class PartialFileMetadata {
  String? identifier;
  String? version;
  String? path;
  Set<String>? platforms;
  Set<String>? signatureHashes;
  String? versionCode;
  String? minSdkVersion;
  String? targetSdkVersion;
  int? size;
  String? url;
  String? hash;
  String? mimeType;
  Set<String> executables = {};

  Map<String, dynamic> toMap() {
    return {
      'identifier': identifier,
      'version': version,
      'path': path,
      'platforms': platforms?.toList(),
      'signatureHashes': signatureHashes?.toList(),
      'versionCode': versionCode,
      'minSdkVersion': minSdkVersion,
      'targetSdkVersion': targetSdkVersion,
      'size': size,
      'url': url,
      'hash': hash,
      'mimeType': mimeType,
      'executables': executables.toList(),
    };
  }
}
