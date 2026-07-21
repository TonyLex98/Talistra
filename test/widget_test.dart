import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:transreade/main.dart';
import 'package:transreade/services/library_service.dart';
import 'package:transreade/services/settings_service.dart';

void main() {
  testWidgets('Home screen shows empty library state', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final settings = SettingsService.load(prefs);
    final library = await LibraryService.load(prefs);

    await tester.pumpWidget(TransReadeApp(settings: settings, library: library));
    await tester.pumpAndSettle();

    expect(find.text('TransRead'), findsOneWidget);
    expect(find.text('Ваша библиотека пуста'), findsOneWidget);
  });
}
