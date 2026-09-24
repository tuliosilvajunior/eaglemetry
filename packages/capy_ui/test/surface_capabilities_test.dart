import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:capy_ui/capy_ui.dart';

void main() {
  group('SurfaceCapabilities.fromWidth', () {
    test('compact below 600', () {
      const c = SurfaceCapabilities(
        widthClass: SurfaceWidthClass.compact,
        supportsSelection: false,
        inputMode: SurfaceInputMode.touch,
        allowKeyboard: true,
        density: SurfaceDensity.compact,
      );
      expect(
        SurfaceCapabilities.fromWidth(0).widthClass,
        SurfaceWidthClass.compact,
      );
      expect(
        SurfaceCapabilities.fromWidth(320).widthClass,
        SurfaceWidthClass.compact,
      );
      expect(
        SurfaceCapabilities.fromWidth(599).widthClass,
        SurfaceWidthClass.compact,
      );
      expect(
        SurfaceCapabilities.fromWidth(599.9).widthClass,
        SurfaceWidthClass.compact,
      );
      expect(SurfaceCapabilities.fromWidth(320).supportsSelection, isFalse);
      expect(
        SurfaceCapabilities.fromWidth(320).inputMode,
        SurfaceInputMode.touch,
      );
      expect(
        SurfaceCapabilities.fromWidth(320).density,
        SurfaceDensity.compact,
      );
      expect(c.widthClass, SurfaceWidthClass.compact);
    });

    test('medium 600-839', () {
      expect(
        SurfaceCapabilities.fromWidth(600).widthClass,
        SurfaceWidthClass.medium,
      );
      expect(
        SurfaceCapabilities.fromWidth(601).widthClass,
        SurfaceWidthClass.medium,
      );
      expect(
        SurfaceCapabilities.fromWidth(720).widthClass,
        SurfaceWidthClass.medium,
      );
      expect(
        SurfaceCapabilities.fromWidth(839).widthClass,
        SurfaceWidthClass.medium,
      );
      expect(
        SurfaceCapabilities.fromWidth(839.9).widthClass,
        SurfaceWidthClass.medium,
      );
      // medium still touch and no selection (only expanded has rotary/selection)
      expect(SurfaceCapabilities.fromWidth(600).supportsSelection, isFalse);
      expect(
        SurfaceCapabilities.fromWidth(600).inputMode,
        SurfaceInputMode.touch,
      );
      expect(
        SurfaceCapabilities.fromWidth(600).density,
        SurfaceDensity.comfortable,
      );
    });

    test('expanded at 840 and above', () {
      expect(
        SurfaceCapabilities.fromWidth(840).widthClass,
        SurfaceWidthClass.expanded,
      );
      expect(
        SurfaceCapabilities.fromWidth(840.1).widthClass,
        SurfaceWidthClass.expanded,
      );
      expect(
        SurfaceCapabilities.fromWidth(1280).widthClass,
        SurfaceWidthClass.expanded,
      );
      expect(
        SurfaceCapabilities.fromWidth(1920).widthClass,
        SurfaceWidthClass.expanded,
      );
      expect(SurfaceCapabilities.fromWidth(1920).supportsSelection, isTrue);
      expect(
        SurfaceCapabilities.fromWidth(1920).inputMode,
        SurfaceInputMode.rotary,
      );
      expect(
        SurfaceCapabilities.fromWidth(1920).density,
        SurfaceDensity.comfortable,
      );
    });

    test('phone is compact, head unit is expanded', () {
      // Spec expectation: phone (~390) is compact, car head unit (1920) is expanded.
      final phone = SurfaceCapabilities.fromWidth(390);
      final car = SurfaceCapabilities.fromWidth(1920);
      expect(phone.widthClass, SurfaceWidthClass.compact);
      expect(car.widthClass, SurfaceWidthClass.expanded);
      expect(phone.inputMode, SurfaceInputMode.touch);
      expect(car.inputMode, SurfaceInputMode.rotary);
    });
  });

  group('SurfaceCapabilities.of', () {
    testWidgets('derives widthClass from MediaQuery.sizeOf', (tester) async {
      Future<SurfaceWidthClass> widthClassFor(double width) async {
        await tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(size: Size(width, 1080)),
              child: Builder(
                builder: (context) {
                  final caps = SurfaceCapabilities.of(context);
                  return Text(caps.widthClass.name);
                },
              ),
            ),
          ),
        );
        final text = tester.widget<Text>(find.byType(Text));
        return SurfaceWidthClass.values.firstWhere(
          (value) => value.name == text.data,
        );
      }

      expect(await widthClassFor(599), SurfaceWidthClass.compact);
      expect(await widthClassFor(600), SurfaceWidthClass.medium);
      expect(await widthClassFor(839), SurfaceWidthClass.medium);
      expect(await widthClassFor(840), SurfaceWidthClass.expanded);
      expect(await widthClassFor(390), SurfaceWidthClass.compact);
      expect(await widthClassFor(1920), SurfaceWidthClass.expanded);
    });
  });

  group('SurfaceCapabilities equality and copyWith', () {
    test('copyWith allowKeyboard', () {
      final base = SurfaceCapabilities.fromWidth(390);
      expect(base.allowKeyboard, isTrue);
      final blocked = base.copyWith(allowKeyboard: false);
      expect(blocked.allowKeyboard, isFalse);
      expect(blocked.widthClass, base.widthClass);
      expect(blocked.inputMode, base.inputMode);
      expect(blocked == base, isFalse);
      expect(blocked.copyWith(allowKeyboard: true) == base, isTrue);
    });

    test('equality', () {
      final a = SurfaceCapabilities.fromWidth(1920);
      final b = SurfaceCapabilities.fromWidth(1920);
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });
  });
}
