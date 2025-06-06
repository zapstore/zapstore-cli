import 'dart:convert';
import 'dart:io';
import 'package:models/models.dart';
import 'package:path/path.dart' as path;
import 'package:zapstore_cli/utils/file_utils.dart';

class HtmlPreview {
  final PartialApp app;

  HtmlPreview(this.app);

  Future<String> build() async {
    final icon = await _getBase64Image(app.icons.first);
    final images = await Future.wait(app.images.map((p) => _getBase64Image(p)));

    return '''
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>${app.name ?? 'App Preview'}</title>
    <style>
        body {
            font-family: sans-serif;
            margin: 0;
            background-color: #f4f4f9;
            color: #333;
        }
        .container {
            max-width: 800px;
            margin: 20px auto;
            padding: 20px;
            background-color: #fff;
            border-radius: 8px;
            box-shadow: 0 2px 4px rgba(0,0,0,0.1);
        }
        .header {
            display: flex;
            align-items: center;
            margin-bottom: 20px;
        }
        .header img {
            width: 128px;
            height: 128px;
            border-radius: 12px;
            margin-right: 20px;
        }
        .header h1 {
            font-size: 2.5em;
            margin: 0;
        }
        .app-info {
            margin-bottom: 20px;
        }
        .app-info h2 {
            font-size: 1.5em;
            border-bottom: 2px solid #eee;
            padding-bottom: 5px;
            margin-bottom: 10px;
        }
        .app-info p, .app-info a {
            font-size: 1.1em;
            line-height: 1.6;
        }
        .app-info a {
          color: #007BFF;
          text-decoration: none;
        }
        .app-info a:hover {
          text-decoration: underline;
        }
        .screenshots {
          margin-top: 20px;
        }
        .screenshots h2 {
          font-size: 1.5em;
          border-bottom: 2px solid #eee;
          padding-bottom: 5px;
          margin-bottom: 10px;
        }
        .screenshots img {
          max-width: 100%;
          border-radius: 8px;
          margin-bottom: 10px;
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            ${icon.isNotEmpty ? '<img src="data:image/png;base64,$icon" alt="App Icon">' : ''}
            <h1>${app.name ?? ''}</h1>
        </div>
        <div class="app-info">
            <h2>Summary</h2>
            <p>${app.summary ?? ''}</p>

            <h2>Description</h2>
            <p>${app.description}</p>

            ${_buildInfoSection('Repository', app.repository)}
            ${_buildInfoSection('Website', app.url)}
            ${_buildInfoSection('License', app.license)}
        </div>
        ${images.isNotEmpty ? '<div class="screenshots"><h2>Screenshots</h2>${images.map((img) => '<img src="data:image/png;base64,$img">').join('')}</div>' : ''}
    </div>
</body>
</html>
    ''';
  }

  String _buildInfoSection(String title, String? value) {
    if (value == null || value.isEmpty) return '';
    if (Uri.tryParse(value)?.isAbsolute ?? false) {
      return '<h2>$title</h2><p><a href="$value" target="_blank">$value</a></p>';
    }
    return '<h2>$title</h2><p>$value</p>';
  }

  Future<String> _getBase64Image(String hash) async {
    try {
      final file = File(getFilePathInTempDirectory(hash));
      if (await file.exists()) {
        final bytes = await file.readAsBytes();
        return base64Encode(bytes);
      }
    } catch (e) {
      // Ignore errors, maybe log them in the future
    }
    return '';
  }

  static Future<void> generate(PartialApp app) async {
    final preview = HtmlPreview(app);
    final htmlContent = await preview.build();
    final tempDir = Directory.systemTemp.createTempSync('zapstore_preview');
    final filePath = path.join(tempDir.path, 'preview.html');
    final file = File(filePath);
    await file.writeAsString(htmlContent);
    print('Preview saved to: $filePath');
  }
}
