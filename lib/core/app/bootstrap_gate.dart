import 'dart:async';

import 'package:flutter/material.dart';

import 'package:sgtp_flutter/core/app/app.dart';
import 'package:sgtp_flutter/core/app/bootstrap.dart';
import 'package:sgtp_flutter/core/di/injector.dart';

typedef BootstrapLoader = Future<AppDependencies> Function();
typedef BootstrapAppBuilder = Widget Function(AppDependencies dependencies);

class BootstrapGate extends StatefulWidget {
  const BootstrapGate({
    super.key,
    this.bootstrap = bootstrapApp,
    this.appBuilder = _defaultAppBuilder,
  });

  final BootstrapLoader bootstrap;
  final BootstrapAppBuilder appBuilder;

  @override
  State<BootstrapGate> createState() => _BootstrapGateState();
}

class _BootstrapGateState extends State<BootstrapGate> {
  late Future<AppDependencies> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.bootstrap();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<AppDependencies>(
      future: _future,
      builder: (context, snapshot) {
        final dependencies = snapshot.data;
        if (dependencies != null) {
          return widget.appBuilder(dependencies);
        }
        if (snapshot.hasError) {
          return StartupFailureApp(
            error: snapshot.error,
            stackTrace: snapshot.stackTrace,
          );
        }
        return const StartupLoadingApp();
      },
    );
  }
}

Widget _defaultAppBuilder(AppDependencies dependencies) {
  return SgtpApp(dependencies: dependencies);
}

class StartupLoadingApp extends StatelessWidget {
  const StartupLoadingApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: Color(0xFF101214),
        body: Center(child: CircularProgressIndicator()),
      ),
    );
  }
}

class StartupFailureApp extends StatelessWidget {
  const StartupFailureApp({super.key, required this.error, this.stackTrace});

  final Object? error;
  final StackTrace? stackTrace;

  @override
  Widget build(BuildContext context) {
    final message = error?.toString() ?? 'Unknown startup error';
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: const Color(0xFF101214),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Startup failed',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 12),
                SelectableText(
                  message,
                  style: const TextStyle(color: Color(0xFFFFB4AB)),
                ),
                const SizedBox(height: 16),
                Expanded(
                  child: SingleChildScrollView(
                    child: SelectableText(
                      stackTrace?.toString() ?? '',
                      style: const TextStyle(
                        color: Color(0xFFCDD6DF),
                        fontSize: 12,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
