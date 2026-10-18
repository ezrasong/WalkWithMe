import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'trail_map.dart';
import 'relative_motion.dart';

class CameraNavigation extends StatelessWidget {
  final Widget camera;
  final Map<String, dynamic> snapshot;
  final Map<String, Object>? guardianLocation;
  final double? turn, distance;
  final bool nearby, simulated;
  final String mode, details;
  final String? street;
  const CameraNavigation({
    super.key,
    required this.camera,
    required this.snapshot,
    required this.mode,
    required this.details,
    this.guardianLocation,
    this.turn,
    this.distance,
    this.street,
    this.nearby = false,
    this.simulated = false,
  });

  String get instruction => turn == null
      ? 'Finding your direction'
      : nearby
      ? 'Search within the location area'
      : turn!.abs() < .35
      ? 'Continue ahead'
      : turn!.abs() > 2.6
      ? 'Turn around'
      : turn! > 0
      ? 'Turn right'
      : 'Turn left';

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final heading = distance == null
        ? instruction
        : '${distance!.round()} m - $instruction';
    final mapSnapshot = {
      ...snapshot,
      if (guardianLocation != null) 'guardianLocation': guardianLocation,
    };
    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          camera,
          const IgnorePointer(child: ColoredBox(color: Color(0x22000000))),
          SafeArea(
            child: LayoutBuilder(
              builder: (context, size) => SingleChildScrollView(
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: size.maxHeight),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(
                              children: [
                                IconButton.filledTonal(
                                  tooltip: 'Return to map',
                                  onPressed: () => Navigator.of(context).pop(),
                                  icon: const Icon(Icons.arrow_back),
                                ),
                                const SizedBox(width: 12),
                                const Expanded(
                                  child: Text(
                                    'WalkWithMe camera guide',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 20,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            Material(
                              color: colors.surface,
                              borderRadius: BorderRadius.circular(20),
                              elevation: 4,
                              child: Padding(
                                padding: const EdgeInsets.all(16),
                                child: Row(
                                  children: [
                                    Icon(
                                      nearby
                                          ? Icons.location_searching
                                          : turn == null
                                          ? Icons.explore_outlined
                                          : turn!.abs() < .35
                                          ? Icons.straight
                                          : turn! > 0
                                          ? Icons.turn_right
                                          : Icons.turn_left,
                                      color: colors.primary,
                                      size: 40,
                                    ),
                                    const SizedBox(width: 16),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            heading,
                                            style: Theme.of(context)
                                                .textTheme
                                                .titleLarge,
                                          ),
                                          Text(
                                            street ??
                                                'Follow the recorded trail',
                                          ),
                                          const SizedBox(height: 4),
                                          Text(
                                            '${simulated ? 'DEMO - ' : ''}$mode',
                                            style: Theme.of(context)
                                                .textTheme
                                                .labelMedium,
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                        SizedBox(
                          height: math.max(88, size.maxHeight * .2),
                          child: Center(
                            child: turn == null
                                ? const SizedBox.shrink()
                                : Semantics(
                                    label: heading,
                                    child: Transform.rotate(
                                      angle: nearby ? 0 : turn!,
                                      child: DecoratedBox(
                                        decoration: BoxDecoration(
                                          color: colors.primary,
                                          borderRadius: BorderRadius.circular(
                                            24,
                                          ),
                                          border: Border.all(
                                            color: Colors.white,
                                            width: 4,
                                          ),
                                          boxShadow: const [
                                            BoxShadow(
                                              color: Colors.black38,
                                              blurRadius: 16,
                                              offset: Offset(0, 6),
                                            ),
                                          ],
                                        ),
                                        child: Padding(
                                          padding: const EdgeInsets.all(12),
                                          child: Icon(
                                            nearby
                                                ? Icons.location_searching
                                                : Icons.arrow_upward_rounded,
                                            size: 72,
                                            color: colors.onPrimary,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                          ),
                        ),
                        Material(
                          color: colors.surface,
                          borderRadius: BorderRadius.circular(20),
                          elevation: 4,
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Text(
                                  details,
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                                if (snapshot['relativeMotion']?['available'] ==
                                    true)
                                  RelativeMotionCard(
                                    motion: snapshot['relativeMotion'] as Map?,
                                    compact: true,
                                  ),
                                const SizedBox(height: 8),
                                SizedBox(
                                  height: (size.maxHeight * .2).clamp(100, 180),
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(12),
                                    child: TrailMap(
                                      snapshot: mapSnapshot,
                                      tiles: true,
                                      compact: true,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 6),
                                const Text(
                                  'Green dot: you. Trail: shared locations. Check the surroundings before walking.',
                                  style: TextStyle(fontSize: 12),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
