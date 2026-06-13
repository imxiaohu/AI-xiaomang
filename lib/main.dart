import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'providers/app_state.dart';
import 'screens/visual_chat_screen.dart';
import 'screens/marketplace_screen.dart';
import 'screens/settings_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
  ));
  runApp(const AIVideoApp());
}

class AIVideoApp extends StatelessWidget {
  const AIVideoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => AppState(),
      child: Consumer<AppState>(
        builder: (context, state, _) {
          return MaterialApp(
            title: 'AI视觉对话助手',
            debugShowCheckedModeBanner: false,
            themeMode: state.settings.themeMode,
            theme: ThemeData(
              brightness: Brightness.dark,
              scaffoldBackgroundColor: Colors.black,
              colorScheme: ColorScheme.fromSeed(
                seedColor: const Color(0xff635bff),
                brightness: Brightness.dark,
              ),
            ),
            darkTheme: ThemeData(
              brightness: Brightness.dark,
              scaffoldBackgroundColor: Colors.black,
              colorScheme: ColorScheme.fromSeed(
                seedColor: const Color(0xff635bff),
                brightness: Brightness.dark,
              ),
            ),
            home: const VisualChatScreen(),
            onGenerateRoute: (settings) {
              switch (settings.name) {
                case '/settings':
                  return MaterialPageRoute(
                    settings: settings,
                    builder: (_) => const SettingsScreen(),
                  );
                case '/marketplace':
                  return MaterialPageRoute(
                    settings: settings,
                    builder: (_) => const MarketplaceScreen(),
                  );
                default:
                  return null;
              }
            },
          );
        },
      ),
    );
  }
}
