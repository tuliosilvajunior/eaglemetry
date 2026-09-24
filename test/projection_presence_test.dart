import 'package:flutter_test/flutter_test.dart';
import 'package:capy_energy/core/projection_presence_api.dart';

/// The projection tab rule and its wire shape.
void main() {
  ProjectionPresence presence(
    PresenceState carplay,
    PresenceState androidAuto, {
    int? carplayEdgeAt,
    int? androidAutoEdgeAt,
  }) {
    return ProjectionPresence(
      carplay: carplay,
      androidAuto: androidAuto,
      carplayAvailable: true,
      androidAutoAvailable: true,
      carplayEdgeAt: carplayEdgeAt,
      androidAutoEdgeAt: androidAutoEdgeAt,
    );
  }

  ProjectionTabs resolve(
    ProjectionPresence p, {
    bool carplayBound = true,
    bool androidAutoBound = true,
    bool carplayEnabled = true,
    bool androidAutoEnabled = true,
  }) {
    return resolveProjectionTabs(
      presence: p,
      carplayEnabled: carplayEnabled,
      androidAutoEnabled: androidAutoEnabled,
      carplayBound: carplayBound,
      androidAutoBound: androidAutoBound,
    );
  }

  group('resolveProjectionTabs', () {
    test('a connected phone shows its tab alone', () {
      expect(
        resolve(presence(PresenceState.connected, PresenceState.disconnected)),
        const ProjectionTabs(carplay: true, androidAuto: false),
      );
      expect(
        resolve(presence(PresenceState.disconnected, PresenceState.connected)),
        const ProjectionTabs(carplay: false, androidAuto: true),
      );
    });

    test('a connected phone beats an unknown one, bound or not', () {
      // The old rule would have shown both, because `bound` is true on every
      // head unit that has the OEM app installed.
      expect(
        resolve(presence(PresenceState.connected, PresenceState.unknown)),
        const ProjectionTabs(carplay: true, androidAuto: false),
      );
    });

    test('both connected shows the more recent edge', () {
      expect(
        resolve(
          presence(
            PresenceState.connected,
            PresenceState.connected,
            carplayEdgeAt: 100,
            androidAutoEdgeAt: 200,
          ),
        ),
        const ProjectionTabs(carplay: false, androidAuto: true),
      );
      expect(
        resolve(
          presence(
            PresenceState.connected,
            PresenceState.connected,
            carplayEdgeAt: 300,
            androidAutoEdgeAt: 200,
          ),
        ),
        const ProjectionTabs(carplay: true, androidAuto: false),
      );
    });

    test('both connected with no order shows both', () {
      // Hiding one of two live sessions with nothing to choose by would leave
      // no way back to it.
      expect(
        resolve(presence(PresenceState.connected, PresenceState.connected)),
        const ProjectionTabs(carplay: true, androidAuto: true),
      );
      expect(
        resolve(
          presence(
            PresenceState.connected,
            PresenceState.connected,
            carplayEdgeAt: 50,
            androidAutoEdgeAt: 50,
          ),
        ),
        const ProjectionTabs(carplay: true, androidAuto: true),
      );
    });

    test('unknown falls back to bound', () {
      expect(
        resolve(presence(PresenceState.unknown, PresenceState.unknown)),
        const ProjectionTabs(carplay: true, androidAuto: true),
      );
      expect(
        resolve(
          presence(PresenceState.unknown, PresenceState.unknown),
          carplayBound: false,
          androidAutoBound: false,
        ),
        ProjectionTabs.none,
      );
    });

    test(
      'unknown and not bound shows nothing, even beside a disconnection',
      () {
        expect(
          resolve(
            presence(PresenceState.unknown, PresenceState.disconnected),
            carplayBound: false,
          ),
          ProjectionTabs.none,
        );
      },
    );

    test('a disconnected phone hides its tab although it is bound', () {
      // This is the whole point of the feature: `bound` alone showed this tab.
      expect(
        resolve(
          presence(PresenceState.disconnected, PresenceState.disconnected),
        ),
        ProjectionTabs.none,
      );
    });

    test('a beta switch that is off removes its protocol first', () {
      expect(
        resolve(
          presence(PresenceState.connected, PresenceState.connected),
          carplayEnabled: false,
        ),
        const ProjectionTabs(carplay: false, androidAuto: true),
      );
      // Off outranks unknown too, so a switched-off protocol never reaches
      // the `bound` fallback.
      expect(
        resolve(
          presence(PresenceState.unknown, PresenceState.unknown),
          androidAutoEnabled: false,
        ),
        const ProjectionTabs(carplay: true, androidAuto: false),
      );
    });
  });

  group('ProjectionPresence.fromMap', () {
    test('reads the map the native monitor writes', () {
      final parsed = ProjectionPresence.fromMap(const {
        'carplay': 'connected',
        'androidAuto': 'disconnected',
        'carplayAvailable': true,
        'androidAutoAvailable': false,
        'carplayEdgeAt': 1234,
        'androidAutoEdgeAt': null,
      });
      expect(parsed.carplay, PresenceState.connected);
      expect(parsed.androidAuto, PresenceState.disconnected);
      expect(parsed.carplayAvailable, isTrue);
      expect(parsed.androidAutoAvailable, isFalse);
      expect(parsed.carplayEdgeAt, 1234);
      expect(parsed.androidAutoEdgeAt, isNull);
    });

    test('a missing or unreadable key is unknown, never disconnected', () {
      final parsed = ProjectionPresence.fromMap(const {});
      expect(parsed.carplay, PresenceState.unknown);
      expect(parsed.androidAuto, PresenceState.unknown);
      expect(parsed.carplayAvailable, isFalse);

      expect(
        ProjectionPresence.fromMap(const {'carplay': 'CONNECTED'}).carplay,
        PresenceState.unknown,
      );
    });
  });
}
