import 'package:flutter/material.dart';
import 'package:flutter_driver/driver_extension.dart';

import 'package:sgtp_flutter/core/app/app.dart';
import 'package:sgtp_flutter/core/app/bootstrap.dart';

void main() async {
  enableFlutterDriverExtension();
  final dependencies = await bootstrapApp();
  runApp(SgtpApp(dependencies: dependencies));
}
