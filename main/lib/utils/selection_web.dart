import 'dart:html' as html;

Future<String?> getSelectedText() async {
  try {
    final sel = html.window.getSelection();
    final text = sel?.toString() ?? '';
    final t = text.trim();
    if (t.isEmpty) return null;
    return t;
  } catch (_) {
    return null;
  }
}

