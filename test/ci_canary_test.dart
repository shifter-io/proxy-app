import 'package:flutter_test/flutter_test.dart';

// Deliberately failing: CI proof, never merged.
void main() {
  test('ci canary fails on purpose', () {
    expect(1 + 1, 3);
  });
}
