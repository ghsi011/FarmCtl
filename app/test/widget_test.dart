import 'package:farmctl/app.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('FarmCtl renders bottom navigation', (tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: FarmCtlApp(),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('Thermostats'), findsWidgets);
    expect(find.text('Settings'), findsWidgets);
  });
}
