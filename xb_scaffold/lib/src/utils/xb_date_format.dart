class XBDateFormat {
  final String pattern;

  const XBDateFormat(this.pattern);

  String format(DateTime dateTime) {
    return pattern
        .replaceAll('yyyy', dateTime.year.toString().padLeft(4, '0'))
        .replaceAll('MM', dateTime.month.toString().padLeft(2, '0'))
        .replaceAll('dd', dateTime.day.toString().padLeft(2, '0'))
        .replaceAll('HH', dateTime.hour.toString().padLeft(2, '0'))
        .replaceAll('mm', dateTime.minute.toString().padLeft(2, '0'))
        .replaceAll('ss', dateTime.second.toString().padLeft(2, '0'));
  }

  DateTime parse(String dateTimeStr) {
    final parts = _parsePatternParts();
    final regexParts = <String>[];
    for (final part in parts) {
      switch (part) {
        case 'yyyy':
          regexParts.add(r'(\d{4})');
          break;
        case 'MM':
        case 'dd':
        case 'HH':
        case 'mm':
        case 'ss':
          regexParts.add(r'(\d{2})');
          break;
        default:
          regexParts.add(RegExp.escape(part));
      }
    }
    final regex = RegExp('^${regexParts.join()}\$');
    final match = regex.firstMatch(dateTimeStr);
    if (match == null) {
      throw FormatException(
        'Invalid date format: $dateTimeStr (expected: $pattern)',
      );
    }

    int year = 0, month = 1, day = 1, hour = 0, minute = 0, second = 0;
    int gi = 1;
    for (final part in parts) {
      switch (part) {
        case 'yyyy':
          year = int.parse(match.group(gi++)!);
          break;
        case 'MM':
          month = int.parse(match.group(gi++)!);
          break;
        case 'dd':
          day = int.parse(match.group(gi++)!);
          break;
        case 'HH':
          hour = int.parse(match.group(gi++)!);
          break;
        case 'mm':
          minute = int.parse(match.group(gi++)!);
          break;
        case 'ss':
          second = int.parse(match.group(gi++)!);
          break;
        default:
          break;
      }
    }
    return DateTime(year, month, day, hour, minute, second);
  }

  List<String> _parsePatternParts() {
    final parts = <String>[];
    int i = 0;
    while (i < pattern.length) {
      bool matched = false;
      for (final token in const ['yyyy', 'MM', 'dd', 'HH', 'mm', 'ss']) {
        if (pattern.startsWith(token, i)) {
          parts.add(token);
          i += token.length;
          matched = true;
          break;
        }
      }
      if (!matched) {
        parts.add(pattern[i]);
        i++;
      }
    }
    return parts;
  }
}
