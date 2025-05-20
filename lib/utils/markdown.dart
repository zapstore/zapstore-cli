import 'package:markdown/markdown.dart' as md;
import 'package:tint/tint.dart';

/// Converts a Markdown string to an ANSI-coloured string that can be
/// printed directly to a terminal.
///
/// Example:
/// ```dart
/// print(renderMarkdown('# Hello **World**'));
/// ```
String mdToTerminal(String source) {
  // Turn Markdown into a list of AST nodes.
  final nodes = md.Document().parseLines(source.split('\n'));

  final out = StringBuffer();

  void walk(md.Node node) {
    if (node is md.Element) {
      switch (node.tag) {
        case 'h1':
          out.writeln(node.textContent.bold().underline().magenta());
          out.writeln();
          break;

        case 'h2':
          out.writeln(node.textContent.bold().cyan());
          out.writeln();
          break;

        case 'p':
          node.children?.forEach(walk);
          out.writeln('\n');
          break;

        case 'strong':
          out.write(node.textContent.bold());
          break;

        case 'em':
          out.write(node.textContent.italic());
          break;

        case 'code':
          out.write(node.textContent.brightBlue());
          break;

        case 'ul':
          node.children?.forEach(walk);
          out.writeln();
          break;

        case 'li':
          out.write('• ');
          node.children?.forEach(walk);
          out.writeln();
          break;

        default:
          node.children?.forEach(walk);
      }
    } else if (node is md.Text) {
      out.write(node.text);
    }
  }

  for (final n in nodes) {
    walk(n);
  }

  return out.toString();
}
