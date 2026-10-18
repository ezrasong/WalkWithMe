import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';

import 'package:flutter/material.dart';
import 'package:maplibre/maplibre.dart' as ml;
import 'package:url_launcher/url_launcher.dart';

const phoneTrailColor = Color(0xff2371cf);
const watchTrailColor = Color(0xffad59c4);

ml.Geographic trailPoint(Map fix) => ml.Geographic(
  lat: (fix['latitude'] as num).toDouble(),
  lon: (fix['longitude'] as num).toDouble(),
);

// Each server path remains a separate feature: no source merging or gap filling.
List<ml.Layer> trailLayers(Map<String, dynamic> snapshot) {
  final geo = snapshot['geography'] as Map?;
  final latest = geo?['latest'] as Map?;
  if (latest == null) return [];
  final center = trailPoint(latest);
  final radius = (latest['accuracy'] as num).toDouble();
  final ring = [
    for (var bearing = 0; bearing < 360; bearing += 6)
      center.vincenty().destinationPoint(
        distance: radius,
        bearing: bearing.toDouble(),
      ),
  ];
  final closedRing = ring.reversed.toList()..add(ring.last);
  final paths = (geo?['mapPaths'] ?? geo?['paths']) as List? ?? [];
  final point = ml.Feature(geometry: ml.Point(center));
  return [
    ml.PolygonLayer(
      polygons: [
        ml.Feature(geometry: ml.Polygon.from([closedRing])),
      ],
      color: phoneTrailColor.withValues(alpha: .12),
      outlineColor: phoneTrailColor.withValues(alpha: .6),
    ),
    for (final source in ['phone', 'watch'])
      ml.PolylineLayer(
        polylines: [
          for (final path in paths)
            if (path['source'] == source && (path['points'] as List).length > 1)
              ml.Feature(
                geometry: ml.LineString.from([
                  for (final fix in path['points']) trailPoint(fix),
                ]),
              ),
        ],
        color: source == 'phone' ? phoneTrailColor : watchTrailColor,
        width: 5,
        dashArray: source == 'watch' ? [2, 2] : null,
      ),
    ml.CircleLayer(
      points: [point],
      radius: 12,
      color: phoneTrailColor,
      strokeWidth: 3,
      strokeColor: Colors.white,
    ),
  ];
}

class TrailMap extends StatefulWidget {
  final Map<String, dynamic> snapshot;
  final bool tiles;
  const TrailMap({super.key, required this.snapshot, required this.tiles});
  @override
  State<TrailMap> createState() => _TrailMapState();
}

class _TrailMapState extends State<TrailMap> {
  ml.MapController? controller;
  bool following = true, loaded = false, failed = false;
  String style = '';
  int retry = 0;
  Timer? loadingTimer;
  Map? get geo => widget.snapshot['geography'] as Map?;
  Map? get latest => geo?['latest'] as Map?;
  List get paths => (geo?['mapPaths'] ?? geo?['paths']) as List? ?? [];
  double get locationZoom => (latest?['accuracy'] as num? ?? 0) > 50 ? 15 : 16;
  String get nextStyle => widget.tiles
      ? Theme.of(context).brightness == Brightness.dark
            ? 'assets/maps/dark.json'
            : 'https://tiles.openfreemap.org/styles/positron'
      : jsonEncode({
          'version': 8,
          'sources': {},
          'layers': [
            {
              'id': 'background',
              'type': 'background',
              'paint': {
                'background-color':
                    Theme.of(context).brightness == Brightness.dark
                    ? '#101216'
                    : '#f3f4f7',
              },
            },
          ],
        });

  void updateStyle() {
    final next = nextStyle;
    if (next == style) return;
    style = next;
    loaded = false;
    failed = false;
    controller?.setStyle(style);
    if (controller != null) startLoadingTimer();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    updateStyle();
  }

  @override
  void didUpdateWidget(covariant TrailMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.tiles != widget.tiles) updateStyle();
    final previous = (oldWidget.snapshot['geography'] as Map?)?['latest'];
    if (following &&
        controller != null &&
        latest != null &&
        (previous == null ||
            previous['fixAt'] != latest!['fixAt'] ||
            previous['latitude'] != latest!['latitude'] ||
            previous['longitude'] != latest!['longitude'])) {
      cameraAction((map) => map.moveCamera(center: trailPoint(latest!)));
    }
  }

  void startLoadingTimer() {
    loadingTimer?.cancel();
    loadingTimer = Timer(const Duration(seconds: 15), () {
      if (mounted && !loaded) setState(() => failed = true);
    });
  }

  @override
  void dispose() {
    loadingTimer?.cancel();
    super.dispose();
  }

  void recenter() {
    setState(() => following = true);
    cameraAction(
      (map) => map.moveCamera(center: trailPoint(latest!), zoom: locationZoom),
    );
  }

  Future<void> cameraAction(
    Future<void> Function(ml.MapController) action,
  ) async {
    final map = controller;
    if (map == null) return;
    try {
      await action(map);
    } catch (error) {
      // A newer gesture/action cancels an in-flight SDK camera animation.
      if (!mounted ||
          map != controller ||
          error.toString().contains('Map camera movement cancelled')) {
        return;
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          ScaffoldMessenger.maybeOf(context)?.showSnackBar(
            const SnackBar(content: Text('The map could not move. Try again.')),
          );
        }
      });
    }
  }

  void fitTrail() {
    final points = <ml.Geographic>[
      for (final path in paths)
        for (final fix in path['points']) trailPoint(fix),
      if (latest != null) trailPoint(latest!),
    ];
    if (points.isEmpty) return;
    setState(() => following = false);
    final bounds = ml.LngLatBounds.fromPoints(points);
    if (bounds.latitudeSouth == bounds.latitudeNorth &&
        bounds.longitudeWest == bounds.longitudeEast) {
      cameraAction(
        (map) => map.moveCamera(center: points.first, zoom: locationZoom),
      );
    } else {
      cameraAction(
        (map) => map.fitBounds(
          bounds: bounds,
          padding: const EdgeInsets.fromLTRB(36, 72, 72, 36),
          nativeDuration: Duration(
            milliseconds: MediaQuery.disableAnimationsOf(context) ? 1 : 250,
          ),
          webMaxZoom: 17,
        ),
      );
    }
  }

  Widget control(String label, IconData icon, VoidCallback action) =>
      IconButton(
        tooltip: label,
        onPressed: controller != null ? action : null,
        icon: Icon(icon),
        constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
      );

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    if (latest == null) {
      return ColoredBox(
        color: colors.surfaceContainerLow,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  widget.snapshot['shared'] == true
                      ? Icons.location_searching
                      : Icons.lock_outline,
                  size: 40,
                  color: colors.primary,
                ),
                const SizedBox(height: 16),
                Text(
                  widget.snapshot['shared'] == true
                      ? 'No location received yet.\nCheck-ins still work.'
                      : 'Trail stays private until\na check-in goes unanswered.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ],
            ),
          ),
        ),
      );
    }
    return Stack(
      children: [
        ml.MapLibreMap(
          key: ValueKey('${widget.snapshot['id']}-$retry'),
          options: ml.MapOptions(
            initStyle: style,
            initCenter: trailPoint(latest!),
            initZoom: locationZoom,
            minZoom: 2,
            maxZoom: 20,
            maxPitch: 0,
            gestures: const ml.MapGestures.all(rotate: false, pitch: false),
          ),
          onMapCreated: (value) {
            if (mounted) {
              setState(() => controller = value);
              startLoadingTimer();
            }
          },
          onStyleLoaded: (_) {
            if (mounted) {
              loadingTimer?.cancel();
              setState(() {
                loaded = true;
                failed = false;
              });
            }
          },
          onEvent: (event) {
            if (event is ml.MapEventStartMoveCamera &&
                event.reason == ml.CameraChangeReason.apiGesture &&
                following) {
              setState(() => following = false);
            }
          },
          gestureRecognizers: {
            Factory<OneSequenceGestureRecognizer>(
              () => EagerGestureRecognizer(),
            ),
          },
          layers: trailLayers(widget.snapshot),
        ),
        Positioned(
          top: 12,
          left: 12,
          right: 72,
          child: IgnorePointer(
            child: Material(
              color: colors.surface,
              elevation: 2,
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Wrap(
                  spacing: 16,
                  runSpacing: 8,
                  children: [
                    legend(
                      Icons.phone_android,
                      'Phone',
                      phoneTrailColor,
                      context,
                    ),
                    legend(
                      Icons.watch_outlined,
                      'Watch · dashed',
                      watchTrailColor,
                      context,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        Positioned(
          top: 12,
          right: 12,
          child: Material(
            color: colors.surface,
            elevation: 3,
            borderRadius: BorderRadius.circular(14),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                control(
                  'Recenter on last location',
                  following ? Icons.my_location : Icons.location_searching,
                  recenter,
                ),
                control(
                  'Show entire recorded trail',
                  Icons.route_outlined,
                  fitTrail,
                ),
              ],
            ),
          ),
        ),
        Positioned(
          bottom: 48,
          right: 12,
          child: Material(
            color: colors.surface,
            elevation: 3,
            borderRadius: BorderRadius.circular(14),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                control(
                  'Zoom out',
                  Icons.remove,
                  () => cameraAction(
                    (map) => map.moveCamera(
                      zoom: (map.getCamera().zoom - 1).clamp(2, 20),
                    ),
                  ),
                ),
                control(
                  'Zoom in',
                  Icons.add,
                  () => cameraAction(
                    (map) => map.moveCamera(
                      zoom: (map.getCamera().zoom + 1).clamp(2, 20),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (widget.tiles)
          Positioned(
            bottom: 4,
            left: 8,
            right: 8,
            child: Align(
              alignment: Alignment.bottomLeft,
              child: Material(
                color: colors.surface.withValues(alpha: .95),
                borderRadius: BorderRadius.circular(6),
                child: InkWell(
                  onTap: () => launchUrl(
                    Uri.parse('https://openfreemap.org/'),
                    mode: LaunchMode.externalApplication,
                  ),
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                    child: Text(
                      'OpenFreeMap · © OpenMapTiles · © OpenStreetMap',
                      style: TextStyle(fontSize: 11),
                    ),
                  ),
                ),
              ),
            ),
          ),
        if (failed)
          Center(
            child: Material(
              color: colors.surface,
              borderRadius: BorderRadius.circular(16),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'Street map unavailable.\nRecorded evidence is unchanged.',
                      textAlign: TextAlign.center,
                    ),
                    TextButton(
                      onPressed: () => setState(() {
                        controller = null;
                        loaded = false;
                        failed = false;
                        retry++;
                      }),
                      child: const Text('Retry map'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        if (!widget.tiles)
          Positioned(
            left: 12,
            bottom: 8,
            child: Material(
              color: colors.surface,
              borderRadius: BorderRadius.circular(8),
              child: const Padding(
                padding: EdgeInsets.all(8),
                child: Text('Street map off'),
              ),
            ),
          ),
      ],
    );
  }

  Widget legend(
    IconData icon,
    String label,
    Color color,
    BuildContext context,
  ) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, color: color, size: 18),
      const SizedBox(width: 6),
      Flexible(
        child: Text(label, style: Theme.of(context).textTheme.labelMedium),
      ),
    ],
  );
}
