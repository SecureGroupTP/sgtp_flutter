import 'package:flutter/material.dart';

import 'package:sgtp_flutter/core/app_theme.dart';

class DropdownOption<T> {
  final T value;
  final String label;

  const DropdownOption({required this.value, required this.label});
}

/// A styled dropdown that matches the app's dark input field design.
/// Automatically opens upward when there is insufficient space below.
class StyledDropdown<T> extends StatefulWidget {
  final IconData icon;
  final List<DropdownOption<T>> options;
  final T value;
  final ValueChanged<T> onChanged;

  const StyledDropdown({
    super.key,
    required this.icon,
    required this.options,
    required this.value,
    required this.onChanged,
  });

  @override
  State<StyledDropdown<T>> createState() => _StyledDropdownState<T>();
}

class _StyledDropdownState<T> extends State<StyledDropdown<T>> {
  final _layerLink = LayerLink();
  OverlayEntry? _entry;
  bool _open = false;

  // Each option row: vertical padding 14×2 + line-height ~22 + 1px border ≈ 51px
  static const _optionHeight = 51.0;
  static const _triggerHeight = 52.0;
  static const _gap = 8.0;

  @override
  void dispose() {
    _removeEntry();
    super.dispose();
  }

  void _removeEntry() {
    _entry?.remove();
    _entry = null;
  }

  void _toggle() => _open ? _closeDropdown() : _openDropdown();

  void _openDropdown() {
    final renderBox = context.findRenderObject() as RenderBox;
    final width = renderBox.size.width;
    final globalPos = renderBox.localToGlobal(Offset.zero);
    final screenHeight = MediaQuery.of(context).size.height;

    // Estimated list height: options × row height + 2px for container borders
    final listH = widget.options.length * _optionHeight + 2;

    // How much room is below the trigger (to the bottom of the screen)
    final spaceBelow =
        screenHeight - globalPos.dy - _triggerHeight - _gap;
    final openUpward = spaceBelow < listH;

    _entry = _buildEntry(width: width, listH: listH, openUpward: openUpward);
    // rootOverlay: true — inserts above all routes/bottom-sheets, preventing
    // the list from being clipped by the modal's own overlay boundary.
    Overlay.of(context, rootOverlay: true).insert(_entry!);
    setState(() => _open = true);
  }

  void _closeDropdown() {
    _removeEntry();
    if (mounted) setState(() => _open = false);
  }

  OverlayEntry _buildEntry({
    required double width,
    required double listH,
    required bool openUpward,
  }) {
    // When opening upward: offset the dropdown so its bottom sits above the trigger.
    final offset = openUpward
        ? Offset(0, -listH - _gap)
        : const Offset(0, _triggerHeight + _gap);

    return OverlayEntry(
      builder: (_) => Stack(
        children: [
          // Invisible full-screen barrier — close on tap outside
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _closeDropdown,
              child: const ColoredBox(color: Colors.transparent),
            ),
          ),
          // Dropdown anchored to the trigger via LayerLink
          CompositedTransformFollower(
            link: _layerLink,
            showWhenUnlinked: false,
            offset: offset,
            child: Align(
              alignment: Alignment.topLeft,
              child: Material(
                color: Colors.transparent,
                child: _DropdownList<T>(
                  options: widget.options,
                  selectedValue: widget.value,
                  width: width,
                  onSelect: (v) {
                    _closeDropdown();
                    widget.onChanged(v);
                  },
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final label = widget.options
        .firstWhere(
          (o) => o.value == widget.value,
          orElse: () => widget.options.first,
        )
        .label;

    return CompositedTransformTarget(
      link: _layerLink,
      child: GestureDetector(
        onTap: _toggle,
        child: Container(
          height: _triggerHeight,
          decoration: BoxDecoration(
            color: const Color(0xFF1B1B1F),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.border),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Icon(widget.icon, size: 22, color: AppColors.textSecondary),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 15,
                  ),
                ),
              ),
              AnimatedRotation(
                turns: _open ? 0.5 : 0.0,
                duration: const Duration(milliseconds: 200),
                child: const Icon(
                  Icons.expand_more,
                  color: AppColors.textSecondary,
                  size: 22,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DropdownList<T> extends StatelessWidget {
  final List<DropdownOption<T>> options;
  final T selectedValue;
  final double width;
  final ValueChanged<T> onSelect;

  const _DropdownList({
    required this.options,
    required this.selectedValue,
    required this.width,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      decoration: BoxDecoration(
        color: AppColors.bgSurface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
        boxShadow: const [
          BoxShadow(
            color: Colors.black38,
            blurRadius: 24,
            offset: Offset(0, 4),
          ),
        ],
      ),
      clipBehavior: Clip.hardEdge,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: List.generate(options.length, (i) {
          final opt = options[i];
          final isSelected = opt.value == selectedValue;
          return GestureDetector(
            onTap: () => onSelect(opt.value),
            child: Container(
              decoration: BoxDecoration(
                color: isSelected
                    ? const Color(0xFF1B1B1F)
                    : Colors.transparent,
                border: i < options.length - 1
                    ? const Border(
                        bottom: BorderSide(color: AppColors.border),
                      )
                    : null,
              ),
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      opt.label,
                      style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 15,
                      ),
                    ),
                  ),
                  if (isSelected)
                    const Icon(
                      Icons.check,
                      color: AppColors.textPrimary,
                      size: 20,
                    ),
                ],
              ),
            ),
          );
        }),
      ),
    );
  }
}
