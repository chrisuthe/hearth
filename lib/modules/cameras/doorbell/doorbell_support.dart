import 'dart:io';

import 'package:flutter/foundation.dart';

/// Stands in for the platform check in tests.
@visibleForTesting
bool? debugDoorbellCallSupportedOverride;

/// Whether a doorbell `ring` opens the call view on this build. Android only:
/// the Pi has no WebRTC, and a ring there stays an ordinary card.
///
/// `dart:io`, not `defaultTargetPlatform`, for the reason given on
/// `voiceSatelliteSupported`.
bool get doorbellCallSupported =>
    debugDoorbellCallSupportedOverride ?? (!kIsWeb && Platform.isAndroid);
