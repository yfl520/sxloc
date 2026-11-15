import 'dart:ui';

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';

const ink = Color(0xFF202127);
const muted = Color(0xFF85858C);
const blue = Color(0xFF007AFF);
const line = Color(0x16000000);

TextStyle textStyle([
  double size = 13,
  Color color = ink,
  FontWeight weight = FontWeight.w400,
]) => TextStyle(
  fontSize: size,
  color: color,
  fontWeight: weight,
  height: 1.45,
  fontFamily: 'Segoe UI',
  fontFamilyFallback: const ['Microsoft YaHei UI', 'PingFang SC'],
);

class Glass extends StatelessWidget {
  const Glass({
    super.key,
    required this.child,
    this.radius = 14,
    this.padding = EdgeInsets.zero,
    this.color = const Color(0xEDFFFFFF),
    this.shadow = true,
  });
  final Widget child;
  final double radius;
  final EdgeInsets padding;
  final Color color;
  final bool shadow;
  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(radius),
      boxShadow: shadow
          ? const [
              BoxShadow(
                color: Color(0x19000000),
                blurRadius: 24,
                offset: Offset(0, 6),
              ),
            ]
          : null,
    ),
    child: ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(radius),
            border: Border.all(color: const Color(0x95FFFFFF)),
          ),
          child: child,
        ),
      ),
    ),
  );
}

class MacButton extends StatefulWidget {
  const MacButton(
    this.label, {
    super.key,
    this.onPressed,
    this.icon,
    this.primary = false,
    this.destructive = false,
    this.compact = false,
    this.busy = false,
    this.success = false,
  });
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool primary, destructive, compact, busy, success;
  @override
  State<MacButton> createState() => _MacButtonState();
}

class _MacButtonState extends State<MacButton> {
  bool hover = false;
  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null && !widget.busy;
    final accent = widget.success ? const Color(0xFF25985C) : blue;
    final foreground = widget.primary
        ? Colors.white
        : widget.destructive
        ? const Color(0xFFE24B45)
        : ink;
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => hover = true),
      onExit: (_) => setState(() => hover = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        decoration: BoxDecoration(
          color: widget.primary
              ? (enabled
                    ? (hover ? accent.withValues(alpha: .85) : accent)
                    : accent.withValues(alpha: .4))
              : hover && enabled
              ? const Color(0xFFF0F1F4)
              : Colors.white,
          borderRadius: BorderRadius.circular(7),
          border: widget.primary ? null : Border.all(color: line),
          boxShadow: const [
            BoxShadow(
              color: Color(0x08000000),
              blurRadius: 2,
              offset: Offset(0, 1),
            ),
          ],
        ),
        child: CupertinoButton(
          padding: EdgeInsets.symmetric(
            horizontal: widget.compact ? 10 : 14,
            vertical: widget.compact ? 6 : 9,
          ),
          minimumSize: Size(0, widget.compact ? 28 : 34),
          borderRadius: BorderRadius.circular(7),
          onPressed: enabled ? widget.onPressed : null,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (widget.busy) ...[
                CupertinoActivityIndicator(radius: 7, color: foreground),
                const SizedBox(width: 7),
              ] else if (widget.icon != null) ...[
                Icon(
                  widget.icon,
                  size: 15,
                  color: enabled
                      ? foreground
                      : foreground.withValues(alpha: .45),
                ),
                const SizedBox(width: 6),
              ],
              Text(
                widget.label,
                style: textStyle(
                  12,
                  enabled || widget.busy
                      ? foreground
                      : foreground.withValues(alpha: .45),
                  FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class ToolButton extends StatelessWidget {
  const ToolButton(
    this.icon,
    this.label,
    this.onPressed, {
    super.key,
    this.selected = false,
  });
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool selected;
  @override
  Widget build(BuildContext context) => Tooltip(
    message: label,
    child: CupertinoButton(
      padding: const EdgeInsets.all(8),
      minimumSize: const Size(32, 32),
      onPressed: onPressed,
      child: Icon(
        icon,
        size: 19,
        color: onPressed == null
            ? muted.withValues(alpha: .35)
            : selected
            ? blue
            : const Color(0xFF66676E),
      ),
    ),
  );
}

class MacField extends StatelessWidget {
  const MacField({
    super.key,
    required this.controller,
    this.label,
    this.hint,
    this.obscure = false,
    this.onChanged,
    this.onSubmitted,
    this.focusNode,
    this.prefix,
    this.suffix,
    this.dense = false,
  });
  final TextEditingController controller;
  final String? label, hint;
  final bool obscure, dense;
  final ValueChanged<String>? onChanged, onSubmitted;
  final FocusNode? focusNode;
  final Widget? prefix, suffix;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (label != null) ...[
        Text(label!, style: textStyle(dense ? 10 : 11, muted)),
        SizedBox(height: dense ? 3 : 5),
      ],
      CupertinoTextField(
        controller: controller,
        focusNode: focusNode,
        obscureText: obscure,
        placeholder: hint,
        placeholderStyle: textStyle(12, muted),
        style: textStyle(12),
        padding: EdgeInsets.symmetric(
          horizontal: dense ? 8 : 10,
          vertical: dense ? 6 : 9,
        ),
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: const Color(0x22000000)),
          borderRadius: BorderRadius.circular(7),
        ),
        prefix: prefix,
        suffix: suffix,
        onChanged: onChanged,
        onSubmitted: onSubmitted,
      ),
    ],
  );
}

class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Text(text, style: textStyle(11, muted, FontWeight.w600)),
  );
}

class StatusPill extends StatelessWidget {
  const StatusPill(this.label, {super.key, this.active = false});
  final String label;
  final bool active;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      color: active ? const Color(0xFFE6F6ED) : const Color(0xFFF0F0F3),
      borderRadius: BorderRadius.circular(20),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 5,
          height: 5,
          decoration: BoxDecoration(
            color: active ? const Color(0xFF34A366) : muted,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 5),
        Text(
          label,
          style: textStyle(10, active ? const Color(0xFF2A8852) : muted),
        ),
      ],
    ),
  );
}

Future<void> showMessage(
  BuildContext context,
  String message, {
  String title = '操作未完成',
}) => showCupertinoDialog<void>(
  context: context,
  builder: (dialogContext) => CupertinoAlertDialog(
    title: Text(title),
    content: Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Text(message),
    ),
    actions: [
      CupertinoDialogAction(
        onPressed: () => Navigator.pop(dialogContext),
        child: const Text('知道了'),
      ),
    ],
  ),
);

Future<T?> showMacSheet<T>(
  BuildContext context, {
  required String title,
  required Widget child,
  double width = 580,
}) => showDialog<T>(
  context: context,
  barrierColor: Colors.black.withValues(alpha: .15),
  builder: (context) => Dialog(
    backgroundColor: const Color(0xFFF6F6F8),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    child: ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: width,
        maxHeight: MediaQuery.sizeOf(context).height - 90,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 15, 12, 12),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: textStyle(15, ink, FontWeight.w600),
                  ),
                ),
                ToolButton(
                  CupertinoIcons.xmark_circle_fill,
                  '关闭',
                  () => Navigator.pop(context),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: line),
          Flexible(child: child),
        ],
      ),
    ),
  ),
);
