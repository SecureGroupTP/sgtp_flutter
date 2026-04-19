import 'package:flutter/material.dart';

class AvatarFallback {
  AvatarFallback._();

  static const gradients = [
    [Color(0xFFFF7676), Color(0xFFE53935)],
    [Color(0xFFFFAE34), Color(0xFFF57C00)],
    [Color(0xFF66CC6C), Color(0xFF2E7D32)],
    [Color(0xFF4DD0E1), Color(0xFF0097A7)],
    [Color(0xFF42A5F5), Color(0xFF1E88E5)],
    [Color(0xFF7E57C2), Color(0xFF4527A0)],
    [Color(0xFFAB47BC), Color(0xFF7B1FA2)],
    [Color(0xFFEC407A), Color(0xFFC2185B)],
  ];

  static String normalizeName(String name) {
    final trimmed = name.trim();
    return trimmed.isEmpty ? '?' : trimmed;
  }

  static String initialForName(String name) {
    final normalized = normalizeName(name);
    return normalized[0].toUpperCase();
  }

  static List<Color> gradientForName(String name) {
    final normalized = normalizeName(name);
    int hash = 0;
    for (int i = 0; i < normalized.length; i++) {
      hash = normalized.codeUnitAt(i) + ((hash << 5) - hash);
    }
    return gradients[hash.abs() % gradients.length];
  }
}
