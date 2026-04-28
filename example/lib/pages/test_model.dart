

import 'package:xb_scaffold/xb_scaffold.dart';

class TestModel {
  int? id;
  int? deviceId;
  int? algorithmId;
  String? algorithmName;
  int? openSwitch;
  int? status;
  String? levelName;
  String? deviceName;
  int? maxCount;
  int? useCount;
  int? aiBind;
  int? step;
  int? timeInterval;
  String? threshold;

  TestModel({
    this.id,
    this.deviceId,
    this.algorithmId,
    this.algorithmName,
    this.openSwitch,
    this.status,
    this.levelName,
    this.deviceName,
    this.maxCount,
    this.useCount,
    this.aiBind,
    this.step,
    this.timeInterval,
    this.threshold,
  });

  TestModel.fromJson(Map<String, dynamic> json) {
    id = xbParse<int>(json['id']);
    deviceId = xbParse<int>(json['deviceId']);
    algorithmId = xbParse<int>(json['algorithmId']);
    algorithmName = xbParse<String>(json['algorithmName']);
    openSwitch = xbParse<int>(json['openSwitch']);
    status = xbParse<int>(json['status']);
    levelName = xbParse<String>(json['levelName']);
    deviceName = xbParse<String>(json['deviceName']);
    maxCount = xbParse<int>(json['maxCount']);
    useCount = xbParse<int>(json['useCount']);
    aiBind = xbParse<int>(json['aiBind']);
    step = xbParse<int>(json['step']);
    timeInterval = xbParse<int>(json['timeInterval']);
    threshold = xbParse<String>(json['threshold']);
  }

  Map<String, dynamic> toJson() {
    final Map<String, dynamic> retMap = {};
    retMap['id'] = id;
    retMap['deviceId'] = deviceId;
    retMap['algorithmId'] = algorithmId;
    retMap['algorithmName'] = algorithmName;
    retMap['openSwitch'] = openSwitch;
    retMap['status'] = status;
    retMap['levelName'] = levelName;
    retMap['deviceName'] = deviceName;
    retMap['maxCount'] = maxCount;
    retMap['useCount'] = useCount;
    retMap['aiBind'] = aiBind;
    retMap['step'] = step;
    retMap['timeInterval'] = timeInterval;
    retMap['threshold'] = threshold;
    return retMap;
  }
}


