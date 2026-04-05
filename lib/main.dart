import 'package:flutter/material.dart';

import 'package:sgtp_flutter/core/app/app.dart';
import 'package:sgtp_flutter/core/app/bootstrap.dart';

void main() async {
  final dependencies = await bootstrapApp();
  runApp(SgtpApp(dependencies: dependencies));
}
