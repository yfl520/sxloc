import 'package:material_ui/material_ui.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:window_manager/window_manager.dart';

import 'workspace.dart';
import 'ui.dart';
import 'service_agreement.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  await windowManager.waitUntilReadyToShow(
    const WindowOptions(
      size: Size(1380, 860),
      minimumSize: Size(1040, 680),
      center: true,
      titleBarStyle: TitleBarStyle.hidden,
      windowButtonVisibility: false,
      title: '随行定位',
    ),
    () async {
      await windowManager.show();
      await windowManager.focus();
    },
  );
  runApp(const MainApp());
}

class MainApp extends StatelessWidget {
  const MainApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '随行定位',
      debugShowCheckedModeBanner: false,
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: ThemeData(
        useMaterial3: false,
        platform: TargetPlatform.macOS,
        scaffoldBackgroundColor: const Color(0xFFF6F6F8),
        colorScheme: const ColorScheme.light(primary: blue),
        fontFamily: 'Segoe UI',
        fontFamilyFallback: const ['Microsoft YaHei UI', 'PingFang SC'],
        textTheme: TextTheme(
          bodyMedium: textStyle(),
          bodySmall: textStyle(11, muted),
        ),
        cupertinoOverrideTheme: const CupertinoThemeData(
          primaryColor: blue,
          brightness: Brightness.light,
        ),
        tooltipTheme: TooltipThemeData(
          textStyle: textStyle(11, Colors.white),
          waitDuration: const Duration(milliseconds: 500),
        ),
      ),
      home: AgreementGate(
        onDecline: () => windowManager.destroy(),
        builder: (_) => const Workspace(),
      ),
    );
  }
}
