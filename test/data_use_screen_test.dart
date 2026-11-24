import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shifter_app/theme/theme.dart';
import 'package:shifter_app/ui/screens/data_use_screen.dart';

void main() {
  for (final ios in [true, false]) {
    testWidgets('data-use screen (${ios ? 'iOS' : 'Android'}) explains the connection and asks for a tap', (tester) async {
      var accepted = false;
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(MaterialApp(theme: buildShifterTheme(), home: DataUseScreen(ios: ios, onAccept: () => accepted = true)));
      await tester.pumpAndSettle();
      expect(find.text('Before you connect'), findsOneWidget);
      expect(find.text('Encrypted by default'), findsOneWidget);
      expect(find.text('All traffic between this device and Shifter is encrypted, on Wi-Fi and mobile data.'), findsOneWidget);
      expect(find.text('Only your API key'), findsOneWidget);
      expect(find.text('Never sold or shared'), findsOneWidget);
      expect(find.text('Privacy policy'), findsOneWidget);
      expect(find.textContaining(ios ? 'iOS asks' : 'Android asks'), findsOneWidget);
      await tester.ensureVisible(find.text('Allow and connect'));
      await tester.tap(find.text('Allow and connect'));
      await tester.pumpAndSettle();
      expect(accepted, isTrue);
    });
  }
}
