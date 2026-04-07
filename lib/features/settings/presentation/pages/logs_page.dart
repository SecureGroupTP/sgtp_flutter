import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:sgtp_flutter/features/settings/application/viewmodels/logs_cubit.dart';
import 'package:sgtp_flutter/features/settings/presentation/pages/logs_screen.dart';

class LogsPage extends StatefulWidget {
  const LogsPage({super.key});

  @override
  State<LogsPage> createState() => _LogsPageState();
}

class _LogsPageState extends State<LogsPage> {
  late final LogsCubit _cubit;

  @override
  void initState() {
    super.initState();
    _cubit = LogsCubit();
  }

  @override
  void dispose() {
    _cubit.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return BlocProvider.value(
      value: _cubit,
      child: const LogsScreen(),
    );
  }
}
