import 'dart:async';

import 'package:flutter/material.dart';

import 'package:sgtp_flutter/core/app/bootstrap_gate.dart';

void main() async {
  runZonedGuarded(() => runApp(const BootstrapGate()), (error, stackTrace) {
    debugPrint('Unhandled startup error: $error\n$stackTrace');
  });
}
