import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre/maplibre.dart' as ml;
import 'package:kaze/main.dart';

Map<String, dynamic> located() => {
  'id': 'test-session',
  'shared': true,
  'geography': {
    'latest': {
      'latitude': 43.6,
      'longitude': -79.4,
      'accuracy': 100,
      'fixAt': 1,
    },
    'paths': [
      {
        'source': 'phone',
        'points': [
          {'latitude': 43.6, 'longitude': -79.4},
          {'latitude': 43.601, 'longitude': -79.4},
        ],
      },
      {
        'source': 'phone',
        'points': [
          {'latitude': 43.61, 'longitude': -79.4},
          {'latitude': 43.611, 'longitude': -79.4},
        ],
      },
      {
        'source': 'watch',
        'points': [
          {'latitude': 43.62, 'longitude': -79.4},
          {'latitude': 43.621, 'longitude': -79.4},
        ],
      },
    ],
  },
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'dark street labels retain readable contrast against the map background',
    () async {
      final style = jsonDecode(
        await rootBundle.loadString('assets/maps/dark.json'),
      );
      final background = const Color(0xff11151b).computeLuminance();
      for (final layer in style['layers']) {
        if (layer['type'] == 'symbol' &&
            layer['layout']?['text-field'] != null) {
          final hex = (layer['paint']['text-color'] as String).substring(1);
          final color = Color(int.parse('ff$hex', radix: 16));
          expect(
            (color.computeLuminance() + .05) / (background + .05),
            greaterThanOrEqualTo(4.5),
            reason: layer['id'],
          );
        }
      }
    },
  );
  test(
    'vector renderer preserves separate sources and broken trail sections',
    () {
      final layers = trailLayers(located());
      final lines = layers.whereType<ml.PolylineLayer>().toList();
      expect(lines, hasLength(2));
      expect(lines[0].list, hasLength(2));
      expect(lines[1].list, hasLength(1));
      expect(lines[0].dashArray, isNull);
      expect(lines[1].dashArray, isNotEmpty);
      expect(lines[0].color, isNot(lines[1].color));
      for (final line in lines.expand((layer) => layer.list)) {
        expect(line.geometry!.chain.positionCount, 2);
      }
      expect(layers.whereType<ml.PolygonLayer>().single.list, hasLength(1));
      expect(
        trailLayers({
          'geography': {'latest': null},
        }),
        isEmpty,
      );
    },
  );

  testWidgets('private map placeholder fits large text and both appearances', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 560);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final brightness in Brightness.values) {
      await tester.pumpWidget(
        MaterialApp(
          theme: kazeTheme(brightness),
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(1.8)),
            child: const Scaffold(
              body: TrailMap(snapshot: {'shared': false}, tiles: false),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.textContaining('Trail stays private'), findsOneWidget);
      expect(find.byType(ml.MapLibreMap), findsNothing);
    }
    await tester.pumpWidget(const SizedBox());
  });
}
