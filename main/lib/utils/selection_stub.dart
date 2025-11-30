import 'package:flutter/services.dart';

Future<String?> getSelectedText() async {
  // Fallback: Try clipboard text (user may copy selection manually)
  try {
    final data = await Clipboard.getData('text/plain');
    final text = data?.text?.trim();
    if (text == null || text.isEmpty) return null;
    return text;
  } catch (_) {
    return null;
  }
}

