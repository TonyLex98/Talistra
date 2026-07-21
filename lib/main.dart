import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'screens/home_screen.dart';
import 'services/library_service.dart';
import 'services/model_download_service.dart';
import 'services/settings_service.dart';
import 'services/translation_service.dart';
import 'theme/app_theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Optional: register a free Syncfusion Community License at
  // https://www.syncfusion.com/products/communitylicense to remove the
  // trial banner from the PDF viewer, then uncomment the line below:
  // SyncfusionLicense.registerLicense('YOUR_LICENSE_KEY');

  final prefs = await SharedPreferences.getInstance();
  final settings = SettingsService.load(prefs);
  final library = await LibraryService.load(prefs);

  runApp(TransReadeApp(settings: settings, library: library));
}

class TransReadeApp extends StatelessWidget {
  const TransReadeApp({super.key, required this.settings, required this.library});

  final SettingsService settings;
  final LibraryService library;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<SettingsService>.value(value: settings),
        ChangeNotifierProvider<LibraryService>.value(value: library),
        Provider<TranslationService>(
          create: (_) => TranslationService(),
          dispose: (_, service) => service.dispose(),
        ),
        ChangeNotifierProxyProvider<TranslationService, ModelDownloadService>(
          create: (context) => ModelDownloadService(context.read<TranslationService>()),
          update: (context, translationService, previous) =>
              previous ?? ModelDownloadService(translationService),
        ),
      ],
      child: Consumer<SettingsService>(
        builder: (context, settings, _) {
          return MaterialApp(
            title: 'TransRead',
            debugShowCheckedModeBanner: false,
            themeMode: settings.themeMode,
            theme: AppTheme.light(),
            darkTheme: AppTheme.dark(),
            home: const HomeScreen(),
          );
        },
      ),
    );
  }
}
