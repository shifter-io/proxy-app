import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shifter_app/data/models.dart';
import 'package:shifter_app/theme/theme.dart';
import 'package:shifter_app/ui/widgets/membership_card.dart';

void main() {
  setUpAll(() async {
    final fonts = FontLoader('Geist');
    for (final weight in ['Regular', 'SemiBold']) {
      fonts.addFont(rootBundle.load('assets/fonts/Geist-$weight.ttf'));
    }
    await fonts.load();
  });

  Future<RenderParagraph> show(WidgetTester tester, {required double width,
      int lines = 1, double scale = 1, String plan = 'Spark',
      String team = 'Acme Research & Operations International Across Multiple Regions'}) async {
    final membership = ResidentialMembership(
      id: 'team', planName: plan, status: MembershipStatus.active,
      expiresAt: DateTime(2027), pool: ResidentialPool.full,
      workspace: Workspace(id: 'team', name: team, role: 'viewer', personal: false),
    );
    await tester.pumpWidget(MaterialApp(
      theme: buildShifterTheme(),
      home: MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(scale)),
        child: Center(child: SizedBox(width: width, child: MembershipTitle(membership, maxLines: lines))),
      ),
    ));
    expect(tester.takeException(), isNull);
    expect(find.byTooltip('$plan ($team)'), findsOneWidget);
    return tester.renderObject<RenderParagraph>(find.descendant(
      of: find.byType(MembershipTitle), matching: find.byType(RichText)));
  }

  void closingBracketIsVisible(RenderParagraph paragraph) {
    final painted = paragraph.text.toPlainText(includeSemanticsLabels: false);
    expect(painted, endsWith('…)'));
    expect(paragraph.didExceedMaxLines, isFalse);
    final boxes = paragraph.getBoxesForSelection(TextSelection(
      baseOffset: painted.length - 1, extentOffset: painted.length));
    expect(boxes, isNotEmpty, reason: 'The final bracket must be laid out, not clipped or ellipsized');
    for (final box in boxes) {
      expect(box.right, lessThanOrEqualTo(paragraph.size.width + 0.1));
      expect(box.bottom, lessThanOrEqualTo(paragraph.size.height + 0.1));
    }
  }

  for (final (width, lines, scale) in [(100.0, 1, 1.0), (150.0, 2, 1.0), (150.0, 2, 1.5)]) {
    testWidgets('closing bracket stays visible at width $width, $lines lines, scale $scale', (tester) async {
      final paragraph = await show(tester, width: width, lines: lines, scale: scale);
      closingBracketIsVisible(paragraph);
      expect(paragraph.text.toPlainText(includeSemanticsLabels: false), startsWith('Spark ('));
    });
  }

  testWidgets('a fitting workspace name stays complete', (tester) async {
    final paragraph = await show(tester, width: 400, team: 'Acme');
    expect(paragraph.text.toPlainText(includeSemanticsLabels: false), 'Spark (Acme)');
    expect(paragraph.didExceedMaxLines, isFalse);
  });

  testWidgets('long product names also reserve the closing bracket', (tester) async {
    final paragraph = await show(tester, width: 110, plan: 'Enterprise Residential Proxies');
    closingBracketIsVisible(paragraph);
    expect(paragraph.text.toPlainText(includeSemanticsLabels: false), endsWith(' (…)'));
  });

  testWidgets('workspace truncation preserves complete Unicode characters', (tester) async {
    const family = '👩‍👩‍👧‍👦';
    final paragraph = await show(tester, width: 140, team: List.filled(12, family).join());
    closingBracketIsVisible(paragraph);
    final painted = paragraph.text.toPlainText(includeSemanticsLabels: false);
    final prefix = painted.substring('Spark ('.length, painted.length - '…)'.length);
    expect(prefix.characters.every((c) => c == family), isTrue);
  });
}
