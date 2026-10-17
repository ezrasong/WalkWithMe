import 'dart:io';

import 'package:integration_test/integration_test_driver_extended.dart';

Future<void> main() async {
  final directory = Directory(
    Platform.environment['KAZE_IOS_EVIDENCE_DIR'] ??
        '../artifacts/ios/screenshots',
  );
  await directory.create(recursive: true);
  await integrationDriver(
    onScreenshot: (name, bytes, [args]) async {
      await File('${directory.path}/$name.png').writeAsBytes(bytes);
      return bytes.isNotEmpty;
    },
    responseDataCallback: null,
    writeResponseOnFailure: true,
  );
}
