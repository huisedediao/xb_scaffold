abstract class XBTrackExporter {
  Future<String> exportAsJson({int? limit});

  Future<String> exportAsText({int? limit});
}
