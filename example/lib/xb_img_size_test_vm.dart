import 'package:example/xb_img_size_test.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

class XBImgSizeTestVM extends XBPageVM<XBImgSizeTest> {
  XBImgSizeTestVM({required super.context}) {
    showLog();
  }

  onGetSizeFromNet() async {
    XBImgSizeUtil.getImageSizeFromUrl(
            "https://www.baidu.com/img/PCtm_d9c8750bed0b3c7d089fa7d55720d6cf.png")
        .then((value) {
      toast(value.toString());
    }).catchError((e) {
      print(e);
    });
  }

  onGetSizeFromAsset() async {
    XBImgSizeUtil.getImageSizeFromAsset(images.imgPath("arrow_down.png"))
        .then((value) {
      toast(value.toString());
    }).catchError((e) {
      print(e);
    });
  }

  onGetSizeFromFile() async {}

  onGetSizeFromMemory() async {}
}
