String xbUmeFormatTime(DateTime time) {
  final h = time.hour.toString().padLeft(2, '0');
  final m = time.minute.toString().padLeft(2, '0');
  final s = time.second.toString().padLeft(2, '0');
  final ms = time.millisecond.toString().padLeft(3, '0');
  return '$h:$m:$s.$ms';
}
