import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

import '../domain/capture_models.dart';
import '../domain/customer_message_time.dart';
import '../capture/viewport_evidence.dart';
import '../capture/row_resolution_guard.dart';
import '../runtime/runtime_trace.dart';
import 'capture_adapter.dart';

bool customerIdentitiesMatch(String? observed, String expected) =>
    observed != null && observed.trim() == expected.trim();

enum ConversationOpenPurpose { delivery, transfer }

class MacOSCaptureAdapter implements CaptureAdapter {
  MacOSCaptureAdapter({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(_channelName) {
    _channel.setMethodCallHandler(_onNativeCall);
  }

  /// Export barrier only; never used in the capture/send critical path.
  Future<void> flushDiagnosticTrace() async {
    await _channel.invokeMethod<void>('flushDiagnosticTrace');
  }

  static const _channelName = 'com.grozziie.jdAutomation/accessibility';
  final MethodChannel _channel;
  final _pendingLocalCalls = <Completer<Map<Object?, Object?>?>>{};
  final _captures = StreamController<CapturedConversation>.broadcast();
  final _diagnostics = StreamController<Map<String, Object?>>.broadcast();
  final _failedSendInspections =
      StreamController<FailedSendInspection>.broadcast();
  static const provisionalPrefix = 'pending-row:';
  static bool isProvisionalIdentity(String customer) =>
      customer.startsWith(provisionalPrefix);
  final _rowReferences = <String, ({String key, String token})>{};
  final _openingRows = <String, Future<void>>{};
  final _rowResolution = RowResolutionGuard();
  bool rowResolutionDue(String customer) =>
      !isProvisionalIdentity(customer) ||
      _verifiedIdentityFor(customer) != customer ||
      _rowResolution.due(customer);
  DateTime? rowResolutionRetryAt(String customer) =>
      _rowResolution.retryAt(customer);
  bool rowResolutionSuspended(String customer) =>
      _rowResolution.suspended(customer);
  void resetRowResolution() => _rowResolution.reset();

  final Map<String, String> _verifiedCustomerIdentities = {};
  // A Dart timeout does not cancel a native Vision request. Keep its future
  // until completion so timer polls cannot accumulate obsolete OCR work.
  final Map<String, Future<OcrInspection>> _ocrInspections = {};
  final Map<(String, int, String), Future<CachedMediaPayload?>>
      _cachedMediaCaptures = {};
  Future<String?>? _mediaCacheRevision;
  String? _currentServiceAccount;
  int _serviceAccountReadGeneration = 0;

  /// The last verified literal AX operator account. Refresh before deciding
  /// that a customer's named transfer target is already receiving the chat.
  String? get currentServiceAccount => _currentServiceAccount;

  String _identityKey(String value) =>
      value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

  /// Available only after native opening independently confirmed the AX name.
  String verifiedCustomerIdentity(String customer) =>
      _verifiedIdentityFor(customer);

  String _verifiedIdentityFor(String customer) =>
      isProvisionalIdentity(customer)
          ? _verifiedCustomerIdentities[_identityKey(customer)] ?? customer
          : customer;

  void _rememberVerifiedIdentity(String requested, Object? verified) {
    final identity = verified?.toString().trim() ?? '';
    if (identity.isEmpty || isProvisionalIdentity(identity)) {
      throw PlatformException(code: 'customer_identity_unconfirmed');
    }
    if (!isProvisionalIdentity(requested)) {
      if (!customerIdentitiesMatch(identity, requested)) {
        throw PlatformException(code: 'customer_identity_mismatch', details: {
          'expectedCustomer': requested,
          'activeCustomerId': identity
        });
      }
      return;
    }
    final prior = _verifiedCustomerIdentities[_identityKey(requested)];
    if (prior != null && !customerIdentitiesMatch(prior, identity)) {
      RuntimeTrace.record('identity.row_binding_conflict', {
        'observedRow': requested,
        'previousCustomer': prior,
        'activeCustomerId': identity
      });
      throw PlatformException(code: 'row_identity_conflict');
    }
    _rowResolution.resolved(requested);
    _verifiedCustomerIdentities[_identityKey(requested)] = identity;
  }

  @override
  Stream<CapturedConversation> get captures => _captures.stream;

  @override
  Stream<Map<String, Object?>> get diagnostics => _diagnostics.stream;

  Stream<FailedSendInspection> get failedSendInspections =>
      _failedSendInspections.stream;

  Future<void> close() async {
    _serviceAccountReadGeneration++;
    _currentServiceAccount = null;
    await _captures.close();
    await _diagnostics.close();
    await _failedSendInspections.close();
  }

  Future<void> _onNativeCall(MethodCall call) async {
    final arguments = (call.arguments as Map<Object?, Object?>?) ?? const {};
    if (call.method == 'capture' && !_captures.isClosed) {
      _captures.add(CapturedConversation.fromMap(arguments));
    } else if (call.method == 'diagnostic' && !_diagnostics.isClosed) {
      _diagnostics.add(arguments.map((key, value) => MapEntry('$key', value)));
    } else if (call.method == 'failedSendCandidates') {
      final inspection = FailedSendInspection.fromMap(arguments);
      if (!_failedSendInspections.isClosed &&
          inspection.customer.isNotEmpty &&
          inspection.candidates.isNotEmpty) {
        _failedSendInspections.add(inspection);
      }
    }
  }

  @override
  Future<Map<String, Object?>> status() => _mapCall('status');

  /// Read-only account identity from the reception header, corroborated by
  /// the AX window title. Missing or changed proof clears the old account.
  Future<Map<String, Object?>> readCurrentServiceAccount() async {
    final generation = ++_serviceAccountReadGeneration;
    _currentServiceAccount = null;
    try {
      final value = await _mapCall('readCurrentServiceAccount');
      final account = value['account'] is String
          ? (value['account']! as String).trim()
          : null;
      final title = value['windowTitle'] is String
          ? (value['windowTitle']! as String).trim()
          : '';
      final titleAccount =
          title.replaceFirst(RegExp(r'\s*[-–—]\s*咚咚融合工作台\s*$'), '').trim();
      final verified = generation == _serviceAccountReadGeneration &&
          value['verified'] == true &&
          value['source'] == 'accessibility_account_header' &&
          account != null &&
          account.isNotEmpty &&
          !const {
            '当前客服账号',
            '当前客服',
            'source',
            'source_account',
            'account',
            'unknown',
            '未确认',
            '京麦',
            '咚咚融合工作台'
          }.contains(account.toLowerCase()) &&
          titleAccount != title &&
          titleAccount == account &&
          value['windowTitleAccount'] == account &&
          value['observedAtMs'] is num;
      if (verified) {
        _currentServiceAccount = account;
        return {...value, 'account': account, 'verified': true};
      }
      return {
        ...value,
        'verified': false,
        'account': null,
        'reason': generation != _serviceAccountReadGeneration
            ? 'service_account_read_superseded'
            : value['reason'] ?? 'service_account_header_unconfirmed',
      };
    } catch (error) {
      if (generation == _serviceAccountReadGeneration) {
        _currentServiceAccount = null;
      }
      return {
        'verified': false,
        'account': null,
        'source': 'accessibility_account_header',
        'reason': error is PlatformException
            ? error.code
            : 'service_account_read_failed',
      };
    }
  }

  @override
  Future<bool> requestAccessibility() async =>
      await _channel.invokeMethod<bool>('requestAccessibility') ?? false;

  Future<Map<String, Object?>> prepareRunPermissions(
          String destinationDirectory) =>
      _mapCall('prepareRunPermissions',
          {'destinationDirectory': destinationDirectory});

  /// Passive: never opens system prompts or reads protected directories.
  Future<bool> runPermissionsReady() async =>
      (await _mapCall('runPermissionsStatus'))['ready'] == true;

  Future<bool> requestScreenRecording() async =>
      await _channel.invokeMethod<bool>('requestScreenRecording') ?? false;

  Future<List<OcrWindowInfo>> listOcrWindows() async {
    final value = await _channel.invokeListMethod<Object?>('listOCRWindows');
    return (value ?? const [])
        .whereType<Map<Object?, Object?>>()
        .map(OcrWindowInfo.fromMap)
        .toList(growable: false);
  }

  Future<ViewportEvidence> captureViewportEvidence(
      {String? expectedCustomer,
      required String directory,
      String? automationSessionId,
      DateTime? historyCutoff,
      Map<String, int> historyCutoffs = const {}}) async {
    final value = await _mapCall('captureViewportEvidence', {
      if (expectedCustomer != null)
        'expectedCustomer': _verifiedIdentityFor(expectedCustomer),
      if (automationSessionId != null)
        'automationSessionId': automationSessionId,
      'directory': directory,
      if (historyCutoff != null)
        'historyCutoffMs': historyCutoff.millisecondsSinceEpoch,
      'historyCutoffs': historyCutoffs,
    });
    _throwEvidenceError(value);
    return ViewportEvidence.fromMap(value);
  }

  final Map<String, Future<OcrInspection>> _evidenceInspections = {};
  Future<OcrInspection> inspectViewportEvidence(ViewportEvidence evidence,
          {bool liveRegistration = false,
          bool mediaRecognition = false,
          bool textFirst = false}) =>
      _evidenceInspections.putIfAbsent(
          textFirst ? '${evidence.id}:text_first' : evidence.id, () async {
        try {
          final value = await _mapCall('inspectViewportEvidence', {
            'manifestPath': evidence.manifestPath,
            'expectedCustomer': evidence.customer,
            'recognitionLevel': textFirst ? 'text_first' : 'accurate',
            if (liveRegistration) 'liveRegistration': true,
            if (mediaRecognition) 'mediaRecognition': true,
          });
          _throwEvidenceError(value);
          return OcrInspection.fromMap(value);
        } finally {
          _evidenceInspections
              .remove(textFirst ? '${evidence.id}:text_first' : evidence.id);
        }
      });

  Future<VisibleImagePayload> cropViewportEvidence(
      ViewportEvidence evidence, OcrVisualRegion region,
      {String? destinationDirectory,
      DateTime? expectedMediaAt,
      String? clippedMediaKind}) async {
    final value = await _mapCall('cropViewportEvidence', {
      if (clippedMediaKind != null) 'clippedMediaKind': clippedMediaKind,
      if (destinationDirectory != null)
        'destinationDirectory': destinationDirectory,
      'manifestPath': evidence.manifestPath,
      'expectedCustomer': evidence.customer,
      'x': region.x,
      'y': region.y,
      'width': region.width,
      'height': region.height,
      if (expectedMediaAt != null)
        'expectedMediaAtMs': expectedMediaAt.millisecondsSinceEpoch,
    });
    _throwEvidenceError(value);
    if (value['cacheSearch'] case final List search) {
      RuntimeTrace.record('media.cache_search', {
        'customer': evidence.customer,
        'evidenceId': evidence.id,
        'senderAt': expectedMediaAt?.toUtc().toIso8601String(),
        'attempts': search,
        'selectedButUnreadable': value['cacheSelectedButUnreadable'] == true,
      });
    }
    return VisibleImagePayload.fromMap(value);
  }

  void _throwEvidenceError(Map<String, Object?> value) {
    if (value['error'] case final String code) {
      throw PlatformException(
          code: code, message: value['message']?.toString());
    }
  }

  Future<OcrInspection> inspectOcr({
    required int windowId,
    bool fast = false,
  }) {
    final key = '$windowId:$fast';
    return _ocrInspections.putIfAbsent(key, () async {
      try {
        return await _inspectOcrOnce(windowId: windowId, fast: fast);
      } finally {
        _ocrInspections.remove(key);
      }
    });
  }

  Future<OcrInspection> _inspectOcrOnce({
    required int windowId,
    required bool fast,
  }) async {
    final value = await _mapCall('inspectOCR', <String, Object?>{
      'windowId': windowId,
      'recognitionLevel': fast ? 'fast' : 'accurate',
    });
    if (value['error'] case final String code) {
      throw PlatformException(
        code: code,
        message: value['message'] as String? ?? 'OCR inspection failed.',
      );
    }
    return OcrInspection.fromMap(value);
  }

  /// Waits until Qianniu's active header proves that a requested row switch
  /// completed. Callers must not persist OCR under the requested customer
  /// name until this independent identity check succeeds.
  Future<OcrInspection> inspectExpectedCustomer({
    required int windowId,
    required String expectedCustomer,
    int maximumAttempts = 6,
    Duration retryDelay = const Duration(milliseconds: 250),
  }) async {
    final verifiedExpected = _verifiedIdentityFor(expectedCustomer);
    OcrInspection? lastInspection;
    for (var attempt = 0; attempt < maximumAttempts; attempt++) {
      if (attempt > 0) await Future<void>.delayed(retryDelay);
      lastInspection = await inspectOcr(windowId: windowId);
      if (customerIdentitiesMatch(
          lastInspection.activeCustomerId, verifiedExpected)) {
        return lastInspection;
      }
    }
    throw PlatformException(
      code: 'customer_switch_not_verified',
      message: 'JingMai did not settle on $verifiedExpected. OCR data was '
          'discarded instead of being saved to the wrong customer file '
          '(active: ${lastInspection?.activeCustomerId ?? 'unknown'}).',
    );
  }

  static const automationEpochZoneKey = 'jd.automation.runEpoch';
  int? _automationEpoch;
  Future<void> setAutomationEpoch(int epoch, {required bool running}) async {
    _automationEpoch = epoch;
    if (!running) {
      final pending = _pendingLocalCalls.toList();
      _pendingLocalCalls.clear();
      for (final call in pending) {
        if (!call.isCompleted) {
          call.completeError(PlatformException(code: 'automation_stopped'));
        }
      }
      _ocrInspections.clear();
      _cachedMediaCaptures.clear();
      _mediaCacheRevision = null;
      _serviceAccountReadGeneration++;
    }
    await _channel.invokeMethod<Object?>(
        'setAutomationEpoch', {'epoch': epoch, 'running': running});
  }

  /// Interrupt only transfer inspection so a ready reply can acquire the UI.
  /// Native dispatch is immediate; it must not wait behind the inspected modal.
  Future<void> requestTransferInspectionYield({int? automationEpoch}) async {
    final epoch = automationEpoch ??
        Zone.current[automationEpochZoneKey] ??
        _automationEpoch;
    await _channel.invokeMethod<Object?>('requestTransferInspectionYield',
        <String, Object?>{if (epoch != null) 'automationEpoch': epoch});
  }

  Future<void> checkDeliveryReadiness(String customer) async {
    final value = await _mapCall('checkDeliveryReadiness',
        {'expectedCustomer': _verifiedIdentityFor(customer)});
    if (value['ready'] != true) {
      throw PlatformException(
          code: value['error']?.toString() ?? 'delivery_readiness_unconfirmed',
          message: value['message']?.toString() ??
              'Native delivery readiness was not confirmed.');
    }
  }

  Future<Map<String, Object?>> readReceptionOwnership(String customer) async {
    final expected = _verifiedIdentityFor(customer);
    final proof = await _mapCall('checkDeliveryReadiness',
        {'expectedCustomer': expected, 'requireCurrentOwnership': true});
    if (proof['ready'] != true ||
        proof['ownershipConfirmed'] != true ||
        proof['ownershipProof'] != 'current_enabled_empty_reception_ax' ||
        proof['currentCustomer'] != expected ||
        proof['activeCustomerId'] != expected ||
        proof['sourceAccount'] is! String ||
        (proof['sourceAccount']! as String).trim().isEmpty ||
        proof['sourceAccount'] == '当前客服账号' ||
        proof['observedAtMs'] is! num) {
      throw PlatformException(
          code: proof['error']?.toString() ?? 'reception_ownership_unconfirmed',
          message:
              'Current reception ownership requires positive native AX evidence.',
          details: proof);
    }
    return proof;
  }

  Future<Map<String, Object?>> sendDraftOnce({
    required String expectedCustomer,
    required String reply,
    List<String> mediaPaths = const [],
    String? attemptId,
    String? receiptPath,
    int? mediaRevision,
    String? mediaGuardPath,
    bool requireRedClock = false,
    DateTime? preClickDeadline,
    DateTime? holdingClickNotBefore,
  }) async {
    if (isProvisionalIdentity(expectedCustomer)) {
      throw PlatformException(
          code: 'unbound_customer',
          message: 'A row reference is not a confirmed customer identity.');
    }
    final value = await _mapCall('sendDraftOnce', <String, Object?>{
      'expectedCustomer': _verifiedIdentityFor(expectedCustomer),
      'reply': reply,
      'mediaPaths': mediaPaths,
      if (requireRedClock) 'requireRedClock': true,
      if (attemptId != null) 'attemptId': attemptId,
      if (receiptPath != null) 'receiptPath': receiptPath,
      if (mediaRevision != null) 'mediaRevision': mediaRevision,
      if (mediaGuardPath != null) 'mediaGuardPath': mediaGuardPath,
      if (preClickDeadline != null)
        'preClickDeadlineMs': preClickDeadline.millisecondsSinceEpoch,
      if (holdingClickNotBefore != null)
        'holdingClickNotBeforeMs': holdingClickNotBefore.millisecondsSinceEpoch,
    });
    if (value['error'] case final String code) {
      throw PlatformException(
          code: code,
          message: value['message'] as String? ?? 'Send failed.',
          details: {
            for (final key in [
              'sendStage',
              'sendStartedAtMs',
              'sendClickedAtMs',
              'stageElapsedMs',
              'clickDispatched',
              'composerRecovery',
              'foregroundPid',
              'foregroundBundleId',
              'activationAttempts',
              'axRefreshAttempts',
              'reusedOwnInsertion',
              'queueWaitMs',
              'preClickDeadlineMs',
              'preClickBudgetRemainingMs',
              'fullSnapshotReads',
              'lightSnapshotReads',
              'confirmationAXValueFailures',
              'postClickComposerPreserved',
              'composerStillMatchesReply',
              'rejectedFingerprint',
              'expectedCustomer',
              'activeCustomerId',
              'identitySource'
            ])
              if (value[key] != null) key: value[key]
          });
    }
    if (value['sent'] == true) {
      for (final key in ['customer', 'activeCustomerId']) {
        if (value[key] != null &&
            !customerIdentitiesMatch(
                value[key]?.toString(), expectedCustomer)) {
          throw PlatformException(
              code: 'send_unconfirmed',
              message:
                  'Native send identity conflicted with the frozen customer.',
              details: {
                'expectedCustomer': expectedCustomer,
                'activeCustomerId': value[key],
                'identitySource': 'native_result_conflict'
              });
        }
      }
    }
    return value;
  }

  Future<bool> requestHoldingSendYield(
      {required String expectedCustomer, required String attemptId}) async {
    if (isProvisionalIdentity(expectedCustomer)) return false;
    final result = await _mapCall('requestHoldingSendYield', {
      'expectedCustomer': expectedCustomer,
      'attemptId': attemptId,
    });
    return result['yieldRequested'] == true;
  }

  /// Retry only an existing failed bubble. This never types text or clicks Send.
  Future<Map<String, Object?>> retryFailedOutgoingMessage({
    required String expectedCustomer,
    required Map<String, Object?> candidate,
  }) async {
    final value =
        await _mapCall('retryFailedOutgoingMessage', <String, Object?>{
      'expectedCustomer': _verifiedIdentityFor(expectedCustomer),
      'candidate': candidate,
    });
    if (value['error'] case final String code) {
      throw PlatformException(code: code, message: value['message'] as String?);
    }
    return value;
  }

  Future<VisibleImagePayload> captureImageRegion({
    required String expectedCustomer,
    required int windowId,
    required double x,
    required double y,
    required double width,
    required double height,
    DateTime? expectedMediaAt,
    bool allowActivationForVideoDetection = false,
  }) async {
    final value = await _mapCall('captureImageRegion', <String, Object?>{
      'expectedCustomer': _verifiedIdentityFor(expectedCustomer),
      'windowId': windowId,
      'x': x,
      'y': y,
      'width': width,
      'height': height,
      if (expectedMediaAt != null)
        'expectedMediaAtMs': expectedMediaAt.millisecondsSinceEpoch,
      'allowActivationForVideoDetection': allowActivationForVideoDetection,
    });
    if (value['error'] case final String code) {
      throw PlatformException(
          code: code,
          message:
              value['message'] as String? ?? 'Image-region capture failed.');
    }
    return VisibleImagePayload.fromMap(value);
  }

  /// Metadata-only progress. A change may wake pending acquisition workers;
  /// it does not identify a customer or authorize a new business message.
  Future<String?> recentMediaCacheRevision() {
    final running = _mediaCacheRevision;
    if (running != null) return running;
    final future = _mapCall('recentMediaCacheRevision')
        .then((value) => value['revision']?.toString());
    _mediaCacheRevision = future;
    unawaited(future.then<void>((_) {
      if (identical(_mediaCacheRevision, future)) _mediaCacheRevision = null;
    }, onError: (Object _, StackTrace __) {
      if (identical(_mediaCacheRevision, future)) _mediaCacheRevision = null;
    }));
    return future;
  }

  /// Looks for one uniquely timed image or video in JD's local cache after an
  /// unread turn was detected. Native code re-verifies the active customer;
  /// the caller must additionally reject cross-customer clock ambiguity.
  Future<CachedMediaPayload?> captureRecentCachedMedia({
    required String expectedCustomer,
    required DateTime expectedMediaAt,
    required String destinationDirectory,
  }) {
    final verifiedCustomer = _verifiedIdentityFor(expectedCustomer);
    final key = (
      verifiedCustomer,
      expectedMediaAt.millisecondsSinceEpoch,
      destinationDirectory
    );
    // Caller timeout does not cancel the native cache scan/copy. Share only
    // that exact in-flight operation, never a completed cache-selection result.
    return _cachedMediaCaptures.putIfAbsent(key, () async {
      try {
        return await _captureRecentCachedMediaOnce(
            verifiedCustomer: verifiedCustomer,
            expectedMediaAt: expectedMediaAt,
            destinationDirectory: destinationDirectory);
      } finally {
        _cachedMediaCaptures.remove(key);
      }
    });
  }

  Future<CachedMediaPayload?> _captureRecentCachedMediaOnce({
    required String verifiedCustomer,
    required DateTime expectedMediaAt,
    required String destinationDirectory,
  }) async {
    final value = await _mapCall('captureRecentCachedMedia', <String, Object?>{
      'expectedCustomer': verifiedCustomer,
      'expectedMediaAtMs': expectedMediaAt.millisecondsSinceEpoch,
      'destinationDirectory': destinationDirectory,
    });
    final kind = value['kind']?.toString();
    if (kind != 'image' && kind != 'video') return null;
    return CachedMediaPayload(
      kind: kind!,
      cacheKey: value['cacheKey']?.toString() ?? '',
      cacheModifiedAt: DateTime.fromMillisecondsSinceEpoch(
        (value['cacheModifiedAtMs'] as num?)?.toInt() ?? 0,
      ),
      image: kind == 'image' ? VisibleImagePayload.fromMap(value) : null,
      video: kind == 'video' ? DownloadedVideoPayload.fromMap(value) : null,
    );
  }

  Future<MessageClassification> classifyMessageAt({
    required String expectedCustomer,
    required int windowId,
    required double x,
    required double y,
  }) async {
    final value = await _mapCall('classifyMessageAt', <String, Object?>{
      'expectedCustomer': _verifiedIdentityFor(expectedCustomer),
      'windowId': windowId,
      'x': x,
      'y': y,
    });
    return MessageClassification(
      kind: value['kind']?.toString() ?? 'unknown',
      visualFingerprint: value['visualFingerprint']?.toString(),
      image: value['kind']?.toString() == 'image'
          ? VisibleImagePayload.fromMap(value)
          : null,
    );
  }

  Future<VisibleImagePayload> downloadImageAt({
    required String expectedCustomer,
    required int windowId,
    required double x,
    required double y,
  }) async {
    final value = await _mapCall('downloadImageAt', <String, Object?>{
      'expectedCustomer': _verifiedIdentityFor(expectedCustomer),
      'windowId': windowId,
      'x': x,
      'y': y,
    });
    if (value['error'] case final String code) {
      throw PlatformException(
          code: code,
          message: value['message'] as String? ??
              'The original JD image could not be downloaded.');
    }
    return VisibleImagePayload.fromMap(value);
  }

  /// Coordinates are valid only for these fresh, immutable transcript pixels.
  /// This is a low-priority acquisition operation, never a delivery preflight.
  Future<ImageOriginalAcquisitionResult> acquireImageOriginal({
    required ViewportEvidence evidence,
    required OcrVisualRegion region,
    required String customer,
    required String messageId,
    required DateTime senderAt,
    required String receiptId,
    required int automationEpoch,
  }) async {
    final value = await _imageOriginalMapCall('acquireImageOriginal', {
      'manifestPath': evidence.manifestPath,
      'evidenceId': evidence.id,
      'expectedCustomer': _verifiedIdentityFor(customer),
      'messageId': messageId,
      'messageTimeKey': CustomerMessageTime.incomingId(
          _verifiedIdentityFor(customer), senderAt),
      'senderAtMs': senderAt.millisecondsSinceEpoch,
      'receiptId': receiptId,
      'automationEpoch': automationEpoch,
      'x': region.x,
      'y': region.y,
      'width': region.width,
      'height': region.height,
    });
    return _imageOriginalResult(value,
        customer: customer,
        messageId: messageId,
        senderAt: senderAt,
        receiptId: receiptId,
        automationEpoch: automationEpoch);
  }

  /// Copies a message image through its owned context menu. Image decoding
  /// and cache comparison are deferred to background polling.
  Future<ImageOriginalAcquisitionResult> copyImageFromMessageContext({
    required ViewportEvidence evidence,
    required Map<String, Object?> target,
    required String customer,
    required String messageId,
    required DateTime senderAt,
    required String receiptId,
    required int automationEpoch,
    bool knownImage = false,
  }) async {
    final value = await _imageOriginalMapCall('copyImageFromMessageContext', {
      'manifestPath': evidence.manifestPath,
      'evidenceId': evidence.id,
      'expectedCustomer': _verifiedIdentityFor(customer),
      'messageId': messageId,
      'messageTimeKey': CustomerMessageTime.incomingId(
          _verifiedIdentityFor(customer), senderAt),
      'senderAtMs': senderAt.millisecondsSinceEpoch,
      'receiptId': receiptId,
      'automationEpoch': automationEpoch,
      'target': target,
      'knownImage': knownImage,
    });
    return _imageOriginalResult(value,
        customer: customer,
        messageId: messageId,
        senderAt: senderAt,
        receiptId: receiptId,
        automationEpoch: automationEpoch);
  }

  /// Reads a triggered download or captured context-copy image. Native polling
  /// performs no AX reads, clicks, keyboard actions or modal cleanup.
  Future<ImageOriginalAcquisitionResult> pollImageOriginal({
    required String token,
    required String customer,
    required String messageId,
    required DateTime senderAt,
    required String receiptId,
    required int automationEpoch,
  }) async {
    final value = await _imageOriginalMapCall('pollImageOriginal', {
      'token': token,
      'expectedCustomer': _verifiedIdentityFor(customer),
      'messageId': messageId,
      'messageTimeKey': CustomerMessageTime.incomingId(
          _verifiedIdentityFor(customer), senderAt),
      'senderAtMs': senderAt.millisecondsSinceEpoch,
      'receiptId': receiptId,
      'automationEpoch': automationEpoch,
    });
    return _imageOriginalResult(value,
        customer: customer,
        messageId: messageId,
        senderAt: senderAt,
        receiptId: receiptId,
        automationEpoch: automationEpoch);
  }

  Future<bool> requestImageAcquisitionYield(
      {required int automationEpoch}) async {
    final value = await _channel.invokeMapMethod<String, Object?>(
        'requestImageAcquisitionYield', {'automationEpoch': automationEpoch});
    return value?['interrupted'] == true;
  }

  /// Wait for cleanup of this run's exact owned viewer before another image
  /// task navigates. Never replace the explicit epoch with a Zone/newer run.
  Future<bool> releaseImageAcquisitionViewer(
      {required int automationEpoch}) async {
    final value = await _channel.invokeMapMethod<String, Object?>(
        'requestImageAcquisitionYield',
        {'automationEpoch': automationEpoch, 'awaitRelease': true});
    return value?['viewerReleased'] == true;
  }

  // A newer run/Zone must not replace the explicit epoch which owns the
  // frozen message and its possible physical click.
  Future<Map<String, Object?>> _imageOriginalMapCall(
      String method, Map<String, Object?> arguments) {
    return RuntimeTrace.measure('native.$method', () async {
      final value =
          await _channel.invokeMapMethod<Object?, Object?>(method, arguments);
      return (value ?? const {}).map((key, value) => MapEntry('$key', value));
    },
        fields: {
          'customer': arguments['expectedCustomer'],
          'messageId': arguments['messageId'],
          'receiptId': arguments['receiptId'],
          'automationEpoch': arguments['automationEpoch'],
        },
        describe: (value) => {
              for (final key in [
                'state',
                'reason',
                'token',
                'captureSource',
                'imageConfirmed',
                'copyPoint',
                'copyMenuTitle',
                'cacheMatched',
              ])
                if (value[key] != null) key: value[key],
            });
  }

  ImageOriginalAcquisitionResult _imageOriginalResult(
      Map<String, Object?> value,
      {required String customer,
      required String messageId,
      required DateTime senderAt,
      required String receiptId,
      required int automationEpoch}) {
    if (value['customer'] != _verifiedIdentityFor(customer) ||
        value['messageId'] != messageId ||
        value['messageTimeKey'] !=
            CustomerMessageTime.incomingId(
                _verifiedIdentityFor(customer), senderAt) ||
        value['receiptId'] != receiptId ||
        value['senderAtMs'] != senderAt.millisecondsSinceEpoch ||
        value['automationEpoch'] != automationEpoch) {
      throw PlatformException(
          code: 'image_original_proof_mismatch',
          message: 'Original-image result did not belong to this message.');
    }
    final ready = value['state'] == 'ready';
    final image = ready ? VisibleImagePayload.fromMap(value) : null;
    if (ready &&
        (value['contentComplete'] != true ||
            image?.kind != 'image' ||
            image?.bytes?.isNotEmpty != true ||
            (value['pixelWidth'] as num? ?? 0) <= 0 ||
            (value['pixelHeight'] as num? ?? 0) <= 0)) {
      throw PlatformException(
          code: 'image_original_incomplete',
          message: 'Native acquisition did not return a complete image.');
    }
    return ImageOriginalAcquisitionResult(
      state: value['state']?.toString() ?? 'pending',
      token: value['token']?.toString(),
      reason: value['reason']?.toString(),
      imageConfirmed: value['imageConfirmed'] == true,
      image: image,
      customer: value['customer']! as String,
      messageId: messageId,
      receiptId: receiptId,
      senderAt: senderAt,
      automationEpoch: automationEpoch,
    );
  }

  Future<DownloadedVideoPayload> downloadVideoAt({
    required String expectedCustomer,
    required int windowId,
    required double x,
    required double y,
    required double width,
    required double height,
    required String destinationDirectory,
  }) async {
    final value = await _mapCall('downloadVideoAt', <String, Object?>{
      'expectedCustomer': _verifiedIdentityFor(expectedCustomer),
      'windowId': windowId,
      'x': x,
      'y': y,
      'width': width,
      'height': height,
      'destinationDirectory': destinationDirectory,
    });
    if (value['error'] case final String code) {
      throw PlatformException(
        code: code,
        message: value['message'] as String? ??
            'The original JD video could not be downloaded.',
      );
    }
    return DownloadedVideoPayload.fromMap(value);
  }

  Future<SpeechTranscription> transcribeAudio(String path) async {
    final value = await _mapCall('transcribeAudio', <String, Object?>{
      'path': path,
    });
    if (value['error'] case final String code) {
      throw PlatformException(
        code: code,
        message: value['message'] as String? ??
            'The video audio could not be transcribed.',
      );
    }
    return SpeechTranscription.fromMap(value);
  }

  Future<List<OcrObservation>> refineEvidenceText(
      {required String manifestPath,
      required String expectedCustomer,
      required OcrVisualRegion region}) async {
    final result = await _mapCall('refineEvidenceText', {
      'manifestPath': manifestPath,
      'expectedCustomer': expectedCustomer,
      'x': region.x,
      'y': region.y,
      'width': region.width,
      'height': region.height
    });
    if (result['busy'] == true) {
      throw PlatformException(code: 'text_refinement_busy');
    }
    if (result['error'] is String) {
      throw PlatformException(
          code: result['error']! as String,
          message: result['message'] as String?);
    }
    return (result['observations'] as List? ?? const [])
        .whereType<Map>()
        .map((x) => OcrObservation.fromMap(x.cast<Object?, Object?>()))
        .toList();
  }

  Future<List<String>> listConversations() async {
    final value = await _channel.invokeListMethod<Object?>('listConversations');
    return (value ?? const [])
        .map((item) => item.toString())
        .toList(growable: false);
  }

  Future<List<QianniuConversationRow>>? _conversationRows;
  Future<List<QianniuConversationRow>> listConversationRows() =>
      _conversationRows ??= _listConversationRowsOnce()
          .whenComplete(() => _conversationRows = null);

  Future<List<QianniuConversationRow>> _listConversationRowsOnce() async {
    final value = await RuntimeTrace.measure('native.listConversationRows',
        () => _channel.invokeListMethod<Object?>('listConversationRows'),
        describe: (rows) => {
              'rows': rows?.length ?? 0,
              'customers': (rows ?? [])
                  .whereType<Map>()
                  .map((r) => {
                        'customer': r['customer'],
                        'unread': r['unread'],
                        'identitySource': r['identitySource'],
                        'rowKey': r['rowKey'],
                        'rowIndex': r['rowIndex'],
                        'unreadAgeSeconds': r['unreadAgeSeconds'],
                        'redClockPresent': r['redClockPresent'],
                        'signalObservedAtMs': r['signalObservedAtMs'],
                        'unreadBadgeText': r['unreadBadgeText'],
                        'unreadBadgeConfidence': r['unreadBadgeConfidence'],
                        'unreadEvidence': r['unreadEvidence']
                      })
                  .toList()
            });
    final rows = (value ?? const [])
        .whereType<Map<Object?, Object?>>()
        .map(QianniuConversationRow.fromMap)
        .toList(growable: false);
    for (final row in rows) {
      if (row.rowKey != null) {
        _rowResolution.observe('$provisionalPrefix${row.rowKey}', row.unread);
      }
      if (row.rowKey != null && row.rowToken != null) {
        final reference = (key: row.rowKey!, token: row.rowToken!);
        _rowReferences[row.customer] = reference;
        if (row.identitySource == 'active_ax') {
          _rememberVerifiedIdentity(
              '$provisionalPrefix${row.rowKey}', row.customer);
        }
      }
    }
    final visibleNames = rows.map((row) => _identityKey(row.customer)).toSet();
    return rows.map((row) {
      final verified = _verifiedIdentityFor(row.customer);
      // Only reuse a previously AX-confirmed alias. Two separately visible
      // names must remain independent instead of being merged by similarity.
      if (verified == row.customer ||
          visibleNames.contains(_identityKey(verified))) {
        return row;
      }
      if (row.rowKey != null && row.rowToken != null) {
        _rowReferences[verified] = (key: row.rowKey!, token: row.rowToken!);
      }
      return QianniuConversationRow(
          customer: verified,
          unread: row.unread,
          unreadEvidence: row.unreadEvidence,
          evidenceAvailable: row.evidenceAvailable,
          unreadAgeSeconds: row.unreadAgeSeconds,
          redClockPresent: row.redClockPresent,
          signalObservedAt: row.signalObservedAt,
          unreadBadgeText: row.unreadBadgeText,
          unreadBadgeConfidence: row.unreadBadgeConfidence,
          identitySource: 'verified_alias',
          rowKey: row.rowKey,
          rowToken: row.rowToken);
    }).toList(growable: false);
  }

  Future<Map<String, Object?>> ensureReceptionWindow(
      {bool allowActivation = true}) async {
    final value = await _mapCall('ensureReceptionWindow', <String, Object?>{
      'allowActivation': allowActivation,
    });
    if (value['error'] case final String code) {
      throw PlatformException(
          code: code,
          message: value['message'] as String? ??
              'Could not open the JD 咚咚 customer-service window.');
    }
    return value;
  }

  Future<void> openConversation(String expectedCustomer,
      {bool allowActivation = true,
      Duration? maxOpenDuration,
      ConversationOpenPurpose purpose =
          ConversationOpenPurpose.delivery}) async {
    final known = _verifiedIdentityFor(expectedCustomer);
    if (isProvisionalIdentity(expectedCustomer) && known != expectedCustomer) {
      await openConversation(known,
          allowActivation: allowActivation,
          maxOpenDuration: maxOpenDuration,
          purpose: purpose);
      return;
    }
    if (purpose == ConversationOpenPurpose.transfer &&
        isProvisionalIdentity(known)) {
      throw PlatformException(code: 'conversation_open_pending', details: {
        'openState': 'pending',
        'pendingReason': 'canonical_identity_required',
        'expectedCustomer': expectedCustomer,
        'transferClicked': false,
      });
    }
    final reference = _rowReferences[expectedCustomer] ?? _rowReferences[known];
    if (isProvisionalIdentity(expectedCustomer) && reference != null) {
      final expected = isProvisionalIdentity(expectedCustomer) ? null : known;
      final key = '${reference.key}:${expected ?? "discover"}';
      if (!_openingRows.containsKey(key) &&
          !rowResolutionDue(expectedCustomer)) {
        throw PlatformException(
            code: 'row_resolution_deferred',
            message: 'Waiting for new row evidence or retry budget.');
      }
      await (_openingRows[key] ??= (() async {
        try {
          await _openRow(reference, expectedCustomer,
              expected: expected, allowActivation: allowActivation);
          _rowResolution.resolved(expectedCustomer);
        } on PlatformException catch (error) {
          if (!const {'qianniu_not_frontmost', 'composer_not_empty'}
              .contains(error.code)) {
            _rowResolution.failed(expectedCustomer);
            RuntimeTrace.record('identity.row_resolution_failed', {
              'observedRow': expectedCustomer,
              'errorCode': error.code,
              'attempts': _rowResolution.failures(expectedCustomer),
              'suspended': _rowResolution.suspended(expectedCustomer),
              'retryAt': _rowResolution
                  .retryAt(expectedCustomer)
                  ?.toUtc()
                  .toIso8601String(),
              'evidenceRetained': true,
            });
          }
          rethrow;
        }
      })()
          .whenComplete(() {
        _openingRows.remove(key);
      }));
      return;
    }
    if (isProvisionalIdentity(expectedCustomer)) {
      throw PlatformException(
          code: 'row_reference_expired',
          message: 'The row must be rediscovered before opening it.');
    }
    final nativeExpected = _verifiedIdentityFor(expectedCustomer);
    final value = await _mapCall('openConversation', <String, Object?>{
      'expectedCustomer': nativeExpected,
      'allowActivation': allowActivation,
      if (purpose == ConversationOpenPurpose.delivery)
        'timeoutMs': maxOpenDuration?.inMilliseconds ?? 4000,
      if (purpose == ConversationOpenPurpose.transfer) ...{
        'purpose': 'transfer',
        if (reference != null) 'rowToken': reference.token,
        if (reference != null) 'rowKey': reference.key,
      },
    });
    if (purpose == ConversationOpenPurpose.transfer &&
        value['transferClicked'] == true) {
      throw PlatformException(code: 'transfer_unconfirmed', details: value);
    }
    if (purpose == ConversationOpenPurpose.transfer &&
        (value['openState'] == 'pending' ||
            value['error'] == 'conversation_open_pending')) {
      throw PlatformException(
          code: 'conversation_open_pending',
          message: value['message']?.toString(),
          details: {
            ...value,
            'expectedCustomer': nativeExpected,
            'transferClicked': false,
          });
    }
    if (value['error'] case final String code) {
      throw PlatformException(
          code: code,
          message:
              value['message'] as String? ?? 'Could not open conversation.',
          details: {
            if (purpose == ConversationOpenPurpose.transfer) ...value,
            'openStage': value['openStage'],
            'queueWaitMs': value['queueWaitMs'],
            'expectedCustomer': nativeExpected,
            'activeCustomerId': value['activeCustomerId'],
            'identitySource': value['identitySource']
          });
    }
    final actual =
        (value['activeCustomerId'] ?? value['customer'])?.toString().trim();
    if (value['opened'] != true ||
        !customerIdentitiesMatch(actual, nativeExpected) ||
        (value['customer'] != null &&
            !customerIdentitiesMatch(
                value['customer']?.toString(), nativeExpected))) {
      RuntimeTrace.record('identity.open_rejected', {
        'expectedCustomer': nativeExpected,
        'activeCustomerId': actual,
        'opened': value['opened'],
        'method': value['method']
      });
      throw PlatformException(code: 'customer_identity_mismatch', details: {
        'expectedCustomer': nativeExpected,
        'activeCustomerId': actual
      });
    }
    if (purpose == ConversationOpenPurpose.transfer &&
        (value['focusVerified'] != true ||
            !const {'exact_active_ax', 'selected_row_and_stable_ax_header'}
                .contains(value['identityProof']))) {
      throw PlatformException(
          code: 'conversation_open_pending',
          message: 'Customer identity or reception focus is not yet confirmed.',
          details: {
            ...value,
            'openState': 'pending',
            'pendingReason': 'final_open_proof_incomplete',
            'expectedCustomer': nativeExpected,
            'transferClicked': false,
          });
    }
    _rememberVerifiedIdentity(expectedCustomer, actual);
    RuntimeTrace.record('identity.open_verified', {
      'customer': nativeExpected,
      'activeCustomerId': actual,
      'identitySource': value['identitySource'] ?? 'native_ax',
      'proof': value['identityProof'] ?? 'exact_active_ax'
    });
  }

  Future<void> _openRow(
      ({String key, String token}) reference, String requested,
      {required String? expected, required bool allowActivation}) async {
    final value = await _mapCall('openConversationRow', {
      'rowToken': reference.token,
      'expectedCustomer': expected,
      'allowActivation': allowActivation,
      'timeoutMs': 2500,
    });
    if (value['error'] case final String code) {
      throw PlatformException(
          code: code,
          message: value['message']?.toString(),
          details: {
            'openStage': value['openStage'],
            'rowKey': reference.key,
            'selectionEvidence': value['selectionEvidence']
          });
    }
    final actual = value['customer']?.toString().trim() ?? '';
    final proof = value['identityProof'];
    final proofValid = proof == 'selected_row_and_stable_ax_header' ||
        (expected != null && proof == 'exact_active_ax');
    if (value['opened'] != true ||
        actual.isEmpty ||
        isProvisionalIdentity(actual) ||
        !proofValid ||
        value['rowKey'] != reference.key ||
        (expected != null && !customerIdentitiesMatch(actual, expected))) {
      throw PlatformException(
          code: 'row_identity_unconfirmed',
          message:
              'The selected row and canonical AX identity were not confirmed.');
    }
    _rememberVerifiedIdentity(requested, actual);
    _rememberVerifiedIdentity('$provisionalPrefix${reference.key}', actual);
    _rowReferences[actual] = reference;
    RuntimeTrace.record('identity.row_bound', {
      'rowKey': reference.key,
      'customer': actual,
      'proof': proof,
      'method': value['method'],
      'elapsedMs': value['elapsedMs'],
      'selectionEvidence': value['selectionEvidence'],
    });
  }

  /// Opens JD's transfer dialog and returns the current service account plus
  /// only visible sub-accounts whose status badge is independently confirmed
  /// green by the native adapter. The dialog remains open so
  /// [transferConversation] can revalidate the automatically selected account.
  Future<TransferAccountPreview> listActiveTransferAccounts(
      String expectedCustomer) async {
    final value = await _mapCall(
      'listActiveTransferAccounts',
      <String, Object?>{
        'expectedCustomer': _verifiedIdentityFor(expectedCustomer),
      },
    );
    if (value['error'] case final String code) {
      throw PlatformException(
        code: code,
        message: value['message'] as String? ??
            'Could not inspect active JD transfer accounts.',
        details: {
          'inspectionStage': value['inspectionStage'],
          'inspectionElapsedMs': value['inspectionElapsedMs'],
          'transferClicked': value['transferClicked'],
          'identitySource': value['identitySource'],
          'axDiagnostics': value['axDiagnostics'],
          for (final key in [
            'stageElapsedMs',
            'ocrRecognitionCount',
            'axProbeCount',
            'groupLabelReuseCount',
            'statusSampleCount'
          ])
            if (value[key] != null) key: value[key],
        },
      );
    }
    final accounts = (value['accounts'] as List<Object?>? ?? const [])
        .map((account) => account.toString())
        .where((account) => account.trim().isNotEmpty)
        .toList(growable: false);
    RuntimeTrace.record('handoff.accounts_inspected', {
      'customer': expectedCustomer,
      'activeCount': accounts.length,
      'identitySource': value['identitySource'],
      'axDiagnostics': value['axDiagnostics'],
      'stage': value['inspectionStage'],
      'elapsedMs': value['inspectionElapsedMs'],
      'transferClicked': false,
      for (final key in [
        'stageElapsedMs',
        'ocrRecognitionCount',
        'axProbeCount',
        'groupLabelReuseCount',
        'statusSampleCount'
      ])
        if (value[key] != null) key: value[key],
    });
    return TransferAccountPreview(
      sourceAccount:
          (value['sourceAccount'] as String?)?.trim().isNotEmpty == true
              ? (value['sourceAccount'] as String).trim()
              : '当前客服账号',
      activeAccounts: accounts,
    );
  }

  /// Selects the already-previewed green account, reveals its row actions,
  /// clicks that row's explicit 转接 control, and verifies that the transfer
  /// dialog closes. Native code never clicks 备注原因 or an inactive row.
  Future<Map<String, Object?>> transferConversation({
    required String expectedCustomer,
    required String targetAccount,
    String? attemptId,
    String? receiptPath,
  }) async {
    if ((attemptId == null) != (receiptPath == null)) {
      throw ArgumentError(
          'Transfer attempt and journal must be supplied together');
    }
    final value = await _mapCall('transferConversation', <String, Object?>{
      'expectedCustomer': _verifiedIdentityFor(expectedCustomer),
      'targetAccount': targetAccount,
      if (attemptId != null) 'attemptId': attemptId,
      if (receiptPath != null) 'receiptPath': receiptPath,
    });
    RuntimeTrace.record('handoff.native_outcome', {
      'customer': expectedCustomer,
      'target': targetAccount,
      'stage': value['stage'],
      'elapsedMs': value['elapsedMs'],
      'transferClicked': value['transferClicked'],
      'transferred': value['transferred'],
      'attemptId': value['attemptId'],
      'receiptState': value['receiptState'],
      'receiptPersisted': value['receiptPersisted'],
      'targetIdentitySource': value['targetIdentitySource'],
      'actionSource': value['actionSource'],
      'axDiagnostics': value['axDiagnostics'],
      'errorCode': value['error']
    });
    if (value['error'] case final String code) {
      throw PlatformException(
        code: code,
        message: value['message'] as String? ?? 'JD chat transfer failed.',
        details: {
          'transferClicked': value['transferClicked'],
          'attemptId': value['attemptId'],
          'receiptState': value['receiptState'],
          'receiptPersisted': value['receiptPersisted'],
          'stage': value['stage'],
          'elapsedMs': value['elapsedMs'],
          'axDiagnostics': value['axDiagnostics'],
        },
      );
    }
    return value;
  }

  Future<void> cancelTransferSelection() async {
    final value = await _mapCall('cancelTransferSelection');
    if (value['error'] case final String code) {
      throw PlatformException(
        code: code,
        message: value['message'] as String? ??
            'Could not close the JD transfer dialog.',
      );
    }
  }

  Future<void> scrollConversation(
      {required String expectedCustomer,
      required int deltaY,
      bool waitForViewport = false,
      int? viewportSteps}) async {
    final value = await _mapCall('scrollConversation', <String, Object?>{
      'expectedCustomer': _verifiedIdentityFor(expectedCustomer),
      'deltaY': deltaY,
      if (waitForViewport) 'waitForViewport': true,
      if (viewportSteps != null) 'viewportSteps': viewportSteps,
    });
    if (waitForViewport && value['viewportSettle'] is String) {
      RuntimeTrace.record('evidence.history_scroll_settled', {
        'customer': expectedCustomer,
        'deltaY': value['deltaY'] ?? deltaY,
        'state': value['viewportSettle'],
        'elapsedMs': value['settleElapsedMs'],
      });
    }
    if (value['error'] case final String code) {
      throw PlatformException(
          code: code,
          message: value['message'] as String? ?? 'Could not scroll chat.');
    }
  }

  @override
  Future<void> start() => _channel.invokeMethod<void>('startCapture');

  @override
  Future<void> stop() => _channel.invokeMethod<void>('stopCapture');

  @override
  Future<Map<String, Object?>> inspectTree({int maxDepth = 12}) =>
      _mapCall('inspectTree', <String, Object?>{'maxDepth': maxDepth});

  Future<Map<Object?, Object?>?> _awaitNativeResult(
      String method, Future<Map<Object?, Object?>?> pending) async {
    if (const {
      'sendDraftOnce',
      'transferConversation',
      'retryFailedOutgoingMessage'
    }.contains(method)) {
      return pending;
    }
    final result = Completer<Map<Object?, Object?>?>();
    _pendingLocalCalls.add(result);
    pending.then((value) {
      if (!result.isCompleted) result.complete(value);
    }, onError: (Object error, StackTrace stack) {
      if (!result.isCompleted) result.completeError(error, stack);
    });
    try {
      return await result.future;
    } finally {
      _pendingLocalCalls.remove(result);
    }
  }

  Future<Map<String, Object?>> _mapCall(String method, [Object? arguments]) {
    final args = arguments is Map ? arguments : const {};
    return RuntimeTrace.measure('native.$method', () async {
      final pending = _channel.invokeMapMethod<Object?, Object?>(
          method,
          arguments is Map
              ? {
                  ...arguments,
                  if (_automationEpoch != null)
                    'automationEpoch':
                        Zone.current[automationEpochZoneKey] ?? _automationEpoch
                }
              : arguments);
      // Physical send/transfer outcomes still own their native receipt. Stop
      // cancels their actions natively, but never discards an already-clicked
      // confirmation while releasing obsolete read/OCR awaiters immediately.
      final value = await _awaitNativeResult(method, pending);
      return (value ?? const {}).map((key, value) => MapEntry('$key', value));
    },
        fields: {
          if (args['expectedCustomer'] != null)
            'customer': args['expectedCustomer'],
          if (args['windowId'] != null) 'windowId': args['windowId'],
          if (args['purpose'] != null) 'purpose': args['purpose'],
          if (args['recognitionLevel'] != null)
            'level': args['recognitionLevel'],
        },
        describe: (value) => {
              for (final key in [
                'ready',
                'accessibility',
                'screenRecording',
                'speechRecognition',
                'cacheReadable',
                'storageWritable',
                'missing',
                'error',
                'message',
                'reusedOwnInsertion',
                'activationAttempts',
                'axRefreshAttempts',
                'sendStage',
                'sendStartedAtMs',
                'sendClickedAtMs',
                'stageElapsedMs',
                'composerRecovery',
                'clickDispatched',
                'foregroundPid',
                'foregroundBundleId',
                'activeCustomerId',
                'customer',
                'method',
                'opened',
                'sent',
                'verified',
                'openStage',
                'openState',
                'pendingReason',
                'focusVerified',
                'clickDispatchedThisStep',
                'openPhaseMs',
                'queueWaitMs',
                'rowReferenceFallback',
                'rowEvidence',
                'clickDispatched',
                'snapshots',
                'selectionEvidence',
                'inspectionStage',
                'inspectionElapsedMs',
                'transferClicked',
                'kind',
                'captureSource',
                'ready',
                'confirmation',
                'rejectedFingerprint',
                'reason'
              ])
                if (value[key] != null) key: value[key],
              if (value['observations'] is List)
                'regions': (value['observations'] as List).length,
            });
  }
}

class MessageClassification {
  const MessageClassification({
    required this.kind,
    this.visualFingerprint,
    this.image,
  });

  final String kind;
  final String? visualFingerprint;
  final VisibleImagePayload? image;
}

class OcrWindowInfo {
  const OcrWindowInfo({
    this.windowId = 0,
    required this.title,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  factory OcrWindowInfo.fromMap(Map<Object?, Object?> value) => OcrWindowInfo(
        windowId: (value['windowId'] as num).toInt(),
        title: value['title'] as String? ?? 'Untitled JD window',
        x: (value['x'] as num?)?.toDouble() ?? 0,
        y: (value['y'] as num?)?.toDouble() ?? 0,
        width: (value['width'] as num?)?.toDouble() ?? 0,
        height: (value['height'] as num?)?.toDouble() ?? 0,
      );

  final int windowId;
  final String title;
  final double x;
  final double y;
  final double width;
  final double height;

  String get description =>
      '${width.round()}×${height.round()} at (${x.round()}, ${y.round()}) • ID $windowId';
}

class QianniuConversationRow {
  const QianniuConversationRow({
    required this.customer,
    required this.unread,
    required this.unreadEvidence,
    required this.evidenceAvailable,
    this.unreadAgeSeconds,
    this.redClockPresent,
    this.signalObservedAt,
    this.unreadBadgeText,
    this.unreadBadgeConfidence,
    this.identitySource = 'unknown',
    this.rowKey,
    this.rowToken,
  });

  factory QianniuConversationRow.fromMap(Map<Object?, Object?> value) {
    final key = value['rowKey']?.toString();
    final source = value['identitySource']?.toString() ?? 'unknown';
    final staged = source == 'row_anchor';
    return QianniuConversationRow(
      customer: staged
          ? '${MacOSCaptureAdapter.provisionalPrefix}${key ?? "unresolved:${value['rowIndex']}"}'
          : value['customer']?.toString() ?? '',
      identitySource: source,
      rowKey: key,
      rowToken: value['rowToken']?.toString(),
      unread: value['unread'] == true,
      unreadEvidence: (value['unreadEvidence'] as num?)?.toInt() ?? 0,
      evidenceAvailable: value['evidenceAvailable'] == true,
      unreadAgeSeconds: (value['unreadAgeSeconds'] as num?)?.toInt(),
      redClockPresent: value['redClockPresent'] as bool?,
      signalObservedAt: value['signalObservedAtMs'] is num
          ? DateTime.fromMillisecondsSinceEpoch(
              (value['signalObservedAtMs']! as num).toInt())
          : null,
      unreadBadgeText: value['unreadBadgeText'] as String?,
      unreadBadgeConfidence:
          (value['unreadBadgeConfidence'] as num?)?.toDouble(),
    );
  }

  final String customer;
  final String? rowKey, rowToken;
  final String identitySource;
  bool get identityVerified =>
      const {'ax', 'active_ax', 'verified_alias'}.contains(identitySource);
  final bool unread;
  final int unreadEvidence;
  final bool evidenceAvailable;

  /// Elapsed time shown by JD's red unread badge, when confidently readable.
  final int? unreadAgeSeconds;
  final bool? redClockPresent;
  final DateTime? signalObservedAt;
  final String? unreadBadgeText;
  final double? unreadBadgeConfidence;
}

class OcrObservation {
  const OcrObservation({
    required this.text,
    required this.confidence,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    this.rotationDegrees = 0,
    this.isWatermark = false,
  });

  factory OcrObservation.fromMap(Map<Object?, Object?> value) => OcrObservation(
        text: value['text'] as String? ?? '',
        confidence: (value['confidence'] as num?)?.toDouble() ?? 0,
        x: (value['x'] as num?)?.toDouble() ?? 0,
        y: (value['y'] as num?)?.toDouble() ?? 0,
        width: (value['width'] as num?)?.toDouble() ?? 0,
        height: (value['height'] as num?)?.toDouble() ?? 0,
        rotationDegrees: (value['rotationDegrees'] as num?)?.toDouble() ?? 0,
        isWatermark: value['isWatermark'] == true,
      );

  final String text;
  final double confidence;
  final double x;
  final double y;
  final double width;
  final double height;
  final double rotationDegrees;
  final bool isWatermark;
}

class OcrInspection {
  const OcrInspection({
    required this.image,
    required this.imageWidth,
    required this.imageHeight,
    required this.windowTitle,
    required this.recognizedText,
    required this.observations,
    required this.capturedAt,
    this.visualRegions = const [],
    this.physicalMediaRegions,
    this.unboundMediaRegions = const [],
    this.windowId = 0,
    this.activeCustomerId,
    this.ocrEngine = 'unknown',
    this.chatTop,
    this.chatLeft,
    this.chatRight,
    this.chatBottom,
    this.failedSendCandidates = const [],
  });

  OcrInspection withObservations(List<OcrObservation> lines) => OcrInspection(
      image: image,
      imageWidth: imageWidth,
      imageHeight: imageHeight,
      windowTitle: windowTitle,
      recognizedText: recognizedText,
      observations: lines,
      capturedAt: capturedAt,
      visualRegions: visualRegions,
      physicalMediaRegions: physicalMediaRegions,
      unboundMediaRegions: unboundMediaRegions,
      windowId: windowId,
      activeCustomerId: activeCustomerId,
      ocrEngine: ocrEngine,
      chatTop: chatTop,
      chatLeft: chatLeft,
      chatRight: chatRight,
      chatBottom: chatBottom,
      failedSendCandidates: failedSendCandidates);

  factory OcrInspection.fromMap(Map<String, Object?> value) {
    final rawObservations = value['observations'] as List<Object?>? ?? const [];
    final rawVisualRegions =
        value['visualRegions'] as List<Object?>? ?? const [];
    final chatRegion = value['chatRegion'] as Map<Object?, Object?>?;
    return OcrInspection(
      image: base64Decode(value['pngBase64'] as String? ?? ''),
      imageWidth: (value['imageWidth'] as num?)?.toInt() ?? 0,
      imageHeight: (value['imageHeight'] as num?)?.toInt() ?? 0,
      windowTitle: value['windowTitle'] as String? ?? 'JD 咚咚工作台',
      recognizedText: value['recognizedText'] as String? ?? '',
      capturedAt: DateTime.fromMillisecondsSinceEpoch(
          (value['capturedAtMs'] as num?)?.toInt() ?? 0),
      activeCustomerId: value['activeCustomerId'] as String?,
      windowId: (value['windowId'] as num?)?.toInt() ?? 0,
      ocrEngine: value['ocrEngine'] as String? ?? 'unknown',
      chatTop: (chatRegion?['top'] as num?)?.toDouble(),
      chatLeft: (chatRegion?['left'] as num?)?.toDouble(),
      chatRight: (chatRegion?['right'] as num?)?.toDouble(),
      chatBottom: (chatRegion?['bottom'] as num?)?.toDouble(),
      failedSendCandidates:
          (value['failedSendCandidates'] as List<Object?>? ?? const [])
              .whereType<Map<Object?, Object?>>()
              .map((candidate) =>
                  candidate.map((key, value) => MapEntry('$key', value)))
              .toList(growable: false),
      observations: rawObservations
          .whereType<Map<Object?, Object?>>()
          .map(OcrObservation.fromMap)
          .toList(growable: false),
      visualRegions: rawVisualRegions
          .whereType<Map<Object?, Object?>>()
          .map(OcrVisualRegion.fromMap)
          .toList(growable: false),
      physicalMediaRegions: (value['physicalMediaRegions'] as List<Object?>?)
          ?.whereType<Map<Object?, Object?>>()
          .where((region) => region['proof'] == 'full_card_pixels')
          .map(OcrVisualRegion.fromMap)
          .toList(growable: false),
      unboundMediaRegions:
          (value['unboundMediaRegions'] as List<Object?>? ?? const [])
              .whereType<Map<Object?, Object?>>()
              .where((region) => region['proof'] == 'explicit_play_overlay')
              .map(OcrVisualRegion.fromMap)
              .toList(growable: false),
    );
  }

  final Uint8List image;
  final int imageWidth;
  final int imageHeight;
  final String windowTitle;
  final String recognizedText;
  final List<OcrObservation> observations;
  final List<OcrVisualRegion> visualRegions;
  final List<OcrVisualRegion>? physicalMediaRegions;

  /// Native, AX-transcript-contained play cards whose sender header may have
  /// scrolled away. These are visual duties, not guessed sender clocks/IDs.
  final List<OcrVisualRegion> unboundMediaRegions;
  final DateTime capturedAt;
  final int windowId;
  final String? activeCustomerId;
  final String ocrEngine;
  final double? chatTop;
  final double? chatLeft;
  final double? chatRight;
  final double? chatBottom;
  final List<Map<String, Object?>> failedSendCandidates;
}

class OcrVisualRegion {
  const OcrVisualRegion({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.confidence,
  });

  factory OcrVisualRegion.fromMap(Map<Object?, Object?> value) =>
      OcrVisualRegion(
        x: (value['x'] as num?)?.toDouble() ?? 0,
        y: (value['y'] as num?)?.toDouble() ?? 0,
        width: (value['width'] as num?)?.toDouble() ?? 0,
        height: (value['height'] as num?)?.toDouble() ?? 0,
        confidence: (value['confidence'] as num?)?.toDouble() ?? 0,
      );

  final double x;
  final double y;
  final double width;
  final double height;
  final double confidence;
}

class ImageOriginalAcquisitionResult {
  const ImageOriginalAcquisitionResult(
      {required this.state,
      required this.customer,
      required this.messageId,
      required this.receiptId,
      required this.senderAt,
      required this.automationEpoch,
      this.token,
      this.reason,
      this.imageConfirmed = false,
      this.image});
  final String state;
  final String customer;
  final String messageId;
  final String receiptId;
  final DateTime senderAt;
  final int automationEpoch;
  final String? token;
  final String? reason;
  final bool imageConfirmed;
  final VisibleImagePayload? image;
  bool get ready => state == 'ready' && image != null;
}

class VisibleImagePayload {
  const VisibleImagePayload({
    required this.kind,
    this.mimeType,
    this.extension,
    this.originalName,
    this.visualFingerprint,
    this.captureSource,
    this.reason,
    this.foregroundFraction,
    this.video,
    this.bytes,
    this.cacheKey,
    this.cacheModifiedAt,
    this.cardPreviewBytes,
    this.playbackOverlayDetected = false,
  });

  factory VisibleImagePayload.fromMap(Map<String, Object?> value) =>
      VisibleImagePayload(
        kind: value['kind']?.toString() ?? 'unsupported',
        mimeType: value['mimeType'] as String?,
        extension: value['extension'] as String?,
        originalName: value['originalName'] as String?,
        visualFingerprint: value['visualFingerprint'] as String?,
        captureSource: value['captureSource'] as String?,
        reason: value['reason'] as String?,
        cacheKey: value['cacheKey'] as String?,
        cacheModifiedAt: value['cacheModifiedAtMs'] is num
            ? DateTime.fromMillisecondsSinceEpoch(
                (value['cacheModifiedAtMs']! as num).toInt())
            : null,
        foregroundFraction: (value['foregroundFraction'] as num?)?.toDouble(),
        video: value['video'] is Map
            ? DownloadedVideoPayload.fromMap(
                Map<String, Object?>.from(value['video'] as Map))
            : null,
        bytes: value['dataBase64'] is String
            ? base64Decode(value['dataBase64']! as String)
            : null,
        cardPreviewBytes: value['cardPreviewDataBase64'] is String
            ? base64Decode(value['cardPreviewDataBase64']! as String)
            : null,
        playbackOverlayDetected: value['playbackOverlayDetected'] == true,
      );

  final String? cacheKey;
  final DateTime? cacheModifiedAt;
  final String kind;
  final String? mimeType;
  final String? extension;
  final String? originalName;
  final String? visualFingerprint;
  final String? captureSource;
  final String? reason;
  final double? foregroundFraction;
  final DownloadedVideoPayload? video;
  final Uint8List? bytes;
  final Uint8List? cardPreviewBytes;
  final bool playbackOverlayDetected;
}

class DownloadedVideoPayload {
  const DownloadedVideoPayload({
    required this.path,
    required this.originalName,
    required this.mimeType,
  });

  factory DownloadedVideoPayload.fromMap(Map<String, Object?> value) =>
      DownloadedVideoPayload(
        path: value['path']?.toString() ?? '',
        originalName: value['originalName']?.toString() ?? 'customer-video.mp4',
        mimeType: value['mimeType']?.toString() ?? 'video/mp4',
      );

  final String path;
  final String originalName;
  final String mimeType;
}

class CachedMediaPayload {
  const CachedMediaPayload({
    required this.kind,
    required this.cacheKey,
    required this.cacheModifiedAt,
    this.image,
    this.video,
  });

  final String kind;
  final String cacheKey;
  final DateTime cacheModifiedAt;
  final VisibleImagePayload? image;
  final DownloadedVideoPayload? video;
}

class FailedSendInspection {
  const FailedSendInspection(
      {required this.customer,
      required this.capturedAt,
      required this.candidates});

  factory FailedSendInspection.fromMap(Map<Object?, Object?> value) =>
      FailedSendInspection(
        customer: value['customer']?.toString().trim() ?? '',
        capturedAt: DateTime.fromMillisecondsSinceEpoch(
            (value['capturedAtMs'] as num?)?.toInt() ?? 0,
            isUtc: true),
        candidates: [
          for (final candidate
              in (value['candidates'] as List<Object?>? ?? const []))
            if (candidate is Map)
              candidate.map((key, value) => MapEntry('$key', value)),
        ],
      );

  final String customer;
  final DateTime capturedAt;
  final List<Map<String, Object?>> candidates;
}

class SpeechTranscription {
  const SpeechTranscription({
    required this.transcript,
    required this.language,
    required this.confidence,
    required this.speechDetected,
  });

  factory SpeechTranscription.fromMap(Map<String, Object?> value) =>
      SpeechTranscription(
        transcript: value['transcript']?.toString().trim() ?? '',
        language: value['language']?.toString() ?? '',
        confidence: (value['confidence'] as num?)?.toDouble() ?? 0,
        speechDetected: value['speechDetected'] == true,
      );

  final String transcript;
  final String language;
  final double confidence;
  final bool speechDetected;
}
