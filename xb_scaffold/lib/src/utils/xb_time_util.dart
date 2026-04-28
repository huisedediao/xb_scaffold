import 'package:intl/intl.dart';

class XBTimeUtil {
  static String formatYMDHMS = 'yyyy-MM-dd HH:mm:ss';
  static String formatNameYMDHMS = 'yyyyMMdd_HHmmss';
  static String formatYMD = 'yyyy-MM-dd';
  static String formatYM = 'yyyy-MM';
  static String formatY = 'yyyy';
  static String formatHMS = 'HH:mm:ss';
  static String formatHM = 'HH:mm';
  static String formatMS = 'mm:ss';

  /// 当前时间的时间戳，单位毫秒
  static int get nowMillis => DateTime.now().millisecondsSinceEpoch;

  /// 当前时间的格式化字符串
  static String nowTimeStr({String? format}) =>
      dateTime2Str(dateTime: DateTime.now(), format: format);

  /// 格式化字符串
  static String dateTime2Str({required DateTime dateTime, String? format}) {
    var formatter = DateFormat(format ?? formatYMDHMS);
    String formatted = formatter.format(dateTime);
    return formatted;
  }

  static bool isToday(DateTime dateTime) {
    DateTime now = DateTime.now();
    return dateTime.year == now.year &&
        dateTime.month == now.month &&
        dateTime.day == now.day;
  }

  /// 日期字符串转成DateTime
  static DateTime? str2DateTime({required String dateTimeStr, String? format}) {
    var formatter = DateFormat(format ?? formatYMDHMS);
    DateTime dateTime = formatter.parse(dateTimeStr);
    return dateTime;
  }

  /// 把秒数转成分秒
  /// 最大只能为3599
  static List<int> secondMSListLessOneHour(int second) {
    final m = second ~/ 60;
    final s = second % 60;
    final ret = [m, s];

    return ret;
  }

  static String formatSecondsToHMS(int seconds) {
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final s = seconds % 60;

    if (h > 0) {
      return '${h.toString().padLeft(2, '0')}:'
          '${m.toString().padLeft(2, '0')}:'
          '${s.toString().padLeft(2, '0')}';
    } else {
      return '${m.toString().padLeft(2, '0')}:'
          '${s.toString().padLeft(2, '0')}';
    }
  }

  /// 秒数转时分秒
  static String second2HMS(
      {required int second,
      String hUnit = ":",
      String mUnit = ":",
      String sUnit = "",
      bool fillZero = true,
      bool omitZero = false}) {
    Duration duration = Duration(seconds: second);
    int hours = duration.inHours;
    int minutes = duration.inMinutes.remainder(60);
    int secondsRemaining = duration.inSeconds.remainder(60);

    String hoursStr = fillZeroStr(hours, fillZero);
    String minutesStr = fillZeroStr(minutes, fillZero);
    String secondsStr = fillZeroStr(secondsRemaining, fillZero);

    if (!omitZero) {
      String time = "$hoursStr$hUnit$minutesStr$mUnit$secondsStr$sUnit";
      return time;
    } else {
      String time = "";
      if (hours != 0) {
        time += "$hoursStr$hUnit";
      }
      if (time.isNotEmpty || minutes != 0) {
        time += "$minutesStr$mUnit";
      }
      if (time.isNotEmpty || secondsRemaining != 0) {
        time += "$secondsStr$sUnit";
      }

      /// 如果没有时间，则返回秒数
      if (time.isEmpty) {
        time += "$secondsStr$sUnit";
      }
      return time;
    }
  }

  /// 补0
  static String fillZeroStr(int num, bool fillZero) =>
      fillZero ? num.toString().padLeft(2, '0') : num.toString();

  /// DateTime 转换为百分比
  /// 只比较同一天的情况，如果不是同一天并且比当前时间大，则返回1(23:59:59)，如果不是同一天并且比当前时间小，则返回0
  static double timeToPercentage(
      {required DateTime time, int? baseYear, int? baseMonth, int? baseDay}) {
    baseYear ??= time.year;
    baseMonth ??= time.month;
    baseDay ??= time.day;
    if (time.year > baseYear || time.month > baseMonth || time.day > baseDay) {
      double secondsOneDay = 24 * 60 * 60;
      double percent = (secondsOneDay - 1) / secondsOneDay;
      return percent;
      // return 1;
    }
    if (time.year < baseYear || time.month < baseMonth || time.day < baseDay) {
      return 0;
    }
    // if (time.year < baseYear || time.month < baseMonth || time.day < baseDay) {
    //   final daySeconds = time.hour * 60 * 60 + time.minute * 60 + time.second;
    //   return -1.0 * (24 * 60 * 60 - daySeconds) / (24 * 60 * 60);
    // }
    final ret = 1.0 *
        (time.hour * 60 * 60 + time.minute * 60 + time.second) /
        (24 * 60 * 60);
    return ret;
  }

  /// 秒数转成百分比
  static double secondToPercentage(int second) {
    return 1.0 * second / (24 * 60 * 60);
  }

  /// 百分比转成秒数
  static int secondCountForPercent(double percentage) {
    int totalSeconds = (percentage * 86400).round();
    return totalSeconds;
  }

  /// 百分比转成当天的时间
  /// HH:mm:ss
  static String convertPercentageToTime(double percentage) {
    // 一天有86400秒
    int totalSeconds = secondCountForPercent(percentage);

    int hours = totalSeconds ~/ 3600;
    totalSeconds %= 3600;
    int minutes = totalSeconds ~/ 60;
    int seconds = totalSeconds % 60;

    return [hours, minutes, seconds]
        .map((element) => element.remainder(60).toString().padLeft(2, '0'))
        .join(':');
  }

  /// 把一天开始的秒数，转成DateTime
  static DateTime dateTimeForDaySecond(
      {required int daySecond, int? year, int? month, int? day}) {
    // 获取当前日期
    DateTime now = DateTime.now();
    // 计算当天的时间戳
    DateTime todayTimestamp =
        DateTime(year ?? now.year, month ?? now.month, day ?? now.day)
            .add(Duration(seconds: daySecond));
    return todayTimestamp;
  }

  /// range的长度必须为2
  static bool isDateTimeInRange(
      {required DateTime dateTime,
      required List<DateTime> range,
      bool needEqual = false}) {
    bool isBefort = range.first.isBefore(dateTime);
    bool isAfter = range.last.isAfter(dateTime);
    bool isBeginSame = range.first.isAtSameMomentAs(dateTime);
    bool isEndSame = range.last.isAtSameMomentAs(dateTime);
    if (isBefort && isAfter) {
      return true;
    } else {
      if (needEqual) {
        return isBeginSame || isEndSame;
      } else {
        return false;
      }
    }
  }

  /// 传入月份，返回这个月的最后一天
  static int lastDayForMonth({required int month, required int year}) {
    if (month == 1 ||
        month == 3 ||
        month == 5 ||
        month == 7 ||
        month == 8 ||
        month == 10 ||
        month == 12) {
      return 31;
    } else if (month == 2) {
      if (isLeapYear(year)) {
        return 29;
      } else {
        return 28;
      }
    } else {
      return 30;
    }
  }

  /// 判断是否是闰年
  static bool isLeapYear(int year) {
    if (year % 4 != 0) {
      return false;
    } else if (year % 100 != 0) {
      return true;
    } else if (year % 400 != 0) {
      return false;
    } else {
      return true;
    }
  }

  /// 判断两个时间差是否大于20秒
  static bool isMoreThan20Seconds(DateTime startTime, DateTime currentTime) {
    Duration difference = currentTime.difference(startTime).abs();
    return difference.inHours > 0 ||
        difference.inMinutes > 0 ||
        difference.inSeconds > 20;
  }
}
