import 'package:flutter/material.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_driver/driver_extension.dart';

import 'package:sgtp_flutter/core/app/bootstrap_gate.dart';

void main() async {
  enableFlutterDriverExtension();
  runApp(const BootstrapGate());
}
