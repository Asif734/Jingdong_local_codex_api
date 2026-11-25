/// Read only authorization captured with the pixels. A cold context cache must
/// not erase an AX arrival/recovery that was already known before capture.
Map<String, Object?>? captureContextFromFrozenSnapshot(
    Map<String, Object?> snapshot) {
  final context = snapshot['context'];
  if (context is Map) return Map<String, Object?>.from(context);
  final arrival = snapshot['liveArrival'];
  if (snapshot['recoveryActive'] != true &&
      !(arrival is String && arrival.isNotEmpty)) {
    return null;
  }
  // No later cycle, frontier, pending state or acquisition scope is borrowed.
  // Complete incoming clocks still have to pass the frame's fixed Start bound.
  return {
    'cycle': null,
    'durable': false,
    'hasDiscoveryAnchor': false,
    'observedArrival': null,
    'frontier': null,
    'acquisitions': const [],
    'onlyAcquisitionWork': false,
  };
}
