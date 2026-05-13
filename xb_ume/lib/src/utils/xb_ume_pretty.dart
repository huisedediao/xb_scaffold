import 'dart:convert';

String xbUmePreview(dynamic value, {int maxLength = 4000}) {
  if (value == null) return '<null>';
  String text;
  if (value is String) {
    text = value;
  } else {
    try {
      text = const JsonEncoder.withIndent('  ').convert(value);
    } catch (_) {
      text = value.toString();
    }
  }
  if (text.length <= maxLength) return text;
  return '${text.substring(0, maxLength)}...<clipped>';
}
