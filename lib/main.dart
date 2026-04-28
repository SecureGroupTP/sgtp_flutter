import 'dart:async';

import 'package:flutter/material.dart';

import 'package:sgtp_flutter/core/app/app_runner.dart';

void main() async {
  await runZonedGuarded(
    () async {
      await runSgtpApp();
    },
    (error, stackTrace) {
      debugPrint('Unhandled startup error: $error\n$stackTrace');
    },
  );
}
