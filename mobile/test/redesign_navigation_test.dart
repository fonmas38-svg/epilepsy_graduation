import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:epilepsy_monitor/core/enums.dart';
import 'package:epilepsy_monitor/core/theme/app_theme.dart';
import 'package:epilepsy_monitor/core/ui/session_actions.dart';
import 'package:epilepsy_monitor/core/ui/workspace_scaffold.dart';
import 'package:epilepsy_monitor/features/auth/login_screen.dart';
import 'package:epilepsy_monitor/l10n/app_localizations.dart';
import 'package:epilepsy_monitor/models/models.dart';
import 'package:epilepsy_monitor/providers/app_state.dart';

Widget harness(
  AppState state,
  Widget page, {
  String locale = 'ar',
  double scale = 1,
  Brightness brightness = Brightness.light,
  Widget Function(BuildContext, Widget?)? wrapper,
}) => ChangeNotifierProvider.value(
  value: state,
  child: MaterialApp(
    theme: (brightness == Brightness.dark ? AppTheme.dark() : AppTheme.light())
        .copyWith(
          filledButtonTheme: FilledButtonThemeData(
            style: FilledButton.styleFrom(
              textStyle: const TextStyle(
                fontFamily: 'Roboto',
                fontWeight: FontWeight.w700,
                fontSize: 15,
              ),
            ),
          ),
          textTheme:
              (brightness == Brightness.dark
                      ? AppTheme.dark()
                      : AppTheme.light())
                  .textTheme
                  .apply(fontFamily: 'Roboto'),
        ),
    locale: Locale(locale),
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(scale)),
      child: wrapper == null ? child! : wrapper(context, child),
    ),
    home: page,
  ),
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  for (final width in [360.0, 800.0, 1440.0]) {
    for (final language in ['ar', 'en']) {
      testWidgets('login $width $language at large text is usable', (
        tester,
      ) async {
        await tester.binding.setSurfaceSize(Size(width, 850));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final state = AppState();
        await tester.pumpWidget(
          harness(state, const LoginScreen(), locale: language, scale: 2),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byType(TextField), findsNWidgets(2));
        expect(
          find.text('نظام تشفير سحابي طبي متوافق مع معايير HIPAA و GDPR'),
          findsNothing,
        );
        await tester.pumpWidget(const SizedBox());
        state.dispose();
      });
    }
  }
  for (final role in UserRole.values) {
    testWidgets('adaptive root preserves role $role', (tester) async {
      final state = AppState();
      state.auth.currentUser = AppUser(
        uid: 'user',
        name: 'Test',
        email: 'test',
        role: role,
        linkedPatientIds: [],
      );
      for (final width in [360.0, 1440.0]) {
        await tester.binding.setSurfaceSize(Size(width, 900));
        await tester.pumpWidget(
          harness(
            state,
            const WorkspaceScaffold(body: Center(child: Text('Content'))),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.byType(NavigationRail),
          width >= 900 ? findsOneWidget : findsNothing,
        );
        expect(
          find.byType(NavigationBar),
          width < 900 ? findsOneWidget : findsNothing,
        );
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox());
      await tester.binding.setSurfaceSize(null);
      state.dispose();
    });
  }
  testWidgets('cancelling sign out preserves monitoring and identity', (
    tester,
  ) async {
    final state = AppState();
    state.auth.currentUser = AppUser(
      uid: 'patient',
      name: 'Test',
      email: 'test',
      role: UserRole.patient,
      linkedPatientIds: [],
    );
    state.monitoring.running = true;
    await tester.pumpWidget(
      harness(
        state,
        Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => confirmSignOut(context, state),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('تسجيل الخروج؟'), findsOneWidget);
    expect(
      find.text('ستتوقف المراقبة على هذا الجهاز حتى تسجّل الدخول مجددًا.'),
      findsOneWidget,
    );
    await tester.tap(find.text('البقاء'));
    await tester.pumpAndSettle();
    expect(state.auth.currentUser?.uid, 'patient');
    expect(state.monitoring.running, isTrue);
    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });
  for (final brightness in Brightness.values) {
    testWidgets('login respects $brightness at large text scale', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(390, 850));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final app = AppState();
      await tester.pumpWidget(
        harness(app, const LoginScreen(), scale: 2, brightness: brightness),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final context = tester.element(find.byType(LoginScreen));
      expect(Theme.of(context).brightness, brightness);
      expect(find.byType(TextField), findsNWidgets(2));
      await tester.pumpWidget(const SizedBox());
      app.dispose();
    });
  }
  testWidgets('capture login previews', (tester) async {
    if (!const bool.fromEnvironment('CAPTURE_UI')) return;
    await tester.runAsync(() async {
      final font = FontLoader('Roboto')
        ..addFont(
          File(
            'C:/Windows/Fonts/segoeui.ttf',
          ).readAsBytes().then((bytes) => ByteData.sublistView(bytes)),
        );
      final icons = FontLoader('MaterialIcons')
        ..addFont(
          File(
            'build/unit_test_assets/fonts/MaterialIcons-Regular.otf',
          ).readAsBytes().then((bytes) => ByteData.sublistView(bytes)),
        );
      await font.load();
      await icons.load();
    });
    for (final brightness in Brightness.values) {
      for (final width in [390.0, 1440.0]) {
        await tester.binding.setSurfaceSize(Size(width, 1000));
        tester.view.devicePixelRatio = 1;
        final state = AppState();
        final key = GlobalKey();
        await tester.pumpWidget(
          harness(
            state,
            RepaintBoundary(key: key, child: const LoginScreen()),
            brightness: brightness,
          ),
        );
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          final image =
              await (key.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary)
                  .toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File(
            'build/ui-preview/login-${brightness.name}-${width.toInt()}.png',
          );
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
        await tester.pumpWidget(const SizedBox());
        state.dispose();
      }
    }
    tester.view.resetDevicePixelRatio();
    await tester.binding.setSurfaceSize(null);
  });
}
