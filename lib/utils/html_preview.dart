import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:markdown/markdown.dart' as md;
import 'package:models/models.dart';
import 'package:zapstore_cli/utils/file_utils.dart';

class HtmlPreview {
  final List<PartialModel> models;

  HtmlPreview(this.models);

  String renderMarkdown(String? text) {
    if (text == null || text.isEmpty) return '';
    return md.markdownToHtml(text, inlineSyntaxes: [md.InlineHtmlSyntax()]);
  }

  Future<String> build() async {
    final app = models.whereType<PartialApp>().first;
    final release = models.whereType<PartialRelease>().firstOrNull;
    final files = models.whereType<PartialFileMetadata>();

    final icon =
        app.icons.isNotEmpty ? await _getBase64Image(app.icons.first) : '';
    final images = await Future.wait(app.images.map((p) => _getBase64Image(p)));

    return '''
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>${app.name ?? 'App Preview'}</title>
    <style>
        :root {
            --background-color: #121212;
            --surface-color: #1E1E1E;
            --primary-color: #BB86FC;
            --primary-variant-color: #3700B3;
            --secondary-color: #03DAC6;
            --on-background-color: #E0E0E0;
            --on-surface-color: #FFFFFF;
            --border-color: #2c2c2c;
        }
        body {
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
            margin: 0;
            background-color: var(--background-color);
            color: var(--on-background-color);
        }
        .container {
            max-width: 960px;
            margin: 20px auto;
            padding: 24px;
            background-color: var(--surface-color);
            border-radius: 12px;
            box-shadow: 0 4px 12px rgba(0,0,0,0.4);
        }
        .header {
            display: flex;
            align-items: center;
            margin: 24px 0;
            padding: 24px 0;
        }
        .header img {
            width: 96px;
            height: 96px;
            border-radius: 20px;
            margin-right: 24px;
            box-shadow: 0 2px 6px rgba(0,0,0,0.5);
        }
        .header h1 {
            font-size: 2.2em;
            font-weight: 700;
            margin: 0;
            color: var(--on-surface-color);
        }
        .section {
          margin: 24px 0;
        }
        .section h2 {
            font-size: 1.6em;
            font-weight: 600;
            color: var(--primary-color);
            border-bottom: 2px solid var(--primary-color);
            padding-bottom: 8px;
            margin-top: 0;
            margin-bottom: 16px;
        }
        .info-grid {
          display: grid;
          grid-template-columns: repeat(auto-fit, minmax(300px, 1fr));
          gap: 16px;
        }
        .info-item, .file-item {
          background-color: #2a2a2a;
          border-radius: 8px;
          padding: 16px;
          display: flex;
          flex-direction: column;
        }
        .info-item strong {
          display: block;
          color: #aaa;
          margin-bottom: 4px;
        }
        .info-item p, .info-item a, .info-item code {
          font-size: 1em;
          line-height: 1.5;
          margin: 0;
          word-break: break-all;
        }
        .file-item strong {
            font-size: 1.1em;
            margin-bottom: 8px;
            color: var(--secondary-color);
        }
        .file-item code, .file-item span {
            font-family: 'SF Mono', 'Menlo', 'Monaco', 'Consolas', monospace;
            font-size: 0.85em;
            word-break: break-all;
        }
        a {
            color: var(--secondary-color);
            text-decoration: none;
        }
        a:hover {
            text-decoration: underline;
        }
        .screenshots {
          display: grid;
          grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
          gap: 16px;
          margin-top: 24px;
        }
        .screenshots img {
          max-width: 100%;
          border-radius: 8px;
          box-shadow: 0 2px 4px rgba(0,0,0,0.3);
        }
        .markdown {
          line-height: 1.6;
        }
        .markdown p:first-child, .markdown h1:first-child, .markdown h2:first-child, .markdown h3:first-child {
            margin-top: 0;
        }
        .markdown p:last-child {
            margin-bottom: 0;
        }
    </style>
</head>
<body>
    <div class="container">
        <h1>Zapstore Publish Preview Page</h1>
        <h3>Confirm the preview below is correct and proceed to signing in the command line</h3>
                
        <div class="section">
            <h2>App</h2>
            <div class="header">
                ${icon.isNotEmpty ? '<img src="data:image/png;base64,$icon" alt="App Icon">' : ''}
                <h1>${app.name ?? ''}</h1>
            </div>
            <div class="info-grid">
              ${_buildInfoItem('Identifier', app.identifier, code: true)}
              ${_buildInfoItem('Summary', app.summary)}
              ${_buildInfoLink('Repository', app.repository)}
              ${_buildInfoLink('Website', app.url)}
              ${_buildInfoItem('License', app.license)}
              ${_buildInfoItem('Platforms', app.platforms.join(', '))}
            </div>
             <div class="markdown" style="margin-top: 16px;">
                <strong>${app.description != null ? 'Description' : ''}</strong>
                ${renderMarkdown(app.description)}
            </div>
            ${images.isNotEmpty ? '''
            <div class="screenshots">
              ${images.map((img) => '<img src="data:image/png;base64,$img">').join('')}
            </div>''' : ''}
        </div>

        ${release != null ? _buildReleaseSection(release) : ''}
        
        ${files.isNotEmpty ? _buildFilesSection(files) : ''}

    </div>
</body>
</html>
    ''';
  }

  String _buildReleaseSection(PartialRelease release) {
    return '''
    <div class="section">
      <h2>Release</h2>
      <div class="info-grid">
        ${_buildInfoLink('Version', release.version)}
        ${_buildInfoLink('URL', release.url)}
      </div>
      <div class="info-item markdown" style="margin-top: 16px;">
        <strong>${release.releaseNotes != null ? 'Release Notes' : ''}</strong>
         ${renderMarkdown(release.releaseNotes)}
      </div>
    </div>''';
  }

  String _buildFilesSection(Iterable<PartialFileMetadata> files) {
    return '''
    <div class="section">
        <h2>Assets</h2>
        <div class="info-grid">
          ${files.map((file) => _buildFileInfo(file)).join('')}
        </div>
    </div>
    ''';
  }

  String _buildFileInfo(PartialFileMetadata file) {
    return '''
    <div class="file-item">
      ${_buildInfoItem('Platforms', file.platforms.join(', '))}
      ${_buildInfoItem('Hash (SHA256)', file.hash, code: true)}
      ${_buildInfoItem('Size', file.size?.toString(), code: true)}
      ${_buildInfoItem('MIME Type', file.mimeType, code: true)}
      ${_buildInfoItem('Min OS/SDK Version', file.minSdkVersion, code: true)}
      ${_buildInfoItem('Target OS/SDK Version', file.targetSdkVersion, code: true)}
      ${_buildInfoItem('APK Signature hash', file.apkSignatureHash, code: true)}
       <div class="info-item">
        <strong>URLs (some assets not yet uploaded)</strong>
        ${file.urls.map((u) => '<a href="$u" target="_blank">$u</a>').join('<br>')}
      </div>
    </div>
    ''';
  }

  String _buildInfoItem(String title, String? value, {bool code = false}) {
    if (value == null || value.isEmpty) return '';
    final content = code ? '<code>$value</code>' : '<p>$value</p>';
    return '<div class="info-item"><strong>$title</strong>$content</div>';
  }

  String _buildInfoLink(String title, String? value) {
    if (value == null || value.isEmpty) return '';
    if (Uri.tryParse(value)?.isAbsolute ?? false) {
      return '<div class="info-item"><strong>$title</strong><a href="$value" target="_blank">$value</a></div>';
    }
    return _buildInfoItem(title, value);
  }

  Future<String> _getBase64Image(String hash) async {
    try {
      final file = File(getFilePathInTempDirectory(hash));
      if (await file.exists()) {
        final bytes = await file.readAsBytes();
        return base64Encode(bytes);
      }
    } catch (e) {
      // Ignore errors
    }
    return '';
  }

  static Future<Isolate> startServer(Iterable<PartialModel> partialModels) {
    final completer = Completer<Isolate>();
    final receivePort = ReceivePort();
    Isolate? isolate;

    receivePort.listen((message) {
      if (message is String) {
        if (message.startsWith('http')) {
          stderr.writeln('✅ Preview server running at $message');
          if (!completer.isCompleted && isolate != null) {
            completer.complete(isolate);
          }
        } else {
          stderr.writeln('❌ $message');
          if (!completer.isCompleted) {
            completer.completeError(Exception(message));
          }
        }
      }
    });

    Isolate.spawn(
      _serverIsolate,
      [receivePort.sendPort, partialModels.toList()],
    ).then((iso) {
      isolate = iso;
      // We'll complete the future when we get the URL message back.
    }).catchError((e) {
      if (!completer.isCompleted) {
        completer.completeError(e);
      }
    });

    return completer.future;
  }

  static void _serverIsolate(List<dynamic> args) async {
    final mainSendPort = args[0] as SendPort;
    final partialModels = args[1] as List<PartialModel>;

    try {
      final preview = HtmlPreview(partialModels);
      final htmlContent = await preview.build();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final url = 'http://${server.address.host}:${server.port}';
      mainSendPort.send(url);
      _openBrowser(url);

      server.listen((HttpRequest request) async {
        if (request.uri.path == '/') {
          request.response
            ..statusCode = HttpStatus.ok
            ..headers.contentType = ContentType.html
            ..write(htmlContent);
        } else {
          request.response
            ..statusCode = HttpStatus.notFound
            ..write('Not Found');
        }
        await request.response.close();
      });
    } catch (e) {
      mainSendPort.send("Failed to start preview server: $e");
    }
  }

  static Future<void> _openBrowser(String url) async {
    try {
      if (Platform.isMacOS) {
        await Process.run('open', [url]);
      } else if (Platform.isLinux) {
        await Process.run('xdg-open', [url]);
      } else if (Platform.isWindows) {
        await Process.run('start', [url], runInShell: true);
      }
    } catch (e) {
      rethrow;
    }
  }
}
