import 'package:flutter/material.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

class XBNavigatorBackBtn extends StatelessWidget {
  final VoidCallback onTap;
  final String? img;
  final Size? imgSize;

  const XBNavigatorBackBtn(
      {required this.onTap, this.img, this.imgSize, Key? key})
      : super(key: key);

  @override
  Widget build(BuildContext context) {
    return XBButton(
        onTap: onTap,
        child: Container(
          color: Colors.transparent,
          alignment: Alignment.center,
          child: (img != null)
              ? XBImage(
                  img,
                  width: imgSize != null ? imgSize!.width : 25,
                  height: imgSize != null ? imgSize!.height : 23,
                )
              : const Icon(
                  Icons.arrow_back,
                  color: Colors.black,
                ),
        ));
  }
}
