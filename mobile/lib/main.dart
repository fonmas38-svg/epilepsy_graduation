import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'core/enums.dart';
import 'features/auth/login_screen.dart';
import 'features/caregiver/caregiver_home_screen.dart';
import 'features/doctor/doctor_home_screen.dart';
import 'features/patient/patient_home_screen.dart';
import 'providers/app_state.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Firebase is optional in demo mode. When DEMO_MODE=false, initialize Firebase here:
  // await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  final appState = AppState();
  // init() guards its own risky steps, but never let an unexpected failure keep
  // the UI from launching — the login screen must always be reachable.
  try {
    await appState.init();
  } catch (e) {
    appState.error = 'تعذّر تهيئة التطبيق: $e';
    appState.ready = true;
  }
  runApp(EpilepsyApp(appState: appState));
}

class EpilepsyApp extends StatelessWidget {
  const EpilepsyApp({super.key, required this.appState});

  final AppState appState;

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider.value(
      value: appState,
      child: MaterialApp(
        title: 'Epilepsy Monitor',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF145C6B),
            brightness: Brightness.light,
          ),
          useMaterial3: true,
          fontFamily: 'Roboto',
        ),
        home: const RootShell(),
      ),
    );
  }
}

class RootShell extends StatelessWidget {
  const RootShell({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    if (!state.ready) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final user = state.auth.currentUser;
    if (user == null) return const LoginScreen();

    Widget home = switch (user.role) {
      UserRole.patient => const PatientHomeScreen(),
      UserRole.caregiver => const CaregiverHomeScreen(),
      UserRole.doctor => const DoctorHomeScreen(),
    };

    return Stack(
      children: [
        home,
        if (state.preAlert != null)
          Positioned(
            left: 12,
            right: 12,
            top: MediaQuery.of(context).padding.top + 8,
            child: Material(
              elevation: 6,
              borderRadius: BorderRadius.circular(12),
              color: const Color(0xFFB7791F), // amber — forecast, not yet detected
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
                child: Row(
                  children: [
                    const Icon(Icons.online_prediction, color: Colors.white),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            state.preAlert!.message,
                            style: const TextStyle(
                                color: Colors.white, fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'إلغاء تلقائي خلال ${state.preAlertSecondsLeft} ثانية ثم إبلاغ المختصين',
                            style: const TextStyle(color: Colors.white70, fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.tonal(
                      onPressed: state.cancelPreAlert,
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.white,
                        foregroundColor: const Color(0xFFB7791F),
                      ),
                      child: Text('إلغاء (${state.preAlertSecondsLeft})'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        if (state.lastAlert != null)
          Positioned(
            left: 12,
            right: 12,
            top: MediaQuery.of(context).padding.top + 8,
            child: Material(
              elevation: 6,
              borderRadius: BorderRadius.circular(12),
              color: const Color(0xFFB42318),
              child: ListTile(
                textColor: Colors.white,
                iconColor: Colors.white,
                leading: const Icon(Icons.warning_amber_rounded),
                title: Text(state.lastAlert!.message),
                trailing: IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: state.dismissAlertBanner,
                ),
                onTap: () => state.acknowledgeAlert(state.lastAlert!.id),
              ),
            ),
          ),
      ],
    );
  }
}
