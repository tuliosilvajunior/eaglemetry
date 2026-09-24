import 'package:flutter_test/flutter_test.dart';
import 'package:capy_energy/core/app_experience_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final controller = AppExperienceController.instance;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await controller.reset();
  });

  tearDown(() async {
    await controller.reset();
  });

  test('the new shell is the default when nothing is persisted', () async {
    await controller.load();

    expect(controller.newUiEnabled, isTrue);
  });

  test('the picked shell persists across a reload', () async {
    await controller.load();

    await controller.setNewUiEnabled(false);
    expect(controller.newUiEnabled, isFalse);

    await controller.load();
    expect(controller.newUiEnabled, isFalse);

    await controller.setNewUiEnabled(true);
    expect(controller.newUiEnabled, isTrue);

    await controller.load();
    expect(controller.newUiEnabled, isTrue);
  });

  test('the CarPlay beta is off until asked for, and then persists', () async {
    await controller.load();
    expect(controller.projectionEnabled, isFalse);

    await controller.setProjectionEnabled(true);
    await controller.load();
    expect(controller.projectionEnabled, isTrue);
    // The two choices are stored under separate keys and must not drag each
    // other along.
    expect(controller.newUiEnabled, isTrue);
  });

  test(
    'welcomeSeen is false by default and persists after setWelcomeSeen',
    () async {
      await controller.load();
      expect(controller.welcomeSeen, isFalse);

      await controller.setWelcomeSeen(true);
      expect(controller.welcomeSeen, isTrue);

      await controller.load();
      expect(controller.welcomeSeen, isTrue);
    },
  );

  test('reset clears the persisted choices, including welcomeSeen', () async {
    await controller.setNewUiEnabled(false);
    await controller.setProjectionEnabled(true);
    await controller.setWelcomeSeen(true);
    await controller.setClimateBarEnabled(true);

    await controller.reset();
    await controller.load();

    expect(controller.newUiEnabled, isTrue);
    expect(controller.projectionEnabled, isFalse);
    expect(controller.welcomeSeen, isFalse);
    expect(controller.climateBarEnabled, isFalse);
  });

  test('the climate bar is off until asked for, and then persists', () async {
    await controller.load();
    expect(controller.climateBarEnabled, isFalse);

    await controller.setClimateBarEnabled(true);
    expect(controller.climateBarEnabled, isTrue);

    await controller.load();
    expect(controller.climateBarEnabled, isTrue);
  });
}
