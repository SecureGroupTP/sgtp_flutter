import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:sgtp_flutter/core/app_log.dart';
import 'package:sgtp_flutter/core/logging/log_setup.dart';

void main() {
  tearDown(() async {
    await LogSetup.close();
  });

  test('init is idempotent and does not duplicate log file writes', () async {
    final dir = await Directory.systemTemp.createTemp('sgtp_log_setup_test_');
    addTearDown(() async {
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    });

    final path = '${dir.path}/sgtp_logs.jsonl';
    LogSetup.init(path);
    LogSetup.init(path);

    AppLog('LogSetupTest').info('single log record');

    await LogSetup.close();

    final lines = await File(path).readAsLines();
    expect(lines.where((line) => line.contains('single log record')).length, 1);
  });

  test('close allows a later init to attach a fresh sink', () async {
    final dir = await Directory.systemTemp.createTemp('sgtp_log_setup_test_');
    addTearDown(() async {
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    });

    final firstPath = '${dir.path}/first.jsonl';
    final secondPath = '${dir.path}/second.jsonl';

    LogSetup.init(firstPath);
    Logger('LogSetupTest').info('first file');
    await LogSetup.close();

    LogSetup.init(secondPath);
    Logger('LogSetupTest').info('second file');
    await LogSetup.close();

    expect((await File(firstPath).readAsLines()).length, 1);
    expect((await File(secondPath).readAsLines()).length, 1);
  });
}
