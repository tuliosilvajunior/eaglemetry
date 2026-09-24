import 'package:capy_companion/sync/supabase_cloud_sink.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('requestParts', () {
    test('a page shorter than one request stays whole', () {
      expect(requestParts([1, 2, 3], 1000), [
        [1, 2, 3],
      ]);
    });

    test('a page is cut into full parts and whatever is left', () {
      final rows = [for (var i = 0; i < 2500; i++) i];
      final parts = requestParts(rows, 1000);

      expect(parts.map((part) => part.length), [1000, 1000, 500]);
      // Nothing is dropped and nothing is sent twice.
      expect(parts.expand((part) => part), rows);
    });

    test('a page that divides exactly has no empty part at the end', () {
      final rows = [for (var i = 0; i < 2000; i++) i];

      expect(requestParts(rows, 1000).map((part) => part.length), [1000, 1000]);
    });

    test('nothing to send is no request at all', () {
      expect(requestParts(<int>[], 1000), isEmpty);
    });
  });
}
