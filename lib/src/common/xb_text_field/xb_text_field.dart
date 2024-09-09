import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/*
 * initValue只有在创建的时候有效，如果需要清除内容，请使用
    GlobalKey<XBTextFieldState> tfKey = GlobalKey();
    tfKey.currentState?.clear();
 * */
class XBTextField extends StatefulWidget {
  final TextAlign textAlign;
  final String? placeholder;
  final String? initValue;
  final TextStyle? style;
  final TextStyle? placeholderStyle;
  final bool focused;
  final VoidCallback? onFocus;
  final VoidCallback? loseFocus;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final bool obscureText;
  final TextInputType? keyboardType;
  final Color? cursorColor;
  final double cursorWidth;
  final Radius? cursorRadius;
  final TextInputAction textInputAction;
  final int? maxLines;
  final bool autoHeight;
  final EdgeInsetsGeometry? contentPadding;
  final bool needContentPadding;
  final List<TextInputFormatter>? inputFormatters;

  const XBTextField(
      {this.placeholder,
      this.autoHeight = false,
      this.maxLines,
      this.initValue,
      this.style,
      this.textAlign = TextAlign.start,
      this.placeholderStyle,
      this.focused = false,
      this.onFocus,
      this.loseFocus,
      this.onChanged,
      this.onSubmitted,
      this.contentPadding,
      this.needContentPadding = true,
      this.obscureText = false,
      this.keyboardType,
      this.textInputAction = TextInputAction.done,
      this.cursorColor = Colors.blue,
      this.cursorWidth = 1,
      this.cursorRadius,
      this.inputFormatters,
      Key? key})
      : super(key: key);

  @override
  State<StatefulWidget> createState() {
    return XBTextFieldState();
  }
}

class XBTextFieldState extends State<XBTextField> {
  late TextEditingController _ctl;
  late FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _ctl = TextEditingController(text: widget.initValue);
    _focusNode = FocusNode();
    _focusNode.addListener(_onFocusChange);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (widget.focused) {
        FocusScope.of(context).requestFocus(_focusNode);
      }
    });
  }

  void _onFocusChange() {
    if (_focusNode.hasFocus) {
      widget.onFocus?.call();
    } else {
      widget.loseFocus?.call();
    }
  }

  void clear() {
    _ctl.text = "";
  }

  @override
  void dispose() {
    _focusNode.removeListener(_onFocusChange);
    _focusNode.dispose();
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      keyboardType: widget.keyboardType,
      maxLines: widget.autoHeight ? null : (widget.maxLines ?? 1),
      textInputAction: widget.textInputAction,
      style: widget.style,
      obscureText: widget.obscureText,
      onSubmitted: widget.onSubmitted,
      onChanged: widget.onChanged,
      focusNode: _focusNode,
      textAlign: widget.textAlign,
      controller: _ctl,
      cursorColor: widget.cursorColor,
      cursorRadius: widget.cursorRadius,
      cursorWidth: widget.cursorWidth,
      inputFormatters: widget.inputFormatters,
      decoration: InputDecoration(
          contentPadding: widget.needContentPadding
              ? (widget.contentPadding ?? EdgeInsets.zero)
              : null,
          border: const OutlineInputBorder(borderSide: BorderSide.none),
          hintText: widget.placeholder,
          hintStyle: widget.placeholderStyle ??
              const TextStyle(color: Color(0xFFCCCCCC))),
    );
  }
}
