import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image/image.dart' as img;
import 'package:pretty_qr_code/pretty_qr_code.dart';

import 'package:sgtp_flutter/core/app_theme.dart';
import 'package:sgtp_flutter/core/file_save.dart';
import 'package:sgtp_flutter/core/qr_data.dart';
import 'package:sgtp_flutter/features/setup/application/services/setup_data_access.dart';

enum _PrettyQrShapeStyle { smooth, squares, dots }

class _PrettyQrPreset {
  final String label;
  final Color primary;
  final Color secondary;
  final Color cardTop;
  final Color cardBottom;

  const _PrettyQrPreset({
    required this.label,
    required this.primary,
    required this.secondary,
    required this.cardTop,
    required this.cardBottom,
  });
}

class PrettyQrSharePanel extends StatefulWidget {
  final QrShareData data;
  final String title;
  final String? subtitle;
  final String? description;
  final String copyMessage;
  final String exportName;
  final bool dialogMode;

  const PrettyQrSharePanel({
    super.key,
    required this.data,
    required this.title,
    this.subtitle,
    this.description,
    this.copyMessage = 'Hex copied',
    this.exportName = 'sgtp-qr',
    this.dialogMode = false,
  });

  @override
  State<PrettyQrSharePanel> createState() => _PrettyQrSharePanelState();
}

class _PrettyQrSharePanelState extends State<PrettyQrSharePanel> {
  static const _logoImage = AssetImage('assets/app_icon.png');
  static const _presets = [
    _PrettyQrPreset(
      label: 'Aurora',
      primary: Color(0xFF06B6D4),
      secondary: Color(0xFF22C55E),
      cardTop: Color(0xFF0F172A),
      cardBottom: Color(0xFF134E4A),
    ),
    _PrettyQrPreset(
      label: 'Sunset',
      primary: Color(0xFFF97316),
      secondary: Color(0xFFEC4899),
      cardTop: Color(0xFF451A03),
      cardBottom: Color(0xFF4A044E),
    ),
    _PrettyQrPreset(
      label: 'Ocean',
      primary: Color(0xFF3B82F6),
      secondary: Color(0xFF8B5CF6),
      cardTop: Color(0xFF0F172A),
      cardBottom: Color(0xFF1E1B4B),
    ),
    _PrettyQrPreset(
      label: 'Mono',
      primary: Color(0xFF111827),
      secondary: Color(0xFF4B5563),
      cardTop: Color(0xFFF3F4F6),
      cardBottom: Color(0xFFD1D5DB),
    ),
  ];

  static const _palette = [
    Color(0xFF111827),
    Color(0xFF3B82F6),
    Color(0xFF06B6D4),
    Color(0xFF14B8A6),
    Color(0xFF22C55E),
    Color(0xFFF59E0B),
    Color(0xFFF97316),
    Color(0xFFEF4444),
    Color(0xFFEC4899),
    Color(0xFF8B5CF6),
  ];

  late String _shareHex;
  late QrImage _qrImage;
  late final SettingsRepository _settingsRepo;
  int _presetIndex = 0;
  Color _primary = _presets.first.primary;
  Color _secondary = _presets.first.secondary;
  bool _showLogo = true;
  _PrettyQrShapeStyle _shapeStyle = _PrettyQrShapeStyle.smooth;

  @override
  void initState() {
    super.initState();
    _settingsRepo = context.read<SettingsRepository>();
    _syncQrPayload();
    _loadSavedStyle();
  }

  @override
  void didUpdateWidget(covariant PrettyQrSharePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.data != oldWidget.data) {
      _syncQrPayload();
    }
  }

  void _syncQrPayload() {
    _shareHex = widget.data.toHex();
    _qrImage = _buildQrImage();
  }

  Future<void> _loadSavedStyle() async {
    final saved = await _settingsRepo.loadQrStyleSettings();
    if (!mounted) return;
    final presetIndex = saved.presetIndex.clamp(0, _presets.length - 1);
    final preset = _presets[presetIndex];
    setState(() {
      _presetIndex = presetIndex;
      _primary = saved.primaryColorValue != null
          ? Color(saved.primaryColorValue!)
          : preset.primary;
      _secondary = saved.secondaryColorValue != null
          ? Color(saved.secondaryColorValue!)
          : preset.secondary;
      _shapeStyle = _shapeFromString(saved.shapeStyle);
      _showLogo = saved.showLogo;
    });
  }

  Future<void> _persistStyle() {
    return _settingsRepo.saveQrStyleSettings(
      QrStyleSettings(
        presetIndex: _presetIndex,
        primaryColorValue: _primary.toARGB32(),
        secondaryColorValue: _secondary.toARGB32(),
        shapeStyle: _shapeToString(_shapeStyle),
        showLogo: _showLogo,
      ),
    );
  }

  _PrettyQrShapeStyle _shapeFromString(String value) {
    return switch (value) {
      'squares' => _PrettyQrShapeStyle.squares,
      'dots' => _PrettyQrShapeStyle.dots,
      _ => _PrettyQrShapeStyle.smooth,
    };
  }

  String _shapeToString(_PrettyQrShapeStyle style) {
    return switch (style) {
      _PrettyQrShapeStyle.smooth => 'smooth',
      _PrettyQrShapeStyle.squares => 'squares',
      _PrettyQrShapeStyle.dots => 'dots',
    };
  }

  QrImage _buildQrImage() {
    final qrCode = QrCode.fromData(
      data: widget.data.toQrContent(),
      errorCorrectLevel: QrErrorCorrectLevel.H,
    );
    return QrImage(qrCode);
  }

  _PrettyQrPreset get _preset => _presets[_presetIndex];

  PrettyQrDecoration get _decoration {
    final brush = PrettyQrBrush.gradient(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [_primary, _secondary],
      ),
    );

    final shape = switch (_shapeStyle) {
      _PrettyQrShapeStyle.smooth => PrettyQrSmoothSymbol(color: brush),
      _PrettyQrShapeStyle.squares => PrettyQrSquaresSymbol(
          color: brush,
          rounding: 0.18,
        ),
      _PrettyQrShapeStyle.dots => PrettyQrDotsSymbol(color: brush),
    };

    return PrettyQrDecoration(
      shape: shape,
      quietZone: PrettyQrQuietZone.standard,
      background: Colors.white,
      image: _showLogo
          ? const PrettyQrDecorationImage(
              image: _logoImage,
              position: PrettyQrDecorationImagePosition.embedded,
              padding: EdgeInsets.all(10),
            )
          : null,
    );
  }

  void _applyPreset(int index) {
    final preset = _presets[index];
    setState(() {
      _presetIndex = index;
      _primary = preset.primary;
      _secondary = preset.secondary;
    });
    _persistStyle();
  }

  Future<void> _exportQr(_QrExportFormat format) async {
    try {
      final bytes = await _buildExportBytes(format);
      if (bytes == null) {
        throw Exception('Failed to render QR image');
      }
      final suggestedFileName = '${widget.exportName}.${format.extension}';
      final savedPath = await FilePicker.platform.saveFile(
        dialogTitle: 'Export QR',
        fileName: suggestedFileName,
        type: FileType.custom,
        allowedExtensions: [format.extension],
        bytes: bytes,
      );

      if (savedPath == null) return;

      if (!kIsWeb) {
        await saveBytesToPath(savedPath, bytes);
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('QR exported as ${format.label}')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('QR export failed: $e')),
      );
    }
  }

  Future<Uint8List?> _buildExportBytes(_QrExportFormat format) async {
    final byteData = await _qrImage.toImageAsBytes(
      size: 2048,
      format: ui.ImageByteFormat.png,
      decoration: _decoration,
      configuration: createLocalImageConfiguration(context),
    );
    final pngBytes = byteData?.buffer.asUint8List();
    if (pngBytes == null) return null;
    if (format == _QrExportFormat.png) {
      return pngBytes;
    }

    final image = img.decodeImage(pngBytes);
    if (image == null) return null;
    return Uint8List.fromList(img.encodeJpg(image, quality: 96));
  }

  @override
  Widget build(BuildContext context) {
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.title,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  if (widget.subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      widget.subtitle!,
                      style: const TextStyle(
                        fontSize: 12,
                        fontFamily: 'monospace',
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Icons.close, color: AppColors.textSecondary),
              onPressed: () => Navigator.pop(context),
            ),
          ],
        ),
        if (widget.description != null) ...[
          const SizedBox(height: 8),
          Text(
            widget.description!,
            style: const TextStyle(
              fontSize: 13,
              color: AppColors.textSecondary,
              height: 1.45,
            ),
          ),
        ],
        const SizedBox(height: 20),
        Center(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            width: widget.dialogMode ? 300 : 320,
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(28),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [_preset.cardTop, _preset.cardBottom],
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withAlpha(45),
                  blurRadius: 24,
                  offset: const Offset(0, 14),
                ),
              ],
            ),
            child: Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(22),
              ),
              child: TweenAnimationBuilder<PrettyQrDecoration>(
                tween: PrettyQrDecorationTween(end: _decoration),
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                builder: (context, decoration, _) {
                  return PrettyQrView(
                    qrImage: _qrImage,
                    decoration: decoration,
                  );
                },
              ),
            ),
          ),
        ),
        const SizedBox(height: 20),
        const Text(
          'Style Presets',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.4,
            color: AppColors.textSecondary,
          ),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: List.generate(_presets.length, (index) {
            final preset = _presets[index];
            final selected = _presetIndex == index;
            return ChoiceChip(
              label: Text(preset.label),
              selected: selected,
              onSelected: (_) => _applyPreset(index),
              selectedColor: AppColors.accent.withAlpha(50),
              backgroundColor: AppColors.bgSurfaceActive,
              side: BorderSide(
                color: selected ? AppColors.accent : AppColors.border,
              ),
              labelStyle: TextStyle(
                color:
                    selected ? AppColors.textPrimary : AppColors.textSecondary,
                fontWeight: FontWeight.w600,
              ),
            );
          }),
        ),
        const SizedBox(height: 18),
        _ColorPickerRow(
          label: 'Primary',
          value: _primary,
          colors: _palette,
          onChanged: (value) {
            setState(() => _primary = value);
            _persistStyle();
          },
        ),
        const SizedBox(height: 14),
        _ColorPickerRow(
          label: 'Accent',
          value: _secondary,
          colors: _palette,
          onChanged: (value) {
            setState(() => _secondary = value);
            _persistStyle();
          },
        ),
        const SizedBox(height: 18),
        const Text(
          'Modules',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.4,
            color: AppColors.textSecondary,
          ),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: _PrettyQrShapeStyle.values.map((shape) {
            final selected = _shapeStyle == shape;
            return ChoiceChip(
              label: Text(
                switch (shape) {
                  _PrettyQrShapeStyle.smooth => 'Smooth',
                  _PrettyQrShapeStyle.squares => 'Squares',
                  _PrettyQrShapeStyle.dots => 'Dots',
                },
              ),
              selected: selected,
              onSelected: (_) {
                setState(() => _shapeStyle = shape);
                _persistStyle();
              },
              selectedColor: AppColors.accent.withAlpha(50),
              backgroundColor: AppColors.bgSurfaceActive,
              side: BorderSide(
                color: selected ? AppColors.accent : AppColors.border,
              ),
              labelStyle: TextStyle(
                color:
                    selected ? AppColors.textPrimary : AppColors.textSecondary,
                fontWeight: FontWeight.w600,
              ),
            );
          }).toList(),
        ),
        const SizedBox(height: 14),
        SwitchListTile.adaptive(
          value: _showLogo,
          onChanged: (value) {
            setState(() => _showLogo = value);
            _persistStyle();
          },
          dense: true,
          contentPadding: EdgeInsets.zero,
          activeThumbColor: AppColors.accent,
          title: const Text(
            'Show Placeholder Logo',
            style: TextStyle(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w600,
            ),
          ),
          subtitle: const Text(
            'Uses the current app icon as a temporary center mark.',
            style: TextStyle(
              color: AppColors.textSecondary,
              fontSize: 12,
            ),
          ),
        ),
        const SizedBox(height: 12),
        const Text(
          'Export',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.4,
            color: AppColors.textSecondary,
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: _PanelActionButton(
                icon: Icons.download_outlined,
                label: 'Save PNG',
                onTap: () => _exportQr(_QrExportFormat.png),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _PanelActionButton(
                icon: Icons.image_outlined,
                label: 'Save JPG',
                onTap: () => _exportQr(_QrExportFormat.jpg),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Theme(
          data: Theme.of(context).copyWith(
            dividerColor: Colors.transparent,
            splashColor: Colors.transparent,
            highlightColor: Colors.transparent,
          ),
          child: ExpansionTile(
            tilePadding: EdgeInsets.zero,
            childrenPadding: EdgeInsets.zero,
            title: const Text(
              'Show share hex',
              style: TextStyle(
                color: AppColors.textPrimary,
                fontWeight: FontWeight.w600,
              ),
            ),
            subtitle: const Text(
              'Share or copy the raw share code.',
              style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: 12,
              ),
            ),
            children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: AppColors.bgSurfaceActive,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: AppColors.border),
                ),
                child: SelectableText(
                  _shareHex,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11,
                    color: AppColors.textSecondary,
                    height: 1.45,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: FilledButton.tonalIcon(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: _shareHex));
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(widget.copyMessage)),
              );
            },
            icon: const Icon(Icons.copy_outlined),
            label: const Text('Copy Hex'),
          ),
        ),
      ],
    );

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 16),
      child: content,
    );
  }
}

enum _QrExportFormat {
  png('PNG', 'png'),
  jpg('JPG', 'jpg');

  final String label;
  final String extension;
  const _QrExportFormat(this.label, this.extension);
}

class _PanelActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _PanelActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: 18),
      label: Text(label),
      style: OutlinedButton.styleFrom(
        minimumSize: const Size.fromHeight(46),
        foregroundColor: AppColors.textPrimary,
        side: const BorderSide(color: AppColors.border),
        backgroundColor: AppColors.bgSurfaceActive,
      ),
    );
  }
}

class _ColorPickerRow extends StatelessWidget {
  final String label;
  final Color value;
  final List<Color> colors;
  final ValueChanged<Color> onChanged;

  const _ColorPickerRow({
    required this.label,
    required this.value,
    required this.colors,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.4,
            color: AppColors.textSecondary,
          ),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: colors.map((color) {
            final selected = color == value;
            return GestureDetector(
              onTap: () => onChanged(color),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: color,
                  border: Border.all(
                    color: selected ? Colors.white : Colors.transparent,
                    width: 2,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: color.withAlpha(100),
                      blurRadius: selected ? 14 : 8,
                      spreadRadius: selected ? 1 : 0,
                    ),
                  ],
                ),
              ),
            );
          }).toList(),
        ),
      ],
    );
  }
}
