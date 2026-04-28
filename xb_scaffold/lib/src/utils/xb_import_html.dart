// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;

getDocumentTitle() {
  return html.document.title;
}

setDocumentTitle(String title) {
  html.document.title = title;
}
