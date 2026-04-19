import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:sgtp_flutter/features/settings/application/services/settings_management_service.dart';
import 'package:sgtp_flutter/features/setup/application/viewmodels/onboarding_cubit.dart';
import 'package:sgtp_flutter/features/setup/presentation/pages/onboarding_screen.dart';

class OnboardingPage extends StatefulWidget {
  const OnboardingPage({super.key});

  @override
  State<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends State<OnboardingPage> {
  late final OnboardingCubit _cubit;

  @override
  void initState() {
    super.initState();
    _cubit = OnboardingCubit(
      settings: context.read<SettingsManagementService>(),
      preferWebTransportOrder: kIsWeb,
    );
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
      child: const OnboardingScreen(),
    );
  }
}
