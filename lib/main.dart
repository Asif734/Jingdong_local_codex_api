import 'runtime/managed_media_processes.dart';
import 'backend/jd_v2_payload.dart';
import 'backend/jd_v2_delivery.dart';
import 'backend/jd_v2_client.dart';
import 'backend/hosted_reply_service.dart';
import 'capture/exact_timed_media.dart';
import 'capture/red_clock_tracker.dart';
import 'capture/live_message_activation.dart';
import 'capture/image_original_task_queue.dart';
import 'capture/image_original_locator.dart';
import 'capture/media_timeline_progress.dart';
import 'capture/media_payload_upgrade.dart';
import 'storage/customer_media_inventory.dart';
import 'domain/automatic_draft_save_result.dart';
import 'capture/transcript_text.dart';
import 'storage/media_visual_matcher.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:crypto/crypto.dart';

import 'capture/capture_coordinator.dart';
import 'capture/viewport_evidence.dart';
import 'capture/viewport_capture_pump.dart';
import 'capture/capture_activation_context.dart';
import 'capture/evidence_coverage.dart';
import 'capture/backfill_dispatcher.dart';
import 'storage/media_capture_audit.dart';
import 'storage/media_message_registrar.dart';
import 'storage/media_identity.dart';
import 'storage/processed_video_store.dart';
import 'storage/capture_evidence_store.dart';
import 'storage/atomic_evidence_writer.dart';
import 'capture/direct_reply_delivery.dart';
import 'capture/failed_send_retry_policy.dart';
import 'capture/ocr_capture_extractor.dart';
import 'capture/text_first_ocr_policy.dart';
import 'capture/ocr_image_candidate_selector.dart';
import 'capture/media_caption_dependency.dart';
import 'capture/live_media_admission.dart';
import 'capture/unknown_message_clarifier.dart';
import 'capture/incoming_message_blocks.dart';
import 'capture/incoming_message_ownership.dart';
import 'capture/unread_capture_recovery.dart';
import 'capture/unread_signal_tracker.dart';
import 'capture/jd_ui_scheduler.dart';
import 'capture/response_timing_policy.dart';
import 'capture/video_audio_extractor.dart';
import 'capture/video_frame_extractor.dart';
import 'codex/codex_reply_service.dart';
import 'codex/holding_replies.dart';
import 'codex/customer_language.dart';
import 'codex/fixed_replies.dart';
import 'codex/local_reply_router.dart';
import 'domain/capture_models.dart';
import 'domain/customer_message_time.dart';
import 'platform/macos_capture_adapter.dart';
import 'runtime/app_runtime.dart';
import 'runtime/runtime_trace.dart';
import 'runtime/delivery_timing.dart';
import 'runtime/installation_check.dart';
import 'storage/capture_database.dart';
import 'domain/message_record.dart';
import 'domain/named_agent_request.dart';
import 'ui/automation_controls.dart';
import 'runtime/automation_settings.dart';
import 'runtime/diagnostic_report.dart';
import 'runtime/diagnostic_work_tracker.dart';

typedef _RunVideoProcessingUnlocked = Future<CapturedMessage?> Function(
    Future<CapturedMessage?> Function() work);

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  RuntimeTrace.record('app.started', {'version': AppRuntime.version});
  if (Platform.environment['JD_INSTALLATION_CHECK'] == '1') {
    await checkInstallation();
    return;
  }
  runApp(const JdAutomationApp());
}

class JdAutomationApp extends StatelessWidget {
  const JdAutomationApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: AppRuntime.appName,
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorSchemeSeed: const Color(0xfff26b21),
          useMaterial3: true,
          scaffoldBackgroundColor: const Color(0xfffaf8f6),
          appBarTheme: const AppBarTheme(
            backgroundColor: Colors.white,
            surfaceTintColor: Colors.transparent,
            elevation: 0,
          ),
        ),
        home: const CaptureHome(),
      );
}

typedef _OriginalPageResult = ({
  ViewportEvidence frame,
  OcrInspection inspection,
  int page,
});

class CaptureHome extends StatefulWidget {
  const CaptureHome(
      {super.key,
      this.database,
      this.adapter,
      this.redClockTracker,
      this.scanIntervalOverride,
      this.mediaCacheProbeIntervalOverride,
      this.draftSchedulerOverride,
      this.generateDraftOverride,
      this.replyServiceOverride,
      this.batchCollectionWindowOverride,
      this.reportOutputDirectory});

  @visibleForTesting
  final Directory? reportOutputDirectory;
  final CaptureDatabase? database;
  final MacOSCaptureAdapter? adapter;
  @visibleForTesting
  final RedClockTracker? redClockTracker;
  @visibleForTesting
  final Duration? scanIntervalOverride;
  @visibleForTesting
  final Duration? mediaCacheProbeIntervalOverride;
  @visibleForTesting
  final void Function(String)? draftSchedulerOverride;
  @visibleForTesting
  final Future<AiDraft> Function(ConversationSummary, CaptureDatabase, String,
      CodexGenerationCancellation)? generateDraftOverride;
  @visibleForTesting
  final CodexReplyService? replyServiceOverride;
  @visibleForTesting
  final Duration? batchCollectionWindowOverride;

  @override
  State<CaptureHome> createState() => _CaptureHomeState();
}

class _CaptureHomeState extends State<CaptureHome> {
  // Covers native window capture, Apple Vision recognition, and JD UI delays.
  static const _captureOperationTimeout = Duration(seconds: 90);
  static const _unreadOperationTimeout = Duration(seconds: 12);
  // A holding message must not sit behind a full 90-second OCR/media pass.
  Duration get _scanInterval =>
      widget.scanIntervalOverride ?? const Duration(seconds: 2);
  static const _batchCollectionWindow = Duration(milliseconds: 1000);
  static const _deliveryFailureRetryDelay = Duration(seconds: 10);
  late final MacOSCaptureAdapter _adapter;
  late final DirectReplyDelivery _directDelivery;
  late final CaptureCoordinator _coordinator;
  late final CaptureDatabase _database;
  late final CaptureEvidenceStore _evidenceStore;
  late final MediaCaptureAudit _mediaAudit;
  late final CustomerMediaInventory _mediaInventory;
  late final MediaMessageRegistrar _mediaRegistrar;
  final Map<String, String> _activeDraftTokens = {};
  final Map<String, bool> _activeDraftMediaSensitive = {};
  final Map<String, DateTime> _activeSocialTurnClocks = {};
  Future<void>? _evidenceRecovery;
  bool _evidenceWakeRequested = false;
  final _registrationWorkers = <String, int>{};
  final _registrationCustomerWakes = <String>{};
  final _viewportOcrTasks = <String, Future<OcrInspection?>>{};
  final _textFirstOcrPolicy = TextFirstOcrPolicy();
  final _textFirstProbes = <String, int>{};
  final _mediaEvidenceWorkers = <String, int>{};
  final _mediaEvidenceCustomerWakes = <String>{};
  bool _mediaEvidenceWakeRequested = false;
  int? _mediaEvidenceWorkerEpoch;
  final _registeredEvidenceOcr = <String, OcrInspection>{};
  ProcessedVideoStore? _processedVideos;
  final Map<String, int> _visualMediaCaptures = {};
  final Map<String, DateTime> _lastPhysicalReplyAt = {};
  final Map<String, Future<void>> _evidencePins = {};
  final Map<String, (int, DateTime)> _pinAttempts = {};
  StreamSubscription? _updateSubscription;
  StreamSubscription? _diagnosticSubscription;
  StreamSubscription? _failedSendInspectionSubscription;
  List<ConversationSummary> _conversations = const [];
  Map<String, Object?> _status = const {};
  String? _selfServiceAccount;
  String _diagnostics = 'No AX inspection yet.';
  Object? _error;
  AutomationSettings _automationSettings = const AutomationSettings();
  AutomationSettingsStore _settingsStore = AutomationSettingsStore();
  Future<void> _settingsWrite = Future<void>.value();
  bool _settingsLoaded = false;
  bool _settingsValid = true;
  bool _exportingReport = false;
  final _diagnosticWork = DiagnosticWorkTracker();
  int _reportTraceStartOffset = 0;
  DateTime? _reportRunStartedAt;
  DateTime? _reportRunStoppedAt;
  Map<String, Object?> _reportStopSummary = const {};
  AutomationSettings _reportSettings = const AutomationSettings();

  Map<String, int>? _unansweredCounts;
  Map<String, int> _admissionGapCounts = {};
  bool _unansweredCountsFailed = false;
  String? _selectedMessageCustomer;
  List<CustomerMessageRecord>? _selectedMessageRecords;
  bool _messageRecordsLoading = false;
  bool _messageRecordsFailed = false;
  int _messageRecordsRefresh = 0;
  int _workSummaryRefresh = 0;
  bool _workSummaryBusy = false;
  bool _workSummaryAgain = false;
  bool _homeDisposed = false;
  String? _handoffServiceAlert;
  final Map<int, DateTime> _handoffOwnershipProbeAfter = {};
  OcrInspection? _ocrInspection;
  bool _autoCaptureRunning = false;
  int _runEpoch = 0;
  String? _automationSessionId;
  DateTime? _automationSessionStartedAt;
  final Set<String> _refinedUnknownBlockKeys = {};
  int? _evidenceWorkerEpoch;
  int? _deliveryWorkerEpoch;
  final Map<String, int> _draftWorkerEpochs = {};
  final Map<String, int> _transferWorkerEpochs = {};
  Timer? _maintenanceTimer;
  bool _maintenanceBusy = false;
  bool _businessDayRolloverBusy = false;
  final Map<String, DateTime> _healthLoggedAt = {};
  void _checkRun(int epoch) {
    if (!_autoCaptureRunning || epoch != _runEpoch || !mounted) {
      throw const _AutomationStopped();
    }
    if (_database.businessDayHasChanged) {
      unawaited(_rollBusinessDay(epoch));
      throw const _AutomationStopped();
    }
  }

  Future<void> _rollBusinessDay(int epoch) async {
    if (_businessDayRolloverBusy ||
        !_autoCaptureRunning ||
        epoch != _runEpoch ||
        !_database.businessDayHasChanged) {
      return;
    }
    _businessDayRolloverBusy = true;
    try {
      RuntimeTrace.record('automation.business_day_changed', {
        'previousBusinessDay': _database.currentBusinessDayKey,
        'previousBusinessResumed': false,
        ..._automationSettings.toJson(),
      });
      // The existing Stop/Start lifecycle changes the native epoch, cancels
      // old generators and archives prior business without changing receipts.
      // It never closes the JD chat window or starts another native send.
      await _start();
      if (!mounted || _autoCaptureRunning || _autoCaptureStarting) return;
      await _start(businessDayBoundary: _database.currentCalendarDayStart);
    } on _AutomationStopped {
      // An operator Stop or a disposed window wins over automatic rollover.
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      _businessDayRolloverBusy = false;
    }
  }

  bool _autoCaptureStarting = false;
  bool _databaseReady = false;
  Future<bool>? _databaseReadinessCheck;
  bool _autoCaptureBusy = false;
  bool _initialCaptureScanReady = false;
  int _completedCaptureScans = 0;
  final Map<String, int> _passiveBaselineScans = {};
  final Map<String, bool> _sidebarUnreadSeen = {};
  final Map<String, bool> _sidebarRedSeen = {};
  final Map<String, String> _liveUnreadArrivals = {};
  final Set<String> _observedCaptureCustomers = {};
  final Set<String> _verifiedLiveCaptureCustomers = {};
  int _liveArrivalSequence = 0;
  bool _mediaCacheProgressBusy = false;
  Timer? _mediaCacheProgressTimer;
  String? _mediaCacheRevision;
  Timer? _autoCaptureTimer;
  Timer? _unreadSignalTimer;
  Timer? _redSignalTimer;
  bool _redSignalBusy = false;
  Timer? _activeChatSignalTimer;
  bool _unreadSignalBusy = false;
  bool _activeChatSignalBusy = false;
  final _viewportCapturePump = ViewportCapturePump();
  bool _failedSendRetryBusy = false;
  Timer? _failedSendRetryTimer;
  final Map<String, Timer> _draftRetryTimers = {};
  final Map<String, Timer> _batchCollectionTimers = {};
  final Map<String, Timer> _slaFallbackTimers = {};
  Timer? _deliveryRetryTimer;
  final _rowsWaitingVisibility = <String>{};

  final Set<String> _draftQueue = {};
  // These workers collect completed answers and apply customer business guards.
  // Hosted API requests run independently per message, including within a
  // customer; the native foreground delivery queue remains serialized.
  static const int _maxConcurrentDraftWorkers = 20;
  final Set<String> _activeDraftUsers = {};
  final Map<String, Map<String, HostedReplyCompletion>>
      _hostedCompletionQueues = {};
  final Set<String> _hostedCompletionBusy = {};
  final Set<String> _hostedCompletedJobs = {};
  final Map<String, DateTime> _hostedCompletionRetryAt = {};
  final Map<String, Timer> _hostedCompletionTimers = {};
  final Set<String> _completedApiDeliveryCustomers = {};

  final Set<String> _answerRepairRetries = {};
  final Map<String, CodexGenerationCancellation> _activeDraftCancellations = {};
  final Map<String, String> _activeDraftMessageIds = {};
  final _jdUiScheduler = JdUiScheduler();
  int _pendingJdUiOperations = 0;
  int _priorityUiOperations = 0;
  int _slaPreemptiveUiOperations = 0;
  bool _deliveryWorkerRunning = false;
  bool _deliveryRequested = false;
  final Map<String, int> _processingUnreadEvidence = {};
  final Map<String, int> _handledUnreadEvidence = {};
  final Map<String, DateTime> _handledUnreadAt = {};
  final Map<String, String> _handledIncomingSenderKeys = {};
  final Map<String, DateTime> _lastUnreadProbeAt = {};
  final Map<String, UnreadCaptureRecovery> _unreadRecovery = {};
  final Map<String, UnreadCaptureRecovery> _mediaAcquisition = {};
  final _imageOriginalTasks = ImageOriginalTaskQueue();
  Timer? _imageOriginalTimer;
  static const _maxOriginalMediaWorkers = 8;
  DateTime? _imageOriginalWakeAt;
  final _originalPageCaptures =
      SharedImageAcquisitionWork<(int, String, int), _OriginalPageResult?>();
  final _originalFrameOcr =
      SharedImageAcquisitionWork<(int, String), OcrInspection>(
          completedLimit: 24);
  final _originalFrameCrops = SharedImageAcquisitionWork<
      (int, String, double, double, double, double, int?),
      VisibleImagePayload>();
  static const _maxParallelTimedMatches = 24;
  final _timedMatchesInFlight = <(int, String, String)>{};
  final _testedTimedCards = <(int, String, String)>{};
  final _timedMediaWrites = SharedImageAcquisitionWork<(int, String), void>();
  final _originalOcrWrites =
      SharedImageAcquisitionWork<(int, String), void>(completedLimit: 24);
  bool _imageOriginalSeeding = false;
  final Map<String, String> _claimedJdCacheMediaOwners = {};
  final Set<String> _startingUnreadRecovery = {};
  final Map<String, Timer> _unreadHoldingTimers = {};
  final Map<String, Timer> _unreadResendTimers = {};
  final Set<String> _visibleTransferWelcomes = {};
  final Set<String> _transferringCustomers = {};
  String _visibleMediaTrace = 'visible image candidates=0, saved=0';

  @override
  void initState() {
    super.initState();
    if (Platform.isMacOS) {
      _redClocks = widget.redClockTracker ?? RedClockTracker();
      _adapter = widget.adapter ?? MacOSCaptureAdapter();
      _directDelivery = DirectReplyDelivery(_adapter,
          onRedClockCleared: (customer, observedAt, cycleId) async {
        if (cycleId == null) return;
        await _database.observePlatformResponse(customer,
            red: false, observedAt: observedAt, expectedCycleId: cycleId);
        final cycle = await _database.platformResponseCycle(customer);
        if (cycle?['cycle_id'] == cycleId && cycle?['state'] == 'cleared') {
          _redClocks.observe(customer, present: false);
          _forgetSlaTimer(customer, expectedCycleId: cycleId);
        }
      }, onConfirmed: (customer, started, attemptId, cycleId) async {
        JdV2Delivery.onConfirmed(_database);
        _lastPhysicalReplyAt[customer] = started;
        await _database.confirmPlatformResponse(customer, started,
            attemptId: attemptId, expectedCycleId: cycleId);
      });
      _database = widget.database ?? CaptureDatabase(currentDayOnly: true);
      unawaited(_loadAutomationSettings());
      _evidenceStore = CaptureEvidenceStore(_database);
      _mediaAudit = MediaCaptureAudit(_database);
      _mediaInventory = CustomerMediaInventory(_database);
      _mediaRegistrar = MediaMessageRegistrar(_database,
          audit: _mediaAudit, inventory: _mediaInventory);
      _coordinator = CaptureCoordinator(_adapter, _database);
      _updateSubscription = _coordinator.updates.listen(
        (value) {
          setState(() => _conversations = value);
          _refreshTickets();
        },
        onError: (Object error) => setState(() {
          _error = error;
          RuntimeTrace.record('ui.error', {'error': '$error'});
        }),
      );
      _diagnosticSubscription = _adapter.diagnostics.listen(
        (value) => setState(() =>
            _diagnostics = const JsonEncoder.withIndent('  ').convert(value)),
      );
      _failedSendInspectionSubscription = _adapter.failedSendInspections.listen(
        (inspection) => unawaited(_observeFailedSendInspection(inspection)),
      );
      _refreshStatus();
      _refreshTickets();
    }
  }

  void _launchDiagnosticWork(Future<void> work) {
    unawaited(_diagnosticWork.track(work));
  }

  Future<void> _loadAutomationSettings() async {
    try {
      _settingsStore =
          AutomationSettingsStore(storageRoot: await _database.storageRoot);
      final settings = await _settingsStore.load();
      if (!mounted) return;
      _database.configureAutomationSettings(settings);
      _redClocks.responseTarget = settings.holdingDelay;
      setState(() {
        _automationSettings = settings;
        _settingsLoaded = true;
      });
    } catch (error) {
      RuntimeTrace.record('settings.load_failed', {'error': '$error'});
      if (mounted) setState(() => _settingsLoaded = true);
    }
  }

  void _changeAutomationSettings(AutomationSettings settings) {
    if (_autoCaptureRunning || _autoCaptureStarting || _exportingReport) return;
    setState(() => _automationSettings = settings);
    // Serialize atomic preference writes while the user edits multiple fields.
    _settingsWrite = _settingsWrite
        .then((_) => _settingsStore.save(settings))
        .catchError((Object error) {
      RuntimeTrace.record('settings.save_failed', {'error': '$error'});
    });
  }

  Future<void> _exportStoppedReport() async {
    if (_autoCaptureRunning ||
        _autoCaptureStarting ||
        _exportingReport ||
        _reportRunStartedAt == null ||
        _reportRunStoppedAt == null) return;
    setState(() => _exportingReport = true);
    try {
      // Wait for the actual capture consumer, including its durable writes.
      // No new capture can start after the automation epoch was stopped.
      await _viewportCapturePump.whenIdle;
      await _diagnosticWork.whenIdle;
      await _adapter.flushDiagnosticTrace();
      // Native completion events may start receipt reconciliation in Dart.
      await _diagnosticWork.whenIdle;
      await RuntimeTrace.flush();
      final home = Platform.environment['HOME'];
      final output = widget.reportOutputDirectory ??
          Directory(home == null
              ? '${(await _database.storageRoot).path}/reports'
              : '$home/Downloads');
      final result = await DiagnosticReportExporter().export(
          database: _database,
          outputDirectory: output,
          runStartedAt: _reportRunStartedAt!,
          runStoppedAt: _reportRunStoppedAt!,
          processingSettledAt: DateTime.now(),
          stopSummary: _reportStopSummary,
          traceStartOffset: _reportTraceStartOffset,
          settings: _reportSettings.toJson());
      final archive = '${result.directory.path}.zip';
      final zip = await Process.run('/usr/bin/ditto', [
        '-c',
        '-k',
        '--sequesterRsrc',
        '--keepParent',
        result.directory.path,
        archive
      ]);
      final exported = zip.exitCode == 0 ? archive : result.directory.path;
      RuntimeTrace.record('report.exported', {'path': exported});
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            duration: const Duration(seconds: 12),
            content: Text('报告已导出：$exported'),
            action: SnackBarAction(
                label: '在文件夹中显示',
                onPressed: () {
                  unawaited(Process.run('/usr/bin/open', ['-R', exported]));
                })));
      }
    } catch (error) {
      RuntimeTrace.record('report.export_failed', {'error': '$error'});
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('报告导出未完成，请重试。')));
    } finally {
      if (mounted) setState(() => _exportingReport = false);
    }
  }

  Future<void> _refreshStatus() async {
    try {
      await _refreshCurrentServiceAccount();
      if (!await _prepareDatabaseForAutomation()) return;
      final status = await _adapter.status();
      if (mounted) setState(() => _status = status);
      await _refreshTickets();
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = error;
          RuntimeTrace.record('ui.error', {'error': '$error'});
        });
      }
    }
  }

  Future<String?> _refreshCurrentServiceAccount() async {
    String? account;
    try {
      await _adapter.readCurrentServiceAccount();
      account = _adapter.currentServiceAccount;
    } catch (_) {
      // This optional routing fact never blocks replies or the red-clock SLA.
    }
    if (mounted && !_homeDisposed) {
      setState(() => _selfServiceAccount = account);
    }
    return account;
  }

  Future<NamedAgentRequest?> _namedRequestForTicket(
      HumanReviewTicket ticket) async {
    final text = await _database.handoffRequestText(ticket.id);
    if (text == null) return null;
    return NamedAgentRequest.parse(text);
  }

  Future<bool> _satisfyCurrentAgentRequest(HumanReviewTicket ticket,
      NamedAgentRequest request, String account) async {
    if (!request.matchesAccount(account)) return false;
    if (_adapter.currentServiceAccount != account &&
        await _refreshCurrentServiceAccount() != account) {
      return false;
    }
    final retired = await _database.satisfyCurrentAgentHandoff(ticket.id,
        currentServiceAccount: account,
        requestedTarget: request.target,
        preserveAuthorityReview: true);
    if (retired && _autoCaptureRunning) {
      _draftRetryTimers.remove(ticket.conversationId)?.cancel();
      _scheduleDraftGeneration(ticket.conversationId, newEvidence: true);
      unawaited(_refreshTickets());
    }
    return retired;
  }

  Future<bool> _prepareDatabaseForAutomation() =>
      _databaseReadinessCheck ??= () async {
        const failurePrefix = '数据库初始化失败，自动化未启动：';
        try {
          await _database.ensureAutomationSchemaReady();
          if (!mounted || _homeDisposed) return false;
          setState(() {
            _databaseReady = true;
            if (_error is String &&
                (_error as String).startsWith(failurePrefix)) {
              _error = null;
            }
          });
          return true;
        } catch (error) {
          if (mounted && !_homeDisposed) {
            setState(() {
              _databaseReady = false;
              _error = '$failurePrefix$error';
            });
            RuntimeTrace.record('ui.error', {
              'stage': 'database_startup_check',
              'error': '$error',
            });
          }
          return false;
        } finally {
          _databaseReadinessCheck = null;
        }
      }();

  Future<void> _refreshTickets() async {
    if (!mounted || _homeDisposed) return;
    if (_workSummaryBusy) {
      _workSummaryAgain = true;
      return;
    }
    _workSummaryBusy = true;
    final refresh = ++_workSummaryRefresh;
    final session = _database.currentAutomationSessionId;
    try {
      final counts = await _database.unansweredWorkCounts();
      if (!mounted || _homeDisposed) return;
      final gaps = await _mediaAudit.pendingAdmissionGaps();
      final gapCounts = <String, int>{};
      for (final gap in gaps) {
        final customer = gap['customer']! as String;
        gapCounts.update(customer, (n) => n + 1, ifAbsent: () => 1);
      }
      final blocked = await _database.blockedHandoffServices();
      if (!mounted ||
          _homeDisposed ||
          refresh != _workSummaryRefresh ||
          session != _database.currentAutomationSessionId) {
        return;
      }
      setState(() {
        _unansweredCounts = counts;
        _admissionGapCounts = gapCounts;
        _unansweredCountsFailed = false;
        _handoffServiceAlert = blocked.isEmpty
            ? null
            : blocked
                .map((s) =>
                    '${s['customer']}：转接待办尚未完成，AI继续回复；${_handoffProblemLabel(s['state']?.toString())}')
                .join('\n');
      });
      final selected = _selectedMessageCustomer;
      if (selected != null) await _loadMessageRecords(selected);
    } catch (_) {
      if (mounted && !_homeDisposed && refresh == _workSummaryRefresh) {
        setState(() => _unansweredCountsFailed = true);
      }
    } finally {
      _workSummaryBusy = false;
      if (_workSummaryAgain && mounted && !_homeDisposed) {
        _workSummaryAgain = false;
        unawaited(_refreshTickets());
      }
    }
  }

  Future<void> _loadMessageRecords(String customer) async {
    final refresh = ++_messageRecordsRefresh;
    final session = _database.currentAutomationSessionId;
    try {
      final records = await _database.customerMessageRecords(customer);
      if (!mounted ||
          _homeDisposed ||
          refresh != _messageRecordsRefresh ||
          session != _database.currentAutomationSessionId ||
          customer != _selectedMessageCustomer) {
        return;
      }
      setState(() {
        _selectedMessageRecords = records;
        _messageRecordsLoading = false;
        _messageRecordsFailed = false;
      });
    } catch (_) {
      if (mounted &&
          !_homeDisposed &&
          refresh == _messageRecordsRefresh &&
          customer == _selectedMessageCustomer) {
        setState(() {
          _messageRecordsLoading = false;
          _messageRecordsFailed = true;
        });
      }
    }
  }

  void _selectMessageCustomer(String customer) {
    setState(() {
      _selectedMessageCustomer = customer;
      _selectedMessageRecords = null;
      _messageRecordsLoading = true;
      _messageRecordsFailed = false;
    });
    unawaited(_loadMessageRecords(customer));
  }

  Future<void> _retryCustomerAnswer(String customer) async {
    if (!_autoCaptureRunning || !_answerRepairRetries.add(customer)) return;
    final epoch = _runEpoch;
    setState(() {});
    try {
      await _database.retryAutomaticReplyRepair(customer);
      _checkRun(epoch);
      await _queueDraftIfPending(customer);
      await _refreshTickets();
    } on _AutomationStopped {
      // A stopped run cannot authorize a new generation.
    } catch (error) {
      if (mounted && epoch == _runEpoch) {
        setState(() => _error = error);
      }
    } finally {
      _answerRepairRetries.remove(customer);
      if (mounted) setState(() {});
    }
  }

  String _handoffProblemLabel(String? reason) => switch (reason) {
        'new_request_ownership_required' => '正在核验当前接待归属；未确认前请客服核实旧转接结果',
        'previous_transfer_unknown' ||
        'acknowledgement_unknown' =>
          '旧转接结果待核实，请客服在京麦接手',
        'no_active_agents' => '暂无可转接的在线客服，请当前客服接手',
        'current_agent_review_required' => '已由指定客服接待，订单等权限操作仍待人工核查',
        'newer_request_after_confirmed_transfer' => '上次转接已完成，新的转接请求待核查，自动回复继续',
        'retry_exhausted' => '转接重试已用尽，请当前客服接手',
        'conversation_open_pending' => '正在确认客户窗口，转接任务保留，自动回复继续',
        _ => '自动转接未完成，请当前客服接手',
      };

  Future<void> _beginAutomaticTransfer(HumanReviewTicket ticket,
      {bool preserveAiWork = false}) async {
    final customer = ticket.conversationId;
    await _database.markTicketHandoffPending(ticket.id);
    if (!await _database.isHandoffExecutionCurrent(ticket.id) ||
        await _database.isHumanContacting(customer)) {
      throw PlatformException(code: 'handoff_cancelled_by_operator');
    }
    if (!preserveAiWork) {
      _draftRetryTimers.remove(customer)?.cancel();
      _draftQueue.remove(customer);
    }
    await _coordinator.refresh();
    await _refreshTickets();
  }

  final _queuedTransferTickets = <int>{};

  Future<bool> _autoTransferTicket(HumanReviewTicket ticket) async {
    final releaseDiagnosticWork = _diagnosticWork.acquire();
    try {
      if (!_autoCaptureRunning ||
          !await _database.isApiTransferTicket(ticket.id) ||
          !_queuedTransferTickets.add(ticket.id)) return false;
      try {
        return await _withJdUiOperation(() => _autoTransferTicketWithUi(ticket),
            priority: JdUiPriority.transfer);
      } on _AutomationStopped {
        return false;
      } finally {
        _queuedTransferTickets.remove(ticket.id);
      }
    } finally {
      releaseDiagnosticWork();
    }
  }

  Future<bool> _autoTransferTicketWithUi(
      HumanReviewTicket initialTicket) async {
    if (!_autoCaptureRunning) return false;
    if (!await _database.isCurrentSessionTicket(initialTicket.id)) return false;
    var ticket = initialTicket;
    final epoch = _runEpoch;
    final customer = ticket.conversationId;
    if (!_transferringCustomers.add(customer)) return false;
    _transferWorkerEpochs[customer] = epoch;
    Future<T> withinTransferUi<T>(Future<T> Function() operation,
        {JdUiPriority? priority}) async {
      _checkRun(epoch);
      // The outer transaction already holds the UI lease; do not acquire it
      // recursively, or release it between inspection, acknowledgement and click.
      return operation();
    }

    ChatTransferLog? log;
    String? target;
    String? transferAttemptId;
    var transferCallInvoked = false;
    var nativeTransferConfirmed = false;
    var phase = 'reservation';
    Map<String, Object?>? continuation;
    NamedAgentRequest? requestedAgent;
    try {
      _checkRun(epoch);
      requestedAgent = await _namedRequestForTicket(ticket);
      _checkRun(epoch);
      final initialNamedRequest = requestedAgent;
      if (initialNamedRequest != null) {
        final account = await _refreshCurrentServiceAccount();
        _checkRun(epoch);
        if (account != null &&
            await _satisfyCurrentAgentRequest(
                ticket, initialNamedRequest, account)) {
          return false;
        }
      }
      if (!await _database.isHandoffExecutionCurrent(ticket.id)) return false;
      if (DateTime.now()
          .isBefore(_handoffOwnershipProbeAfter[ticket.id] ?? DateTime(1970))) {
        return false;
      }
      continuation = await _database.handoffReplyContinuation(ticket.id);
      _checkRun(epoch);
      log = await _database.reserveChatTransferLog(ticket: ticket);
      TransferAccountPreview? receptionPreview;
      if (log == null) {
        final service = await _database.handoffServiceStatus(customer);
        if (service?['state'] == 'new_request_ownership_required' &&
            !DateTime.now().isBefore(
                _handoffOwnershipProbeAfter[ticket.id] ?? DateTime(1970))) {
          _handoffOwnershipProbeAfter[ticket.id] =
              DateTime.now().add(const Duration(seconds: 30));
          phase = 'revalidate_reception_ownership';
          await withinTransferUi(() async {
            _checkRun(epoch);
            await _adapter.openConversation(customer,
                allowActivation: true,
                purpose: ConversationOpenPurpose.transfer);
            _checkRun(epoch);
            final proof = await _adapter.readReceptionOwnership(customer);
            _checkRun(epoch);
            receptionPreview =
                await _adapter.listActiveTransferAccounts(customer);
            _checkRun(epoch);
            final fresh = await _database.startNewHandoffAfterReceptionProof(
                ticketId: ticket.id,
                proof: proof,
                sourceAccount: receptionPreview!.sourceAccount);
            if (fresh != null) ticket = fresh;
          }, priority: JdUiPriority.transfer);
          _checkRun(epoch);
          if (ticket.id != initialTicket.id) {
            continuation = null;
            requestedAgent = await _namedRequestForTicket(ticket);
            _checkRun(epoch);
            log = await _database.reserveChatTransferLog(ticket: ticket);
          }
        }
        if (log == null) {
          if (receptionPreview != null) {
            await _adapter.cancelTransferSelection();
          }
          _handoffOwnershipProbeAfter[ticket.id] =
              DateTime.now().add(const Duration(seconds: 30));
          final status = await _database.handoffServiceStatus(customer);
          await _database.releaseHandoffForAi(ticket.id,
              reason: status?['state']?.toString() ?? 'reservation_unavailable',
              unknownClick:
                  status?['state']?.toString().contains('unknown') == true);
          RuntimeTrace.record('handoff.reservation_declined', {
            'customer': customer,
            'ticketId': ticket.id,
            'reason': status?['state'] ?? 'ticket_or_reservation_changed',
            'oldLogId': status?['logId'],
            'requestMessageId': status?['requestMessageId'],
            'oldRequestMessageId': status?['oldRequestMessageId'],
            'handoffCompleted': false,
            'businessResponseSent': false,
            'caseResolved': null,
            'holdingDoesNotResolve': true
          });
          if (_autoCaptureRunning && epoch == _runEpoch) {
            _scheduleDraftGeneration(customer, newEvidence: true);
          }
          return false;
        }
      }
      final namedRequest = requestedAgent;
      if (continuation != null) {
        final current = await _database.handoffReplyContinuation(ticket.id);
        _checkRun(epoch);
        continuation = current?['logId'] == log.id &&
                current?['requestMessageId'] == continuation['requestMessageId']
            ? current
            : null;
      }
      await _beginAutomaticTransfer(ticket,
          preserveAiWork: continuation != null);
      Future<void> runTransferPhase(Future<bool> Function() operation) async {
        _checkRun(epoch);
        final completed = await withinTransferUi(() async {
          _checkRun(epoch);
          return operation();
        }, priority: JdUiPriority.transfer);
        if (!completed) {
          throw PlatformException(code: 'handoff_yielded_for_reply');
        }
      }

      late TransferAccountPreview preview;
      final resumeTarget = continuation?['targetAccount'] as String?;
      final resumeSource = continuation?['sourceAccount'] as String?;
      // One owned modal stays open from account inspection through native
      // revalidation and click. No local acknowledgement is sent in between.
      if (receptionPreview != null) {
        preview = receptionPreview!;
      } else {
        phase = 'inspect_accounts';
        await _database.updateChatTransferLog(
            id: log.id,
            status: 'pending',
            phase: phase,
            transferClicked: false);
        await runTransferPhase(() async {
          _checkRun(epoch);
          await _adapter.openConversation(customer,
              allowActivation: true, purpose: ConversationOpenPurpose.transfer);
          _checkRun(epoch);
          preview = await _adapter.listActiveTransferAccounts(customer);
          _checkRun(epoch);
          return true;
        });
      }
      if (resumeSource?.isNotEmpty == true &&
          resumeSource != preview.sourceAccount) {
        throw PlatformException(code: 'transfer_source_changed');
      }
      var eligible = preview.activeAccounts
          .where((a) => a.trim() != preview.sourceAccount.trim())
          .toList();
      if (namedRequest != null) {
        if (await _satisfyCurrentAgentRequest(
            ticket, namedRequest, preview.sourceAccount)) {
          await _adapter.cancelTransferSelection();
          return false;
        }
        final matching = namedRequest.firstMatchingAccount(eligible);
        if (matching == null) {
          throw PlatformException(
              code: 'requested_transfer_account_unavailable');
        }
        eligible = [matching];
        target = matching;
      }
      if (eligible.isEmpty) {
        throw PlatformException(code: 'no_active_transfer_accounts');
      }
      if (target == null &&
          resumeTarget != null &&
          eligible.contains(resumeTarget)) {
        target = resumeTarget;
      }
      target ??= await _database.chooseAutomaticTransferAccount(eligible);
      _checkRun(epoch);
      await _database.updateChatTransferLog(
          id: log.id,
          status: 'ready',
          sourceAccount: preview.sourceAccount,
          targetAccount: target);
      _checkRun(epoch);
      await _database.updateChatTransferLog(
          id: log.id,
          status: 'transferring',
          sourceAccount: preview.sourceAccount,
          targetAccount: target);
      phase = 'revalidate_target';
      // Native code freshly checks this still-open modal, the exact target's
      // active status, row action and AX customer before its one click.
      await runTransferPhase(() async {
        _checkRun(epoch);
        if (!await _database.isHandoffExecutionCurrent(ticket.id)) {
          throw PlatformException(code: 'handoff_cancelled_by_operator');
        }
        _checkRun(epoch);
        final attempt = await _database.beginTransferAttempt(
            logId: log!.id, customer: customer, targetAccount: target!);
        transferAttemptId = attempt['attemptId']!;
        _checkRun(epoch);
        await _database.markTransferNativeInvoked(log!.id, transferAttemptId!);
        phase = 'transfer_click_and_confirm';
        transferCallInvoked = true;
        final accepted = await _adapter.transferConversation(
            expectedCustomer: customer,
            targetAccount: target!,
            attemptId: transferAttemptId,
            receiptPath: attempt['receiptPath']);
        if (accepted['transferred'] != true ||
            accepted['customer'] != customer ||
            accepted['targetAccount'] != target ||
            accepted['attemptId'] != transferAttemptId ||
            accepted['receiptState'] != 'confirmed' ||
            accepted['transferClicked'] != true) {
          throw PlatformException(
              code: 'transfer_unconfirmed', details: accepted);
        }
        nativeTransferConfirmed = true;
        return true;
      });
      // A clicked transfer is an observed fact even if Stop was pressed while
      // native confirmation was in flight. Complete its local work without
      // holding the UI lease or tying it to the ticket's newest request.
      phase = 'persist_confirmed_transfer';
      final confirmedLogId = log.id;
      final confirmedAttemptId = transferAttemptId!;
      await _database.updateChatTransferLog(
          id: confirmedLogId,
          expectedAttemptId: confirmedAttemptId,
          status: 'transferred',
          phase: 'confirmed',
          transferClicked: true,
          sourceAccount: preview.sourceAccount,
          targetAccount: target);
      phase = 'settle_confirmed_transfer';
      // The verified native receipt owns the physical confirmation time;
      // a delayed Dart callback must not swallow a customer's fresh return.
      final settled = await _database.settleConfirmedTransfer(
          logId: confirmedLogId, attemptId: confirmedAttemptId);
      RuntimeTrace.record('handoff.confirmed', {
        'customer': customer,
        'target': target,
        'ticketId': ticket.id,
        'attemptId': transferAttemptId,
        'handoffCompleted': true,
        'localCompletionApplied': settled,
        'businessResponseSent': false,
        'caseResolved': null,
      });
      return true;
    } catch (error) {
      if (nativeTransferConfirmed) {
        // Failed local bookkeeping cannot undo native success or grant
        // permission to click Transfer twice. The durable receipt remains
        // available to maintenance for this exact attempt.
        RuntimeTrace.record('handoff.local_completion_pending', {
          'customer': customer,
          'ticketId': ticket.id,
          'logId': log?.id,
          'attemptId': transferAttemptId,
          'stage': phase,
          'errorCode': error.runtimeType.toString(),
          'nativeConfirmed': true,
        });
        return true;
      }
      final details = error is PlatformException && error.details is Map
          ? error.details as Map
          : const {};
      final knownPreclick = !transferCallInvoked ||
          (details['attemptId'] == transferAttemptId &&
              details['transferClicked'] == false &&
              details['receiptState'] == 'not_clicked');
      final bool? clickedEvidence = !transferCallInvoked
          ? false
          : details['attemptId'] == transferAttemptId &&
                  details['transferClicked'] is bool
              ? details['transferClicked'] as bool
              : null;
      final acknowledgementUncertain =
          log != null && await _database.transferAcknowledgement(log.id) == 2;
      var unconfirmed = !knownPreclick ||
          acknowledgementUncertain ||
          (error is PlatformException && error.code == 'transfer_unconfirmed');
      final stopped = error is _AutomationStopped ||
          !_autoCaptureRunning ||
          epoch != _runEpoch;
      if (!stopped &&
          !unconfirmed &&
          !transferCallInvoked &&
          error is PlatformException &&
          error.code == 'conversation_open_pending') {
        if (log == null) {
          return false;
        }
        final resumePhase =
            target == null ? 'inspect_accounts' : 'revalidate_target';
        final deferred = await _database.deferHandoffForOpenRecovery(
            logId: log.id,
            ticketId: ticket.id,
            resumePhase: resumePhase,
            reason: details['pendingReason']?.toString() ??
                'ax_verification_pending');
        _checkRun(epoch);
        if (deferred) {
          RuntimeTrace.record('handoff.open_recovery_pending', {
            'customer': customer,
            'ticketId': ticket.id,
            'logId': log.id,
            'resumePhase': resumePhase,
            'openStage': details['openStage'],
            'reason': details['pendingReason'],
            'rowClickDispatched': details['clickDispatched'],
            'transferClicked': false,
            'failureCountUnchanged': true,
            'originalQuestionPreserved': true,
          });
          _scheduleDraftGeneration(customer, newEvidence: true);
          if (mounted) {
            setState(() => _diagnostics = '客户窗口正在恢复确认，转接任务保留，自动回复继续。');
          }
          return false;
        }
        // A changed ticket/operator/journal cannot authorize recovery or a
        // fallback failure update. Preserve its newer state and release UI.
        return false;
      }
      var yielded = !stopped &&
          !unconfirmed &&
          log != null &&
          error is PlatformException &&
          error.code == 'handoff_yielded_for_reply';
      if (yielded) {
        final deferred = await _database.deferHandoffForReply(
            logId: log.id,
            ticketId: ticket.id,
            resumePhase:
                target == null ? 'inspect_accounts' : 'revalidate_target',
            provenNotClickedAttemptId:
                transferCallInvoked ? transferAttemptId : null);
        if (!deferred) {
          if (!transferCallInvoked) return false;
          // Native's return value alone cannot release an invoked attempt.
          // Missing or conflicting durable click evidence remains uncertain.
          yielded = false;
          unconfirmed = true;
        }
      }
      if (log != null && !yielded) {
        await _database.updateChatTransferLog(
            id: log.id,
            status: unconfirmed
                ? 'unconfirmed'
                : stopped
                    ? 'cancelled'
                    : 'failed',
            targetAccount: target,
            phase: unconfirmed
                ? acknowledgementUncertain
                    ? 'acknowledgement_unknown'
                    : 'unknown'
                : stopped
                    ? 'cancelled_preclick'
                    : 'retryable_preclick',
            transferClicked: clickedEvidence,
            error: error.toString());
      }
      if (!unconfirmed && !yielded) {
        // Close only our transfer modal under the same scheduler, never a chat
        // window and never an unrelated modal after automation was stopped.
        if (!stopped) {
          try {
            await withinTransferUi(() => _adapter.cancelTransferSelection(),
                priority: JdUiPriority.transfer);
          } catch (_) {}
        }
      }
      if (!stopped) {
        if (!yielded) {
          await _database.releaseHandoffForAi(ticket.id,
              reason: error is PlatformException
                  ? error.code
                  : error.runtimeType.toString(),
              unknownClick: unconfirmed,
              countPreclickFailure: !unconfirmed);
        }
        if (epoch == _runEpoch) {
          _scheduleDraftGeneration(customer, newEvidence: true);
        }
      }
      if (!stopped && !yielded && mounted) {
        setState(() => _error = StateError(
            '客户 $customer 转接未完成，已继续准备业务答复；工单和原问题保留。${unconfirmed ? "转接结果仍待核实，不会重复点击。" : ""}阶段：$phase；$error'));
      }
      RuntimeTrace.record('transfer.interrupted', {
        'customer': customer,
        'stopped': stopped,
        'unconfirmed': unconfirmed,
        'errorCode': error is PlatformException
            ? error.code
            : error.runtimeType.toString(),
        'ticketId': ticket.id,
        'phase': phase,
        'attemptId': transferAttemptId,
        'acknowledgementUncertain': acknowledgementUncertain,
        'transferClicked': clickedEvidence,
        'automaticHandoffRetry': false,
        'continueAiAnswer': !stopped,
        'draftAndCursorPreserved': true,
        if (error is PlatformException && error.details is Map)
          'inspection': error.details
      });
      return false;
    } finally {
      if (_transferWorkerEpochs[customer] == epoch) {
        _transferWorkerEpochs.remove(customer);
        _transferringCustomers.remove(customer);
      }
      if (_autoCaptureRunning && epoch == _runEpoch) {
        if (nativeTransferConfirmed) {
          _scheduleDraftGeneration(customer, newEvidence: false);
        }
        _requestDelivery();
      }
      await _coordinator.refresh();
      await _refreshTickets();
      if (mounted) setState(() {});
    }
  }

  bool _runPermissionsReady = false;
  bool _preparingPermissions = false;

  Future<void> _prepareRunPermissions() async {
    if (_preparingPermissions || _autoCaptureRunning || _autoCaptureStarting) {
      return;
    }
    setState(() {
      _preparingPermissions = true;
      _runPermissionsReady = false;
      _error = null;
    });
    try {
      if (!await _prepareDatabaseForAutomation()) return;
      final destination = (await _database.history).mediaDirectory.path;
      final result = await _adapter.prepareRunPermissions(destination);
      if (!mounted) return;
      setState(() {
        _runPermissionsReady = result['ready'] == true;
        _status = {
          ..._status,
          if (result['accessibility'] is bool)
            'trusted': result['accessibility']
        };
        _diagnostics = result['message']?.toString() ??
            (_runPermissionsReady ? '所需权限已就绪，可以开始。' : '授权尚未完成，请允许系统提示后重新检查。');
        if (!_runPermissionsReady) _error = _diagnostics;
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _runPermissionsReady = false;
          _error = '权限准备失败：$error';
        });
      }
    } finally {
      if (mounted) setState(() => _preparingPermissions = false);
    }
  }

  Future<void> _start({DateTime? businessDayBoundary}) async {
    if (_autoCaptureStarting || _exportingReport) return;
    if (_autoCaptureRunning) {
      _runEpoch++;
      final stoppingEpoch = _runEpoch;
      setState(() {
        _autoCaptureRunning = false;
        _autoCaptureStarting = true;
      });
      HostedReplyService.cancelRun(_database, sessionId: _automationSessionId);
      final mediaStopped = ManagedMediaProcesses.shared.cancelRun();
      _reportStopSummary = {
        'mode': 'cancelled_run',
        'localLeasesCancelled': _diagnosticWork.cancelPending(),
        'viewport': _viewportCapturePump.stop(),
        'nativeCancellation': 'requested',
        'serverJobs': 'already_submitted_jobs_may_continue_remotely',
      };
      RuntimeTrace.record('automation.work_cancelled', _reportStopSummary);
      _maintenanceTimer?.cancel();
      _mediaCacheProgressTimer?.cancel();
      _imageOriginalTimer?.cancel();
      for (final c in _activeDraftCancellations.values) {
        c.cancel();
      }
      _draftQueue.clear();
      for (final t in [
        ..._draftRetryTimers.values,
        ..._batchCollectionTimers.values
      ]) {
        t.cancel();
      }
      _draftRetryTimers.clear();
      _batchCollectionTimers.clear();
      try {
        await Future.wait([
          _adapter.setAutomationEpoch(_runEpoch, running: false),
          mediaStopped,
        ]);
        if (!mounted || stoppingEpoch != _runEpoch) return;
        await _database.cancelGenerationLeases();
      } catch (error) {
        RuntimeTrace.record('automation.stop_cleanup_failed',
            {'epoch': stoppingEpoch, 'error': '$error'});
        if (mounted && stoppingEpoch == _runEpoch) {
          setState(() => _error = error);
        }
      }
      if (!mounted || stoppingEpoch != _runEpoch) return;
      _reportRunStoppedAt = DateTime.now();
      RuntimeTrace.record(
          'automation.stopped', {'sessionId': _automationSessionId});
      _autoCaptureTimer?.cancel();
      _unreadSignalTimer?.cancel();
      _redSignalTimer?.cancel();
      for (final timer in _slaPreparationTimers.values) {
        timer.cancel();
      }
      _slaPreparationTimers.clear();
      _activeChatSignalTimer?.cancel();
      _failedSendRetryTimer?.cancel();
      for (final timer in _unreadHoldingTimers.values) {
        timer.cancel();
      }
      for (final timer in _unreadResendTimers.values) {
        timer.cancel();
      }
      for (final timer in _slaFallbackTimers.values) {
        timer.cancel();
      }
      _slaFallbackTimers.clear();
      _deliveryRetryTimer?.cancel();
      _deliveryRequested = false;
      setState(() {
        _autoCaptureRunning = false;
        _autoCaptureStarting = false;
      });
      return;
    }
    if (_autoCaptureStarting ||
        _preparingPermissions ||
        !_settingsLoaded ||
        !_settingsValid) return;
    setState(() => _autoCaptureStarting = true);
    await _settingsWrite;
    _database.configureAutomationSettings(_automationSettings);
    _redClocks.responseTarget = _automationSettings.holdingDelay;
    if (!await _prepareDatabaseForAutomation()) {
      if (mounted) setState(() => _autoCaptureStarting = false);
      return;
    }
    var permissionsCurrent = false;
    try {
      permissionsCurrent =
          _runPermissionsReady && await _adapter.runPermissionsReady();
    } catch (error) {
      RuntimeTrace.record('permissions.start_check_failed',
          {'errorCode': error.runtimeType.toString()});
    }
    if (!permissionsCurrent) {
      if (mounted) {
        setState(() {
          _autoCaptureStarting = false;
          _runPermissionsReady = false;
          _error = '请先点击“授权所需权限”，完成检查后再开始。';
        });
      }
      return;
    }
    if (!mounted) return;
    setState(() {
      _autoCaptureStarting = true;
      _error = null;
      _diagnostics = 'Opening the JD reception window…';
    });
    try {
      await _adapter
          .ensureReceptionWindow(allowActivation: true)
          .timeout(_captureOperationTimeout);
    } catch (error) {
      if (mounted) {
        setState(() {
          _autoCaptureStarting = false;
          _error = error;
          RuntimeTrace.record('ui.error', {'error': '$error'});
        });
      }
      return;
    }
    if (!mounted) return;
    await _refreshCurrentServiceAccount();
    if (!mounted) return;
    _runEpoch++;
    _resetSessionMemory();
    ManagedMediaProcesses.shared.beginRun();
    _reportStopSummary = const {};
    // Automatic midnight rollover owns every message since the new shop day
    // began, including messages received during permission/window checks.
    final startedAt = businessDayBoundary ?? DateTime.now();
    try {
      _automationSessionId = await _database.beginAutomationSession(
          startedAt: startedAt,
          baselineBeforeStartedAtOnly: businessDayBoundary != null);
      _automationSessionStartedAt = startedAt;
      await _evidenceStore.beginSession(
          sessionId: _automationSessionId!, startedAt: startedAt);
      await _coordinator.beginSession(
          sessionId: _automationSessionId!, startedAt: startedAt);
      await _mediaInventory.beginRun(startedAt);
    } catch (error) {
      if (mounted) {
        setState(() {
          _autoCaptureStarting = false;
          _error = error;
        });
      }
      return;
    }
    await RuntimeTrace.flush();
    try {
      _reportTraceStartOffset = await File(RuntimeTrace.path).length();
    } on FileSystemException {
      _reportTraceStartOffset = 0;
    }
    await _adapter.setAutomationEpoch(_runEpoch, running: true);
    setState(() {
      _adapter.resetRowResolution();
      _autoCaptureStarting = false;
      _autoCaptureRunning = true;
      _reportRunStartedAt = startedAt;
      _reportRunStoppedAt = null;
      _reportSettings = _automationSettings;
      RuntimeTrace.record('automation.started', {
        'sessionId': _automationSessionId,
        'startedAt': startedAt.toUtc().toIso8601String(),
        'previousBusinessResumed': false
      });
      _error = null;
      _diagnostics =
          '本轮已开始：只处理新消息。按客户红标计时，${_database.holdingDelay.inSeconds}秒内优先正式答复；仍未就绪时兜底消除红标，原问题继续等待全部解析完成后正式回复。';
    });
    _autoCaptureTimer =
        Timer.periodic(_scanInterval, (_) => unawaited(_runAutoCaptureCycle()));
    // This read-only sidebar poll is intentionally independent of the slower
    // OCR/media capture cycle. A busy video extraction cannot prevent the
    // unread clock from starting for another customer.
    _redSignalTimer = Timer.periodic(
        const Duration(seconds: 1), (_) => unawaited(_pollRedSignals()));
    unawaited(_pollRedSignals());
    _unreadSignalTimer =
        Timer.periodic(_scanInterval, (_) => unawaited(_pollUnreadSignals()));
    final captureEpoch = _runEpoch;
    await _ensureEvidenceRecovered();
    _checkRun(captureEpoch);
    _viewportCapturePump.begin(
        epoch: captureEpoch,
        sessionId: _automationSessionId!,
        directory: await _evidenceDirectory(),
        current: () =>
            mounted && _autoCaptureRunning && captureEpoch == _runEpoch,
        consume: (evidence, snapshot) async {
          _checkRun(captureEpoch);
          try {
            await _registerCapturedViewport(evidence, snapshot,
                epoch: captureEpoch,
                customer: snapshot['requestedCustomer'] as String?,
                historyCutoff: snapshot['historyCutoffMs'] is int
                    ? DateTime.fromMillisecondsSinceEpoch(
                        snapshot['historyCutoffMs']! as int)
                    : null);
          } finally {
            if (_autoCaptureRunning && captureEpoch == _runEpoch) {
              await _refreshViewportCaptureContext(
                  evidence.customer, captureEpoch);
            }
          }
        },
        onError: (error) => RuntimeTrace.record('evidence.capture_failed',
            {'errorCode': error.runtimeType.toString()}));
    _activeChatSignalTimer =
        Timer(Duration.zero, () => unawaited(_pollActiveChatSignal()));
    _maintenanceTimer = Timer.periodic(
        const Duration(seconds: 1), (_) => unawaited(_maintainQueues()));
    _mediaCacheProgressTimer = Timer.periodic(
        widget.mediaCacheProbeIntervalOverride ?? const Duration(seconds: 1),
        (_) => unawaited(_pollMediaCacheProgress()));
    unawaited(_pollMediaCacheProgress());
    unawaited(_maintainQueues());
    unawaited(_pollUnreadSignals());
    unawaited(_pollActiveChatSignal());
    unawaited(_runAutoCaptureCycle());
  }

  void _resetSessionMemory() {
    _imageOriginalTimer?.cancel();
    _imageOriginalTasks.reset();
    _imageOriginalWakeAt = null;
    _originalPageCaptures.reset();
    _originalFrameOcr.reset();
    _originalFrameCrops.reset();
    _originalOcrWrites.reset();
    _timedMatchesInFlight.clear();
    _testedTimedCards.clear();
    _timedMediaWrites.reset();
    _imageOriginalSeeding = false;
    _refinedUnknownBlockKeys.clear();
    _unansweredCounts = null;
    _admissionGapCounts = {};
    _unansweredCountsFailed = false;
    _selectedMessageCustomer = null;
    _selectedMessageRecords = null;
    _messageRecordsRefresh++;
    _messageRecordsLoading = false;
    _messageRecordsFailed = false;
    _workSummaryRefresh++;
    for (final cancellation in _activeDraftCancellations.values) {
      cancellation.cancel();
    }
    for (final timer in [
      ..._draftRetryTimers.values,
      ..._batchCollectionTimers.values,
      ..._unreadHoldingTimers.values,
      ..._unreadResendTimers.values,
      ..._slaFallbackTimers.values,
      ..._slaPreparationTimers.values
    ]) {
      timer.cancel();
    }
    _deliveryRetryTimer?.cancel();
    _draftRetryTimers.clear();
    _batchCollectionTimers.clear();
    _unreadHoldingTimers.clear();
    _unreadResendTimers.clear();
    _slaFallbackTimers.clear();
    _slaTimerPlans.clear();
    _slaPreparationTimers.clear();
    _activeDraftCancellations.clear();
    _activeDraftMessageIds.clear();
    _activeDraftTokens.clear();
    _activeDraftMediaSensitive.clear();
    _activeSocialTurnClocks.clear();
    _activeDraftUsers.clear();
    _draftWorkerEpochs.clear();
    _draftQueue.clear();
    _deliveryRequested = false;
    _deliveryWorkerRunning = false;
    _deliveryWorkerEpoch = null;
    _evidenceWakeRequested = false;
    _registrationWorkers.clear();
    _registrationCustomerWakes.clear();
    _viewportOcrTasks.clear();
    _textFirstOcrPolicy.clear();
    _textFirstProbes.clear();
    _mediaEvidenceWorkers.clear();
    _mediaEvidenceCustomerWakes.clear();
    _mediaEvidenceWakeRequested = false;
    _mediaEvidenceWorkerEpoch = null;
    _registeredEvidenceOcr.clear();
    _evidenceWorkerEpoch = null;
    _evidenceRecovery = null;
    _autoCaptureBusy = false;
    _initialCaptureScanReady = false;
    _completedCaptureScans = 0;
    _passiveBaselineScans.clear();
    _sidebarUnreadSeen.clear();
    _sidebarRedSeen.clear();
    _liveUnreadArrivals.clear();
    _observedCaptureCustomers.clear();
    _verifiedLiveCaptureCustomers.clear();
    _liveArrivalSequence = 0;
    _mediaCacheProgressBusy = false;
    _mediaCacheProgressTimer?.cancel();
    _mediaCacheRevision = null;
    _maintenanceBusy = false;
    _hostedCompletionQueues.clear();
    _hostedCompletionBusy.clear();
    _hostedCompletedJobs.clear();
    _hostedCompletionRetryAt.clear();
    for (final timer in _hostedCompletionTimers.values) {
      timer.cancel();
    }
    _hostedCompletionTimers.clear();
    _completedApiDeliveryCustomers.clear();
    _redSignalBusy = false;
    _unreadSignalBusy = false;
    _activeChatSignalBusy = false;
    _unreadRecovery.clear();
    _mediaAcquisition.clear();
    _startingUnreadRecovery.clear();
    _processingUnreadEvidence.clear();
    _handledUnreadEvidence.clear();
    _handledUnreadAt.clear();
    _handledIncomingSenderKeys.clear();
    _lastUnreadProbeAt.clear();
    _unreadDecisionLog.clear();
    _unreadDecisionAt.clear();
    _rowsWaitingVisibility.clear();
    _anonymousProbeOrder.clear();
    _anonymousProbeSequence = 0;
    _transferringCustomers.clear();
    _transferWorkerEpochs.clear();
    _handoffOwnershipProbeAfter.clear();
    _handoffServiceAlert = null;
    _recoveryNoticeDelegatedEpoch.clear();
    _slaUiDeadlines.clear();
    _slaPreparedCycles.clear();
    _slaPreparedReplies.clear();
    _slaPreparingCustomers.clear();
    _slaDispatchInFlight.clear();
    _nativeSlaAttempts.clear();
    _visualMediaCaptures.clear();
    _evidencePins.clear();
    _pinAttempts.clear();
    _lastPhysicalReplyAt.clear();
    _visibleTransferWelcomes.clear();
    _claimedJdCacheMediaOwners.clear();
    _healthLoggedAt.clear();
    _videoAudioQueue.clear();
    _videoAudioJobs.clear();
    for (final timer in _videoAudioRetryTimers.values) {
      timer.cancel();
    }
    _videoAudioRetryTimers.clear();
    _videoAudioActiveCustomers.clear();
    _videoAudioWorkerBusy = false;
    _videoAudioWorkerEpoch = null;
    _unreadSignals = UnreadSignalTracker();
    _redClocks.beginSession();
  }

  static bool _isOwnHoldingReply(String? body) => isHoldingReply(body);

  OcrExtractionAttempt _analyzeUnreadInspection(
      OcrInspection inspection, UnreadCaptureRecovery? recovery) {
    final strict = const OcrCaptureExtractor().analyze(inspection);
    if (recovery?.useRelaxedBodyOcr(DateTime.now()) != true) return strict;
    final relaxed = const OcrCaptureExtractor(bodyConfidenceThreshold: 0.30)
        .analyze(inspection);
    final latest = relaxed.capture?.messages.reversed
        .where((message) => message.direction == 'incoming')
        .firstOrNull;
    if (latest == null ||
        recovery!.knownIncomingIds.contains(latest.stableId)) {
      return relaxed;
    }
    final strictIds = strict.capture?.messages
            .where((message) => message.direction == 'incoming')
            .map((message) => message.stableId)
            .toSet() ??
        const <String>{};
    if (strictIds.contains(latest.stableId) ||
        recovery.confirmRelaxedBody(latest.body)) {
      return relaxed;
    }
    return strict;
  }

  Future<void> _beginUnreadRecovery(String customer, int evidence,
      {DateTime? detectedAt}) async {
    if (!_autoCaptureRunning) return;
    final epoch = _runEpoch;
    if (_unreadRecovery.containsKey(customer) ||
        !_startingUnreadRecovery.add(customer)) {
      return;
    }
    try {
      final document = await (await _database.history).read(customer);
      final messages = (document?['messages'] as List<Object?>? ?? const [])
          .whereType<Map<String, dynamic>>();
      final eventAt = detectedAt ?? DateTime.now();
      final recovery = UnreadCaptureRecovery(
        customer: customer,
        unreadEvidence: evidence,
        detectedAt: eventAt,
        knownIncomingIds: _incomingIdentitySnapshot(messages),
        knownOutgoingIds: messages
            .where((message) => message['direction'] == 'outgoing')
            .map((message) => message['id']?.toString() ?? '')
            .toSet(),
      );
      if (await _database.isConversationUnavailable(customer)) return;
      if (!_autoCaptureRunning || epoch != _runEpoch) return;
      _unreadRecovery[customer] = recovery;
      _mediaAcquisition[customer] = recovery;
      await _evidenceStore.observe(customer, eventAt);
      RuntimeTrace.record('unread.detected', {
        'customer': customer,
        'detectedAt': eventAt.toUtc().toIso8601String(),
        'observedAt': DateTime.now().toUtc().toIso8601String(),
        'ageMs': DateTime.now().difference(eventAt).inMilliseconds,
      });
      _armUnreadRecoveryTimers(recovery);
    } finally {
      if (epoch == _runEpoch) _startingUnreadRecovery.remove(customer);
    }
  }

  var _unreadSignals = UnreadSignalTracker();
  late final RedClockTracker _redClocks;
  final _unreadDecisionLog = <String, String>{};
  final _unreadDecisionAt = <String, DateTime>{};
  DateTime _unreadDetectedAt(QianniuConversationRow row) =>
      _unreadSignals.detectedAt(row.customer, row.unreadAgeSeconds);

  Future<void> _observePlatformClock(QianniuConversationRow row) async {
    if (!_autoCaptureRunning || !row.evidenceAvailable) return;
    final epoch = _runEpoch;
    final observedAt = row.signalObservedAt ?? DateTime.now();
    try {
      if (await _database.isHumanContacting(row.customer)) {
        _redClocks.observe(row.customer, present: false);
        await _database.observePlatformResponse(row.customer, red: false);
        return;
      }
      final present = row.redClockPresent ?? (row.unreadAgeSeconds != null);
      // A failed screenshot cannot clear an existing clock. An explicit
      // native pill result is independent of whether its digits were readable.
      if (row.redClockPresent == null && row.unreadAgeSeconds == null) {
        return;
      }
      final cycle = await _database.platformResponseCycle(row.customer);
      if (!_autoCaptureRunning || epoch != _runEpoch) return;
      final lastSample = cycle?['observed_at_ms'] as int?;
      final stamp = observedAt.millisecondsSinceEpoch;
      final lastPhysical = _lastPhysicalReplyAt[row.customer];
      if ((lastPhysical != null && !lastPhysical.isBefore(observedAt)) ||
          lastSample != null &&
              (lastSample > stamp ||
                  (lastSample == stamp &&
                      (cycle?['identity_verified'] == 1 ||
                          !row.identityVerified)))) {
        return;
      }
      final previousRed = _sidebarRedSeen[row.customer];
      if (_initialCaptureScanReady &&
          row.redClockPresent == true &&
          previousRed == false) {
        _liveUnreadArrivals[row.customer] =
            'arrival:red-transition:${_automationSessionId!}:${++_liveArrivalSequence}';
      }
      if (row.redClockPresent != null) {
        _sidebarRedSeen[row.customer] = row.redClockPresent!;
      }
      if (present && cycle?['state'] == 'cleared') {
        _redClocks.observe(row.customer, present: false);
      }
      final reading = _redClocks.observe(row.customer,
          present: present,
          ageSeconds: row.unreadAgeSeconds,
          allowCounterReset: cycle?['state'] == 'sent');
      final sampledStart = observedAt.subtract(Duration(
          seconds:
              reading?.calibrated == true ? row.unreadAgeSeconds ?? 0 : 0));
      final start = reading == null
          ? null
          : reading.startedAt.isBefore(sampledStart)
              ? reading.startedAt
              : sampledStart;
      await _database.observePlatformResponse(row.customer,
          red: present,
          observedAt: observedAt,
          ageSeconds: reading?.calibrated == true ? row.unreadAgeSeconds : null,
          startedAt: start,
          clockReset: reading?.counterReset ?? false,
          identityVerified: row.identityVerified);
      final updated = await _database.platformResponseCycle(row.customer);
      final activeHolding = _nativeSlaAttempts[row.customer];
      if (activeHolding != null &&
          activeHolding.epoch == epoch &&
          (updated?['cycle_id'] !=
                  (activeHolding.job.batchStartMessageId ??
                      activeHolding.job.messageId) ||
              updated?['state'] == 'cleared')) {
        unawaited(_yieldNativeHolding(row.customer, activeHolding.attemptId));
      }
      if (_initialCaptureScanReady &&
          present &&
          cycle != null &&
          updated?['state'] == 'waiting' &&
          updated?['cycle_id'] != cycle['cycle_id']) {
        _liveUnreadArrivals[row.customer] =
            'arrival:cycle:${updated!['cycle_id']}';
      }
      if (present &&
          updated?['state'] == 'waiting' &&
          updated?['started_at_ms'] !=
              reading?.startedAt.millisecondsSinceEpoch &&
          (updated?['cycle_id'] != cycle?['cycle_id'] ||
              updated?['started_at_ms'] != cycle?['started_at_ms'])) {
        _redClocks.restartFromEvidence(
            row.customer,
            DateTime.fromMillisecondsSinceEpoch(
                updated!['started_at_ms']! as int));
      }
      if (present) {
        RuntimeTrace.record('sla.red_clock_sample', {
          'customer': row.customer,
          'rawText': row.unreadBadgeText,
          'confidence': row.unreadBadgeConfidence,
          'axAgeSeconds': row.unreadAgeSeconds,
          'elapsedMs': reading?.elapsed.inMilliseconds,
          'clockSource': reading?.reason,
          'calibrated': reading?.calibrated,
          'ageSource': row.unreadAgeSeconds == null ? 'local_monotonic' : 'ax',
          'counterReset': reading?.counterReset
        });
      }
      if (row.identityVerified) await _scheduleSlaFallback(row.customer);
    } catch (error) {
      RuntimeTrace.record('sla.red_clock_observation_failed', {
        'customer': row.customer,
        'errorCode': error.runtimeType.toString()
      });
    }
  }

  void _refreshHandledUnread(QianniuConversationRow row,
      {bool observeClock = true}) {
    final previousUnread = _sidebarUnreadSeen[row.customer];
    if (_initialCaptureScanReady && row.unread && previousUnread != true) {
      _liveUnreadArrivals[row.customer] =
          'arrival:${previousUnread == null ? 'new-row' : 'transition'}:${_automationSessionId!}:${++_liveArrivalSequence}';
    } else if (!row.unread && row.redClockPresent == false) {
      _liveUnreadArrivals.remove(row.customer);
    }
    _sidebarUnreadSeen[row.customer] = row.unread;
    if (observeClock) unawaited(_observePlatformClock(row));
    final handledAt = _handledUnreadAt[row.customer];
    final hadHandled = _handledUnreadEvidence.containsKey(row.customer);
    final decision = _unreadSignals.observe(row.customer,
        unread: row.unread,
        badgeAgeSeconds: row.unreadAgeSeconds,
        handledAt: handledAt);
    if (decision.clearHandled) {
      _handledUnreadEvidence.remove(row.customer);
      _handledUnreadAt.remove(row.customer);
    }
    final outcome = !row.unread
        ? 'no_unread'
        : _unreadRecovery.containsKey(row.customer)
            ? 'recovery_active'
            : _handledUnreadEvidence.containsKey(row.customer)
                ? 'handled_probe_pending'
                : 'recover_new_unread';
    final signature = '$outcome:${decision.reason}:$hadHandled';
    final at = DateTime.now();
    if (_unreadDecisionLog[row.customer] != signature ||
        at.difference(_unreadDecisionAt[row.customer] ?? DateTime(1970)) >=
            const Duration(seconds: 10)) {
      _unreadDecisionLog[row.customer] = signature;
      _unreadDecisionAt[row.customer] = at;
      RuntimeTrace.record('unread.signal_decision', {
        'customer': row.customer,
        'rowKey': row.rowKey,
        'unread': row.unread,
        'previousUnread': decision.previousUnread,
        'badgeAgeSeconds': row.unreadAgeSeconds,
        'reason': decision.reason,
        'outcome': outcome,
        'hadHandled': hadHandled,
        'handledCleared': hadHandled && decision.clearHandled,
        'handledAt': handledAt?.toUtc().toIso8601String(),
        'detectedAt': decision.detectedAt?.toUtc().toIso8601String(),
        'probeDue': _unreadSignals.needsProbe(
            row.customer, _handledUnreadAt[row.customer]),
        'answeredCursorCheck': 'on_capture_or_delivery',
      });
    }
  }

  bool _isMissingConversation(Object error) =>
      error is PlatformException &&
      const {
        'conversation_not_found',
        'conversation_verification_failed',
        'conversation_changed',
        'customer_not_receiving',
        'send_platform_rejected'
      }.contains(error.code);

  Future<void> _suspendMissingConversation(
      String customer, Object error) async {
    if (error is PlatformException && error.details is Map) {
      final fingerprint = (error.details as Map)['rejectedFingerprint'];
      if (fingerprint is String) {
        await _database.ownFailedOutgoing(customer, fingerprint);
      }
    }
    await _database.suspendUnavailableConversation(customer, error.toString());
    _slaFallbackTimers.remove(customer)?.cancel();
    _unreadHoldingTimers.remove(customer)?.cancel();
    _unreadResendTimers.remove(customer)?.cancel();
    // A new sighting starts a fresh recovery from its real badge clock.
    // Pending drafts and their original SLA rows remain durable in SQLite.
    _unreadRecovery.remove(customer);
    _handledUnreadEvidence.remove(customer);
    _handledUnreadAt.remove(customer);
    _processingUnreadEvidence.remove(customer);
    _lastUnreadProbeAt.remove(customer);
    RuntimeTrace.record('conversation.suspended', {
      'customer': customer,
      'nextProbeAfterMs': 3000,
      'draftAndOriginalDeadlinePreserved': true,
      'reason': error is PlatformException
          ? error.code
          : error.runtimeType.toString(),
    });
  }

  Future<void> _resumeVisibleConversations(Iterable<String> customers,
      {Iterable<String> verifiedActive = const [],
      Iterable<String> deliveryReady = const []}) async {
    final resumed = await _database.resumeVisibleConversations(customers,
        verifiedActive: verifiedActive, deliveryReady: deliveryReady);
    for (final customer in resumed) {
      RuntimeTrace.record('conversation.resumed', {'customer': customer});
      if (_unreadRecovery[customer] case final recovery?) {
        _armUnreadRecoveryTimers(recovery);
      }
      _scheduleDraftGeneration(customer, newEvidence: false);
      unawaited(_scheduleSlaFallback(customer));
    }
    if (resumed.isNotEmpty) _requestDelivery();
  }

  final _anonymousProbeOrder = <String, int>{};
  int _anonymousProbeSequence = 0;
  Future<void> _probeUnavailableConversations(
      List<QianniuConversationRow> rows) async {
    final epoch = _runEpoch;
    final blocked =
        (await _database.historyFaults()).map((r) => r['user_id']).toSet();
    final outstanding =
        (await _database.outstandingCustomers()).difference(blocked);
    final reconciliation = (await _database.reconciliationWork())
        .where((r) => r['blocksCustomer'] != false)
        .map((r) => r['user_id'])
        .toSet();
    for (final row in rows.where((r) =>
        r.identityVerified && (r.unread || outstanding.contains(r.customer)))) {
      if (!_autoCaptureRunning ||
          (blocked.contains(row.customer) ||
              await _database.isHumanContacting(row.customer))) {
        continue;
      }
      if (reconciliation.contains(row.customer) &&
          !await _database.isConversationUnavailable(row.customer)) {
        await _database.suspendUnavailableConversation(
            row.customer, 'send_unconfirmed: reconciliation_required');
      }
      final lease = await _database.claimUnavailableProbe(row.customer);
      if (lease == null) continue;
      final fields = <String, Object?>{
        'customer': row.customer,
        'attempt': lease['probe_attempts'],
        'nextProbeAtMs': lease['next_probe_at_ms'],
        'originalDeadlineMs': lease['original_deadline_ms'],
        'suspendedAtMs': lease['failed_at_ms']
      };
      RuntimeTrace.record('conversation.probe_started', fields);
      try {
        await _withJdUiOperation(() async {
          _checkRun(epoch);
          await _adapter.openConversation(row.customer, allowActivation: true);
          _checkRun(epoch);
          await _adapter.checkDeliveryReadiness(row.customer);
          _checkRun(epoch);
          if (reconciliation.contains(row.customer)) {
            // Capture for asynchronous receipt reconciliation, never before a
            // normal generated send. A readiness check alone is not a receipt.
            await _captureViewport(customer: row.customer, hasUiLease: true);
            await _database.reconcileOrphanSla(row.customer);
            RuntimeTrace.record('conversation.reconciliation_probe', fields);
            return;
          }
          if (!_autoCaptureRunning) return;
          await _resumeVisibleConversations([row.customer],
              verifiedActive: [row.customer], deliveryReady: [row.customer]);
          RuntimeTrace.record('conversation.probe_confirmed', fields);
        });
      } catch (error) {
        RuntimeTrace.record('conversation.probe_failed', {
          ...fields,
          'errorCode': error is PlatformException
              ? error.code
              : error.runtimeType.toString()
        });
      }
      // One bounded UI probe per poll; other customers' deadline work stays ahead.
      return;
    }
    // A restart loses in-memory row aliases. Real retained work, not a red
    // badge alone, authorizes one bounded discovery. Never send to its index.
    final unresolved = outstanding
        .where((id) => !rows.any((r) => r.identityVerified && r.customer == id))
        .toSet();
    if (unresolved.isEmpty || !_autoCaptureRunning || epoch != _runEpoch) {
      return;
    }
    final candidates = rows.toList()
      ..sort((a, b) => (_anonymousProbeOrder[a.rowKey] ?? 0)
          .compareTo(_anonymousProbeOrder[b.rowKey] ?? 0));
    if (_anonymousProbeOrder.length > 200) {
      final visible = rows.map((r) => r.rowKey).toSet();
      _anonymousProbeOrder.removeWhere((key, _) => !visible.contains(key));
    }
    for (final row in candidates) {
      if (row.identityVerified ||
          row.rowKey == null ||
          row.rowToken == null ||
          !_adapter.rowResolutionDue(row.customer)) {
        continue;
      }
      if (!_autoCaptureRunning || epoch != _runEpoch) return;
      _anonymousProbeOrder[row.rowKey!] = ++_anonymousProbeSequence;
      try {
        await _withJdUiOperation(() async {
          _checkRun(epoch);
          RuntimeTrace.record('identity.outstanding_probe_started', {
            'observedRow': row.customer,
            'rowKey': row.rowKey,
            'targetCustomers': unresolved.toList(),
            'reason': 'durable_work_without_bound_row'
          });
          await _adapter.openConversation(row.customer, allowActivation: true);
          _checkRun(epoch);
          final actual = _adapter.verifiedCustomerIdentity(row.customer);
          if (MacOSCaptureAdapter.isProvisionalIdentity(actual)) return;
          RuntimeTrace.record('identity.outstanding_probe_bound', {
            'observedRow': row.customer,
            'customer': actual,
            'needed': unresolved.contains(actual)
          });
          if (!unresolved.contains(actual) ||
              await _database.isHumanContacting(actual)) {
            return;
          }
          await _adapter.checkDeliveryReadiness(actual);
          _checkRun(epoch);
          if (reconciliation.contains(actual)) {
            await _captureViewport(customer: actual, hasUiLease: true);
            await _database.reconcileOrphanSla(actual);
          } else {
            await _resumeVisibleConversations([actual],
                verifiedActive: [actual], deliveryReady: [actual]);
            _requestDelivery();
          }
        });
      } catch (error) {
        RuntimeTrace.record('identity.outstanding_probe_failed', {
          'observedRow': row.customer,
          'errorCode': error is PlatformException
              ? error.code
              : error.runtimeType.toString()
        });
      }
      return;
    }
  }

  /// AX/colour-only signal reads have their own native queue, never acquire
  /// the UI lease and remain active while another customer is being sent.
  Future<void> _pollRedSignals() async {
    final releaseDiagnosticWork = _diagnosticWork.acquire();
    try {
      if (!_autoCaptureRunning || _redSignalBusy) return;
      _redSignalBusy = true;
      final epoch = _runEpoch;
      final elapsed = Stopwatch()..start();
      try {
        // The adapter already shares one native sidebar read. A Dart timeout
        // cannot cancel it; discarding its eventual result can lose the only
        // red snapshot during a burst. Keep this poll busy until it completes.
        final rows = await _adapter.listConversationRows();
        if (!_autoCaptureRunning || epoch != _runEpoch) return;
        for (final row in rows) {
          if (!_autoCaptureRunning || epoch != _runEpoch) return;
          await _observePlatformClock(row);
        }
        RuntimeTrace.record('sla.monitor_completed', {
          'elapsedMs': elapsed.elapsedMilliseconds,
          'rows': rows.length,
          'uiBusy': _pendingJdUiOperations > 0 || _priorityUiOperations > 0
        });
      } catch (error) {
        RuntimeTrace.record(
            'sla.monitor_failed', {'errorCode': error.runtimeType.toString()});
      } finally {
        if (epoch == _runEpoch) _redSignalBusy = false;
      }
    } finally {
      releaseDiagnosticWork();
    }
  }

  Future<void> _pollUnreadSignals() async {
    final releaseDiagnosticWork = _diagnosticWork.acquire();
    try {
      if (!_autoCaptureRunning ||
          _unreadSignalBusy ||
          _pendingJdUiOperations > 0 ||
          _priorityUiOperations > 0) {
        return;
      }
      _unreadSignalBusy = true;
      final epoch = _runEpoch;
      try {
        final rows = await _adapter
            .listConversationRows()
            .timeout(_unreadOperationTimeout);
        if (!_autoCaptureRunning || epoch != _runEpoch) return;
        await _resumeVisibleConversations(
            rows
                .where((row) => row.unread && row.identityVerified)
                .map((row) => _adapter.verifiedCustomerIdentity(row.customer)),
            verifiedActive: rows
                .where((row) => row.identitySource == 'active_ax')
                .map((row) => row.customer));
        if (_pendingJdUiOperations == 0 && _priorityUiOperations == 0) {
          await _probeUnavailableConversations(rows);
        }
        for (final row in rows) {
          if (!_autoCaptureRunning || epoch != _runEpoch) return;
          _refreshHandledUnread(row);
          if (!row.unread) {
            continue;
          }
          if (_unreadRecovery[row.customer] case final recovery?) {
            // A real new unread transition or fresh AX proof can reopen a paused
            // locator. Resume its original clock, including foreground recovery.
            if (_adapter.rowResolutionDue(row.customer)) {
              _armUnreadRecoveryTimers(recovery);
            }
            continue;
          }
          if (_handledUnreadEvidence.containsKey(row.customer) ||
              await _database.isHumanContacting(row.customer)) {
            continue;
          }
          await _beginUnreadRecovery(row.customer, row.unreadEvidence,
              detectedAt: _unreadDetectedAt(row));
        }
      } catch (_) {
        // The capture cycle continues to inspect the active chat even if a
        // transient sidebar read fails. The next signal poll retries.
      } finally {
        if (epoch == _runEpoch) _unreadSignalBusy = false;
      }
    } finally {
      releaseDiagnosticWork();
    }
  }

  /// A selected JD row may not expose an unread flag. Observe its verified
  /// sender clock independently of the slow full capture/media cycle so the
  /// 20-second deadline starts even when content extraction fails.
  Future<Directory> _evidenceDirectory() async =>
      Directory('${(await _database.storageRoot).path}/capture_evidence');

  Future<void> _ensureEvidenceRecovered() => _evidenceRecovery ??= () async {
        final directory = await _evidenceDirectory();
        await directory.create(recursive: true);
        // A new Start is not recovery of the previous business session.
        // beginSession retained its files in the archive; only new records
        // can enter this run's evidence queue.
      }();

  Future<ViewportEvidence?> _captureViewport(
      {String? customer,
      DateTime? historyCutoff,
      bool hasUiLease = false,
      bool verifiedLiveBottom = false,
      bool fastSampling = false}) async {
    if (!_autoCaptureRunning) return null;
    if (customer == null &&
        historyCutoff == null &&
        !_initialCaptureScanReady) {
      return null;
    }
    final epoch = _runEpoch;
    final sessionId = _automationSessionId;
    if (!_viewportCapturePump.current(epoch)) return null;
    if (!fastSampling &&
        customer != null &&
        (historyCutoff != null ||
            !_viewportCapturePump.freezeContexts().containsKey(customer))) {
      await _refreshViewportCaptureContext(customer, epoch,
          includeHistoryWork: historyCutoff != null);
    }
    _checkRun(epoch);
    // Copy every authorization source before native capture starts. In
    // particular, a customer/arrival discovered after this point belongs only
    // to a later frame, even when raw registration is delayed by SQLite/OCR.
    final contexts = _viewportCapturePump.freezeContexts();
    final arrivals = Map<String, String>.from(_liveUnreadArrivals);
    final recoveryCustomers = _unreadRecovery.keys.toSet();
    final verifiedCustomers = _verifiedLiveCaptureCustomers.toSet();
    final scans = _completedCaptureScans;
    final cutoffs =
        Map<String, int>.from(_viewportCapturePump.navigationCutoffs);
    final directory = _viewportCapturePump.captureDirectory;
    if (directory == null) return null;
    var evidence = await _viewportCapturePump.capture(
        wait: !fastSampling,
        current: () => _autoCaptureRunning && mounted && epoch == _runEpoch,
        native: () => _adapter.captureViewportEvidence(
            expectedCustomer: customer,
            automationSessionId: sessionId,
            directory: directory.path,
            historyCutoff: historyCutoff,
            historyCutoffs: cutoffs));
    _checkRun(epoch);
    if (evidence == null) return null;
    final context = contexts[evidence.customer];
    final needsBaseline = context?['hasDiscoveryAnchor'] != true;
    final firstScan = needsBaseline
        ? _passiveBaselineScans.putIfAbsent(evidence.customer, () => scans)
        : scans;
    final snapshot = <String, Object?>{
      'epoch': epoch,
      'sessionId': sessionId,
      'context': context,
      'liveArrival': arrivals[evidence.customer],
      'recoveryActive': recoveryCustomers.contains(evidence.customer),
      'verifiedCustomer': verifiedCustomers.contains(evidence.customer),
      'passiveBaselineReady': needsBaseline && scans > firstScan,
      'requestedCustomer': customer,
      'historyCutoffMs': historyCutoff?.millisecondsSinceEpoch,
    };
    evidence = ViewportEvidence({
      ...evidence.metadata,
      'automationSessionId': sessionId,
      'automationSessionStartedAtMs':
          _automationSessionStartedAt?.millisecondsSinceEpoch,
      if (verifiedLiveBottom && historyCutoff == null)
        'verifiedLiveBottom': true,
      if (arrivals[evidence.customer] case final arrival?)
        'unreadArrivalKey': arrival,
      if (historyCutoff != null)
        'historyCutoffMs': historyCutoff.millisecondsSinceEpoch,
    });
    _observedCaptureCustomers.add(evidence.customer);
    if (fastSampling) {
      await _viewportCapturePump.save(epoch, evidence, snapshot);
      _checkRun(epoch);
      return evidence;
    }
    try {
      return await _registerCapturedViewport(evidence, snapshot,
          epoch: epoch,
          customer: customer,
          historyCutoff: historyCutoff,
          hasUiLease: hasUiLease);
    } finally {
      if (_autoCaptureRunning && epoch == _runEpoch) {
        await _refreshViewportCaptureContext(evidence.customer, epoch);
      }
    }
  }

  Future<void> _refreshViewportCaptureContext(String customer, int epoch,
      {bool includeHistoryWork = false}) async {
    _checkRun(epoch);
    final revision = DateTime.now().microsecondsSinceEpoch;
    final observedArrival = _liveUnreadArrivals[customer];
    final cycle = await _database.platformResponseCycle(customer);
    final durable = await _database.hasPendingUnanswered(customer);
    final frontier = await _mediaConversationFrontier(customer);
    final acquisitions = await _mediaInventory.pendingMediaForTask(customer);
    final keys = <String>{
      for (final item in acquisitions) ...{
        if (item['receiptId'] is String) item['receiptId']! as String,
        if (item['messageId'] is String) item['messageId']! as String,
        ...(item['aliases'] as List? ?? const []).whereType<String>(),
      }
    };
    final onlyAcquisition = !durable ||
        (includeHistoryWork &&
            (await _database.processingMessages(customer))
                .where((m) => m['direction'] == 'incoming')
                .every((m) => <String>{
                      m['id']! as String,
                      ...(m['observed_ids'] as List? ?? const [])
                          .whereType<String>()
                    }.intersection(keys).isNotEmpty));
    final anchored = await _evidenceStore.hasDiscoveryAnchor(customer);
    final cutoffs = await _evidenceStore.restoreCutoffs();
    _checkRun(epoch);
    _viewportCapturePump.navigationCutoffs = {
      for (final entry in cutoffs.entries) entry.key: entry.value
    };
    _viewportCapturePump.cacheContext(epoch, customer, revision, {
      'cycle': cycle == null
          ? null
          : {
              for (final key in [
                'state',
                'cycle_id',
                'identity_verified',
                'started_at_ms'
              ])
                if (cycle.containsKey(key)) key: cycle[key]
            },
      'durable': durable,
      'hasDiscoveryAnchor': anchored,
      'observedArrival': observedArrival,
      'frontier': frontier == null
          ? null
          : {
              for (final key in [
                'id',
                'observed_ids',
                'sent_at',
                'body',
                'direction',
                'empty',
                'visibleTextAnchors'
              ])
                if (frontier.containsKey(key)) key: frontier[key]
            },
      'acquisitions': [
        for (final item in acquisitions)
          {
            for (final key in ['receiptId', 'messageId', 'aliases'])
              if (item.containsKey(key)) key: item[key]
          }
      ],
      'onlyAcquisitionWork': onlyAcquisition,
    });
  }

  Future<ViewportEvidence?> _registerCapturedViewport(
      ViewportEvidence evidence, Map<String, Object?> snapshot,
      {required int epoch,
      String? customer,
      DateTime? historyCutoff,
      bool hasUiLease = false}) async {
    final releaseDiagnosticWork = _diagnosticWork.acquire();
    try {
      _checkRun(epoch);
      if (snapshot['epoch'] != epoch ||
          snapshot['sessionId'] != _automationSessionId ||
          evidence.metadata['automationSessionId'] != _automationSessionId) {
        throw const _AutomationStopped();
      }
      final context = captureContextFromFrozenSnapshot(snapshot);
      if (context == null) {
        final observation = ViewportEvidence({
          ...evidence.metadata,
          'replyActivationAllowed': false,
          'capturePurpose': 'arrival_observation'
        });
        await _evidenceStore.record(observation);
        _checkRun(epoch);
        unawaited(_drainEvidenceInbox());
        return observation;
      }
      final cycle = context['cycle'] as Map?;
      if (historyCutoff == null &&
          cycle?['state'] == 'waiting' &&
          cycle?['identity_verified'] == 1 &&
          snapshot['verifiedCustomer'] != true) {
        final actual = evidence.customer;
        final observed = ViewportEvidence({
          ...evidence.metadata,
          'replyActivationAllowed': false,
          'capturePurpose': 'arrival_observation',
        });
        await _evidenceStore.record(observed);
        _checkRun(epoch);
        // This older frame stays observational even if a later frame already
        // completed the guarded navigation. Never promote it using later state.
        if (_verifiedLiveCaptureCustomers.contains(actual)) return observed;
        Future<ViewportEvidence?> prepareCurrent() async {
          _checkRun(epoch);
          await _adapter.openConversation(actual, allowActivation: false);
          await _adapter.scrollConversation(
              expectedCustomer: actual, deltaY: -10000);
          _checkRun(epoch);
          _liveUnreadArrivals.putIfAbsent(actual,
              () => 'arrival:verified-current:$_automationSessionId:$actual');
          _verifiedLiveCaptureCustomers.add(actual);
          return _captureViewport(
              customer: actual, hasUiLease: true, verifiedLiveBottom: true);
        }

        return hasUiLease
            ? await prepareCurrent()
            : await _withJdUiOperation(prepareCurrent,
                priority: JdUiPriority.responseDeadline);
      }
      final live = cycle?['state'] == 'waiting' ||
          snapshot['recoveryActive'] == true ||
          (snapshot['liveArrival'] != null &&
              snapshot['liveArrival'] != context['observedArrival']);
      final durable = context['durable'] == true;
      // Freeze the admission boundary with these pixels. A new AX-owned frame
      // can be registered ahead of old recovery work without moving the boundary
      // underneath an older frame that still contains an unseen real message.
      final admissionFrontier = context['frontier'] as Map?;
      final acquisitions = (context['acquisitions'] as List? ?? const [])
          .whereType<Map>()
          .toList();
      final acquisition = acquisitions.isNotEmpty;
      if (customer == null &&
          historyCutoff == null &&
          !live &&
          !durable &&
          !acquisition &&
          context['hasDiscoveryAnchor'] != true &&
          snapshot['passiveBaselineReady'] != true) {
        final observation = ViewportEvidence({
          ...evidence.metadata,
          'replyActivationAllowed': false,
          'capturePurpose': 'arrival_observation'
        });
        await _evidenceStore.record(observation);
        return observation;
      }
      _passiveBaselineScans.remove(evidence.customer);
      final onlyAcquisitionWork = historyCutoff != null &&
          !live &&
          acquisition &&
          context['onlyAcquisitionWork'] == true;
      _checkRun(epoch);
      evidence = ViewportEvidence({
        ...evidence.metadata,
        'admissionFrontier': admissionFrontier == null
            ? null
            : {
                for (final key in [
                  'id',
                  'observed_ids',
                  'sent_at',
                  'body',
                  'direction',
                  'empty',
                  'visibleTextAnchors'
                ])
                  if (admissionFrontier.containsKey(key))
                    key: admissionFrontier[key],
              },
        'captureRequestedBackfill': historyCutoff != null,
        'navigationCutoffSource': historyCutoff != null
            ? 'requested_backfill'
            : evidence.metadata['historyCutoffMs'] != null
                ? 'restore_pending'
                : 'current_viewport',
        'replyActivationAllowed': live || durable || acquisition,
        if (acquisition) 'mediaAcquisitionPending': true,
        if (onlyAcquisitionWork) ...{
          'acquisitionOnly': true,
          'acquisitionInputKeys': [
            ...{
              for (final item in acquisitions) ...<String>{
                if (item['receiptId'] case final String receipt) receipt,
                if (item['messageId'] case final String message) message,
                ...(item['aliases'] as List? ?? const []).whereType<String>(),
              }
            }
          ],
        },
        'capturePurpose': historyCutoff != null
            ? 'history_backfill'
            : live
                ? 'live_signal'
                : durable
                    ? 'durable_unanswered'
                    : 'history_only',
      });
      await _resumeVisibleConversations([evidence.customer],
          verifiedActive: [evidence.customer]);
      if (await _database.isHumanContacting(evidence.customer)) return null;
      final bool inserted;
      if (historyCutoff == null) {
        final discovery = await _evidenceStore.discoveryCapture(evidence,
            hasLiveWork: live,
            hasPendingWork: durable,
            acquisition: acquisition);
        evidence = discovery.evidence;
        inserted = discovery.inserted;
      } else {
        inserted = await _evidenceStore.record(evidence);
      }
      _checkRun(epoch);
      final recovery = _unreadRecovery[evidence.customer] ??
          _mediaAcquisition[evidence.customer];
      // A selected customer can have a real AX red clock without an unread
      // flag. Pin its original immediately, without creating another recovery
      // task or changing the response clock while OCR is still pending.
      final redStartedMs = cycle?['started_at_ms'] as int?;
      final pinRecovery = recovery ??
          (historyCutoff == null &&
                  cycle?['state'] == 'waiting' &&
                  cycle?['identity_verified'] == 1 &&
                  !MacOSCaptureAdapter.isProvisionalIdentity(
                      evidence.customer) &&
                  redStartedMs != null
              ? UnreadCaptureRecovery(
                  customer: evidence.customer,
                  unreadEvidence: 0,
                  detectedAt: DateTime.fromMillisecondsSinceEpoch(redStartedMs),
                  knownIncomingIds: <String>{},
                  knownOutgoingIds: <String>{})
              : null);
      final previousPin = _pinAttempts[evidence.id];
      if (pinRecovery != null &&
          evidence.metadata['historyCutoffMs'] == null &&
          !_evidencePins.containsKey(evidence.id) &&
          (await _evidenceStore.lookup(evidence.id))?.pinnedMedia == null &&
          (previousPin == null ||
              (previousPin.$1 < 3 &&
                  DateTime.now().difference(previousPin.$2) >=
                      const Duration(seconds: 3)))) {
        _pinAttempts[evidence.id] =
            ((previousPin?.$1 ?? 0) + 1, DateTime.now());
        if (_pinAttempts.length > 500) {
          _pinAttempts.remove(_pinAttempts.keys.first);
        }
        if (recovery == null) {
          RuntimeTrace.record('media.red_clock_pin_requested', {
            'customer': evidence.customer,
            'evidenceId': evidence.id,
            'cycleId': cycle?['cycle_id'],
            'startedAtMs': redStartedMs,
            'createsBusinessTask': false
          });
        }
        final pin = _pinEvidenceOriginal(evidence, pinRecovery);
        _evidencePins[evidence.id] = pin;
        unawaited(pin.whenComplete(() {
          if (epoch == _runEpoch &&
              identical(_evidencePins[evidence.id], pin)) {
            _evidencePins.remove(evidence.id);
          }
        }));
      }
      if (!inserted) return evidence;
      RuntimeTrace.record('evidence.captured', {
        'customer': evidence.customer,
        'evidenceId': evidence.id,
        'capturedAt': evidence.capturedAt.toIso8601String(),
        'historyCutoffMs': evidence.metadata['historyCutoffMs']
      });
      if (mounted) {
        setState(() => _diagnostics = '${evidence.customer} 的画面已保存，后台提取中。');
      }
      _startViewportOcr(evidence);
      unawaited(_drainEvidenceInbox());
      return evidence;
    } finally {
      releaseDiagnosticWork();
    }
  }

  Future<void> _pinEvidenceOriginal(
      ViewportEvidence evidence, UnreadCaptureRecovery recovery) async {
    final epoch = _runEpoch;
    try {
      final store = await _database.history;
      final destination = Directory(
          '${store.mediaDirectory.path}/${store.safeUserId(evidence.customer)}/videos');
      await destination.create(recursive: true);
      final media = await _adapter
          .captureRecentCachedMedia(
              expectedCustomer: evidence.customer,
              expectedMediaAt: recovery.detectedAt,
              destinationDirectory: destination.path)
          .timeout(const Duration(seconds: 2));
      if (!_autoCaptureRunning || epoch != _runEpoch) return;
      final redClockCompetitors = <String, UnreadCaptureRecovery>{};
      if (media != null) {
        final rows = await (await _database.database).query(
            'platform_response_cycles',
            where: "state='waiting' AND identity_verified=1");
        if (!_autoCaptureRunning || epoch != _runEpoch) return;
        for (final row in rows) {
          final customer = row['user_id']! as String;
          if (MacOSCaptureAdapter.isProvisionalIdentity(customer)) continue;
          redClockCompetitors[customer] = UnreadCaptureRecovery(
              customer: customer,
              unreadEvidence: 0,
              detectedAt: DateTime.fromMillisecondsSinceEpoch(
                  row['started_at_ms']! as int),
              knownIncomingIds: <String>{},
              knownOutgoingIds: <String>{});
        }
      }
      if (media != null &&
          _claimDirectCachedMedia(evidence.customer, recovery, media,
              additionalRecoveries: redClockCompetitors)) {
        final values = <String, Object?>{
          'kind': media.kind,
          'cacheKey': media.cacheKey,
          'cacheModifiedAtMs': media.cacheModifiedAt.millisecondsSinceEpoch
        };
        if (media.image case final image?) {
          if (image.bytes != null) {
            final file = File(
                '${(await _evidenceDirectory()).path}/${evidence.id}.original');
            await file.writeAsBytes(image.bytes!, flush: true);
            values.addAll({
              'evidenceFile': file.path,
              'mimeType': image.mimeType,
              'extension': image.extension,
              'originalName': image.originalName,
              'visualFingerprint': image.visualFingerprint,
              'captureSource': 'jd-image-cache'
            });
          }
        } else if (media.video case final video?) {
          values.addAll({
            'path': video.path,
            'originalName': video.originalName,
            'mimeType': video.mimeType
          });
        }
        evidence = evidence.withPinnedMedia(values);
        await _evidenceStore.pin(evidence);
        await _evidenceStore.wakePinnedMedia(evidence);
        unawaited(_drainEvidenceInbox());
        unawaited(_drainEvidenceInbox(mediaOnly: true));
      }
    } catch (error) {
      RuntimeTrace.record('evidence.original_deferred', {
        'customer': evidence.customer,
        'errorCode': error is PlatformException
            ? error.code
            : error.runtimeType.toString()
      });
    }
  }

  Future<void> _requestImageOriginal(
      String customer, String receipt, DateTime senderAt,
      {ViewportEvidence? initialFrame, bool confirmedImage = false}) async {
    final session = _automationSessionId;
    final epoch = _runEpoch;
    if (!_autoCaptureRunning || session == null) return;
    final parent = await _mediaInventory.resolveParent(customer,
        receiptId: receipt, requireCurrentSession: true);
    if (parent == null) return;
    final boundAt =
        await _mediaInventory.recordedSenderTime(customer, parent.receiptId);
    if (!_autoCaptureRunning ||
        epoch != _runEpoch ||
        boundAt == null ||
        !CustomerMessageTime.sameSecond(boundAt, senderAt)) {
      return;
    }
    if (!await _database.isIncompleteImageAcquisitionAllowed(
        customer, parent.messageId)) {
      return;
    }
    if (!_autoCaptureRunning ||
        _runEpoch != epoch ||
        _automationSessionId != session) {
      return;
    }
    _imageOriginalTasks.enqueue(
        customer: customer,
        messageId: parent.messageId,
        receiptId: parent.receiptId,
        senderAt: boundAt,
        sessionId: session,
        epoch: epoch,
        initialFrame: initialFrame,
        confirmedImage: confirmedImage);
    _armImageOriginalWork(Duration.zero);
  }

  void _armImageOriginalWork([Duration delay = const Duration(seconds: 1)]) {
    if (!_autoCaptureRunning || !_imageOriginalTasks.hasRunnableTasks) return;
    final due = DateTime.now().add(delay);
    if (_imageOriginalWakeAt case final current? when !due.isBefore(current)) {
      return;
    }
    _imageOriginalTimer?.cancel();
    _imageOriginalWakeAt = due;
    _imageOriginalTimer = Timer(delay, () {
      _imageOriginalWakeAt = null;
      _runImageOriginalWork();
    });
  }

  Future<OcrInspection> _inspectOriginalFrame(
      ImageOriginalTask task, ViewportEvidence frame) async {
    final inspection =
        await _originalFrameOcr.run((task.epoch, frame.id), () async {
      final existing = _registeredEvidenceOcr[frame.id];
      if (existing?.physicalMediaRegions != null) return existing!;
      return await _readRegisteredEvidenceOcr(frame) ??
          await _adapter.inspectViewportEvidence(frame, mediaRecognition: true);
    });
    // Share even a reused OCR result: another pending message may now own a
    // different complete card on this same immutable page.
    unawaited(_sharePendingMediaFrame(frame, inspection, task.epoch));
    return inspection;
  }

  Future<void> _sharePendingMediaFrame(
      ViewportEvidence source, OcrInspection inspection, int epoch) async {
    final releaseDiagnosticWork = _diagnosticWork.acquire();
    try {
      try {
        final session = _automationSessionId;
        if (!_autoCaptureRunning ||
            epoch != _runEpoch ||
            session == null ||
            source.metadata['automationSessionId'] != session ||
            inspection.activeCustomerId != source.customer) return;
        final pending =
            await _mediaInventory.pendingMediaForTask(source.customer);
        _checkRun(epoch);
        final cards = ExactTimedMedia.forPending(source, inspection, [
          for (final item in pending)
            if (item['senderAt'] case final DateTime at) at,
        ]);
        if (cards.isEmpty) return;
        final allowed = <String>{
          for (final item in pending) ...{
            if (item['messageId'] case final String id) id,
            if (item['receiptId'] case final String id) id,
          },
        };
        final frame = ViewportEvidence({
          ...source.metadata,
          'acquisitionOnly': true,
          'replyActivationAllowed': true,
          'acquisitionInputKeys': allowed.toList(),
        });
        // Recovery pages used to disappear after serving their requesting task.
        // Retain immutable pixels and OCR so other pending messages can reuse it.
        if (await _evidenceStore.lookup(frame.id) == null) {
          await _evidenceStore.record(frame);
        }
        _checkRun(epoch);
        await _originalOcrWrites.run(
            (epoch, frame.id),
            () => _recordOcrEvidence(frame, inspection,
                const OcrCaptureExtractor().analyze(inspection)));
        _checkRun(epoch);
        _startExactTimedMatches(frame, inspection, epoch, registeredCards: {
          for (final card in cards) card.region: card.sentAt,
        });
      } on _AutomationStopped {
        // A previous run cannot publish into the next run.
      } catch (error) {
        RuntimeTrace.record('media.shared_frame_deferred', {
          'customer': source.customer,
          'evidenceId': source.id,
          'errorCode': error is PlatformException
              ? error.code
              : error.runtimeType.toString(),
        });
      }
    } finally {
      releaseDiagnosticWork();
    }
  }

  Future<VisibleImagePayload> _matchOriginalFrame(
      ViewportEvidence frame, OcrVisualRegion region, DateTime? senderAt) {
    final epoch = _runEpoch;
    final key = (
      epoch,
      frame.id,
      region.x,
      region.y,
      region.width,
      region.height,
      senderAt?.millisecondsSinceEpoch
    );
    return _originalFrameCrops.run(key, () async {
      _checkRun(epoch);
      final store = await _database.history;
      _checkRun(epoch);
      return _adapter.cropViewportEvidence(frame, region,
          expectedMediaAt: senderAt,
          destinationDirectory:
              '${store.mediaDirectory.path}/${store.safeUserId(frame.customer)}/videos');
    });
  }

  Future<void> _seedImageOriginalTasks(int epoch) async {
    final releaseDiagnosticWork = _diagnosticWork.acquire();
    try {
      if (_imageOriginalSeeding) return;
      _imageOriginalSeeding = true;
      try {
        for (final customer in await _database.pendingHealth()) {
          _checkRun(epoch);
          final id = customer['user_id']! as String;
          for (final row in await _mediaInventory.pendingMediaForTask(id)) {
            if (!const {'image', 'unknown'}.contains(row['kind'])) continue;
            final at = row['senderAt'];
            final receipt = row['receiptId'];
            if (at is! DateTime || receipt is! String) continue;
            if (!_database.isOnCurrentBusinessDay(at)) continue;
            await _requestImageOriginal(id, receipt, at);
          }
        }
      } on _AutomationStopped {
        // The next Start owns its own original-message queue.
      } catch (error) {
        RuntimeTrace.record('media.original_queue_failed',
            {'stage': 'seed', 'error': error.runtimeType.toString()});
      } finally {
        if (epoch == _runEpoch) _imageOriginalSeeding = false;
      }
    } finally {
      releaseDiagnosticWork();
    }
  }

  Future<bool> _imageOriginalTaskCurrent(ImageOriginalTask task) async {
    if (!await _mediaOriginalOwnerCurrent(task)) return false;
    final type = await _imageOriginalType(task);
    if (!const {'image', 'video', 'unknown'}.contains(type.kind)) return false;
    if (!await _database.isIncompleteImageAcquisitionAllowed(
        task.customer, task.messageId)) {
      return false;
    }
    final ready = await _mediaInventory.analysisReadyMessageIds(task.customer);
    _checkRun(task.epoch);
    return !ready.contains(task.messageId) && !ready.contains(task.receiptId);
  }

  Future<bool> _mediaOriginalOwnerCurrent(ImageOriginalTask task) async {
    if (!_autoCaptureRunning ||
        task.epoch != _runEpoch ||
        task.sessionId != _automationSessionId ||
        !_imageOriginalTasks.owns(task)) {
      return false;
    }
    final parent = await _mediaInventory.resolveParent(task.customer,
        receiptId: task.receiptId, requireCurrentSession: true);
    if (parent?.messageId != task.messageId) return false;
    final boundAt = await _mediaInventory.recordedSenderTime(
        task.customer, parent!.receiptId);
    if (boundAt == null ||
        !CustomerMessageTime.sameSecond(boundAt, task.senderAt)) {
      return false;
    }
    final db = await _database.database;
    final rows = await db.query('automation_session_messages',
        columns: ['response_state', 'input_kind'],
        where: 'session_id=? AND user_id=? AND message_id=?',
        whereArgs: [task.sessionId, task.customer, task.messageId]);
    if (rows.firstOrNull?['response_state'] != 'pending' ||
        rows.firstOrNull?['input_kind'] != 'media') {
      return false;
    }
    _checkRun(task.epoch);
    return true;
  }

  Future<({String kind, bool knownImage})> _imageOriginalType(
      ImageOriginalTask task) async {
    final parent = await _mediaInventory.resolveParent(task.customer,
        receiptId: task.receiptId, requireCurrentSession: true);
    if (parent?.messageId != task.messageId) {
      return (kind: 'unbound', knownImage: false);
    }
    final rows = await (await _database.database).query('customer_media_items',
        columns: ['kind', 'media_json'],
        where: 'customer=? AND item_id=?',
        whereArgs: [task.customer, parent!.receiptId]);
    if (rows.length != 1) return (kind: 'unbound', knownImage: false);
    final row = rows.single;
    final media = (jsonDecode(row['media_json']?.toString() ?? '[]') as List)
        .whereType<Map>();
    return MediaTimelineProgress.inventoryType(
        row['kind']?.toString() ?? 'unknown', media);
  }

  Future<_OriginalPageResult?> _imageOriginalPage(
      ImageOriginalTask task) async {
    final pages = <Future<_OriginalPageResult?>>[];
    final ready = Completer<_OriginalPageResult>();
    final firstPage = task.searchPage;
    Future<bool> shouldYield() async =>
        _responseUiReserved ||
        await _hasEarlyFormalReply() ||
        _responseUiReserved;
    await _withJdUiOperation(() async {
      if (await shouldYield() || !await _imageOriginalTaskCurrent(task)) return;
      var navigated = false;
      try {
        await _adapter.openConversation(task.customer, allowActivation: true);
        _checkRun(task.epoch);
        if (await shouldYield()) return;
        await _evidenceStore.setRestore(task.customer, true);
        _viewportCapturePump.navigationCutoffs = {
          ..._viewportCapturePump.navigationCutoffs,
          task.customer: task.senderAt.millisecondsSinceEpoch,
        };
        navigated = true;
        await _adapter.scrollConversation(
            expectedCustomer: task.customer,
            deltaY: -10000,
            waitForViewport: true);
        final seen = <String>{};
        for (var page = firstPage; page < firstPage + 3; page++) {
          _checkRun(task.epoch);
          if (ready.isCompleted || await shouldYield()) break;
          if (page > 0) {
            final steps = page == firstPage ? page : 1;
            await _adapter.scrollConversation(
                expectedCustomer: task.customer,
                deltaY: EvidenceCoverage.scrollPixels(steps - 1),
                viewportSteps: steps,
                waitForViewport: true);
          }
          _checkRun(task.epoch);
          if (ready.isCompleted || await shouldYield()) break;
          final frame = await _viewportCapturePump.capture(
              wait: true,
              current: () => _autoCaptureRunning && task.epoch == _runEpoch,
              native: () async => _adapter.captureViewportEvidence(
                  expectedCustomer: task.customer,
                  directory: (await _evidenceDirectory()).path,
                  automationSessionId: task.sessionId,
                  historyCutoff: task.senderAt));
          if (frame == null || !seen.add(frame.id)) break;
          RuntimeTrace.record('evidence.media_recovery_page_saved', {
            'customer': task.customer,
            'messageId': task.messageId,
            'page': page + 1,
            'evidenceId': frame.id,
          });
          final capturedPage = page;
          pages.add(() async {
            try {
              final inspection = await _inspectOriginalFrame(task, frame);
              _checkRun(task.epoch);
              final result =
                  (frame: frame, inspection: inspection, page: capturedPage);
              final candidates = ImageOriginalLocator.locate(
                  inspection, task.customer, task.senderAt);
              if (candidates.isNotEmpty) {
                if (!ready.isCompleted) ready.complete(result);
                _startExactTimedMatches(frame, inspection, task.epoch,
                    registeredCards: {
                      for (final region in candidates) region: task.senderAt
                    });
              }
              return result;
            } catch (error) {
              RuntimeTrace.record('evidence.media_recovery_ocr_failed', {
                'customer': task.customer,
                'evidenceId': frame.id,
                'errorCode': error is PlatformException
                    ? error.code
                    : error.runtimeType.toString(),
              });
              return null;
            }
          }());
        }
      } on _AutomationStopped {
        rethrow;
      } catch (error) {
        if (pages.isEmpty) rethrow;
        // Keep earlier immutable frames when a later scroll/capture fails.
        RuntimeTrace.record('evidence.media_recovery_scroll_deferred', {
          'customer': task.customer,
          'messageId': task.messageId,
          'capturedPages': pages.length,
          'errorCode': error is PlatformException
              ? error.code
              : error.runtimeType.toString(),
        });
      } finally {
        if (navigated && _autoCaptureRunning && task.epoch == _runEpoch) {
          try {
            await _adapter.scrollConversation(
                expectedCustomer: task.customer,
                deltaY: -10000,
                waitForViewport: true);
            await _evidenceStore.setRestore(task.customer, false);
            final cutoffs = {..._viewportCapturePump.navigationCutoffs};
            cutoffs.remove(task.customer);
            _viewportCapturePump.navigationCutoffs = cutoffs;
          } catch (_) {
            // The durable restore marker remains for the next safe visit.
          }
        }
      }
    },
        priority: task.confirmedImage
            ? JdUiPriority.imageAcquisition
            : JdUiPriority.capture);
    if (pages.isEmpty) return null;
    // A ready card beats slower OCR on any other page. With no hit, advance
    // only through the contiguous pages we actually succeeded in inspecting.
    return Future.any<_OriginalPageResult?>([
      ready.future,
      Future.wait(pages).then((results) {
        _OriginalPageResult? last;
        for (final result in results) {
          if (result == null) break;
          last = result;
        }
        return last;
      }),
    ]);
  }

  Future<void> _queueTimedVideoFrame(ImageOriginalTask task,
      ViewportEvidence source, OcrInspection inspection) async {
    final existing = await _evidenceStore.lookup(source.id);
    final frame = existing ??
        ViewportEvidence({
          ...source.metadata,
          'replyActivationAllowed': true,
          'acquisitionOnly': true,
          'acquisitionInputKeys': [task.messageId, task.receiptId],
        });
    if (existing == null) await _evidenceStore.record(frame);
    _checkRun(task.epoch);
    await _originalOcrWrites.run(
        (task.epoch, frame.id),
        () => _recordOcrEvidence(frame, inspection,
            const OcrCaptureExtractor().analyze(inspection)));
    _startExactTimedMatches(frame, inspection, task.epoch, registeredCards: {
      for (final region in ImageOriginalLocator.locate(
          inspection, task.customer, task.senderAt))
        region: task.senderAt,
    });
    await _evidenceStore.requestMediaTypeRecheck(frame.id,
        acquisitionOwnerKeys: {task.messageId, task.receiptId});
    unawaited(_drainEvidenceInbox(mediaOnly: true));
  }

  void _runImageOriginalWork() {
    if (!_autoCaptureRunning) return;
    final epoch = _runEpoch;
    final tasks = _imageOriginalTasks.takeBatch(
        allowUi: !_responseUiReserved, maxInFlight: _maxOriginalMediaWorkers);
    if (tasks.isEmpty) {
      _armImageOriginalWork();
      return;
    }
    for (final task in tasks) {
      unawaited(_processImageOriginalTask(task, epoch));
    }
  }

  Future<void> _processImageOriginalTask(
      ImageOriginalTask task, int epoch) async {
    final releaseDiagnosticWork = _diagnosticWork.acquire();
    try {
      try {
        if (!await _imageOriginalTaskCurrent(task)) {
          _imageOriginalTasks.complete(task);
          return;
        }
        ViewportEvidence? source;
        source = task.freshFrame;
        task.freshFrame = null;
        OcrInspection? savedInspection;
        final type = await _imageOriginalType(task);
        if (!task.triedSavedOriginal) {
          task.triedSavedOriginal = true;
          final rows = await (await _database.database).query(
              'customer_media_items',
              columns: ['evidence_id'],
              where: 'customer=? AND item_id=?',
              whereArgs: [task.customer, task.receiptId]);
          final id = rows.firstOrNull?['evidence_id'];
          final older = id is String ? await _evidenceStore.lookup(id) : null;
          for (final frame in [
            if (source != null) source,
            if (older != null && older.id != source?.id) older,
          ]) {
            if (!await MediaTimelineProgress.savedFrameIsUsable(frame,
                customer: task.customer, sessionId: task.sessionId)) continue;
            final inspect = await _inspectOriginalFrame(task, frame);
            _checkRun(epoch);
            if (ImageOriginalLocator.locate(
                    inspect, task.customer, task.senderAt)
                .isNotEmpty) {
              source = frame;
              savedInspection = inspect;
              break;
            }
          }
          if (savedInspection == null) source = null;
        }
        var inspectedPage = task.searchPage;
        if (source == null) {
          final recovered = await _originalPageCaptures.run(
              (epoch, task.key, task.searchPage),
              () => _imageOriginalPage(task));
          if (recovered == null) return;
          source = recovered.frame;
          savedInspection = recovered.inspection;
          inspectedPage = recovered.page;
        }
        // No UI lease is held across OCR, file parsing, or cache matching.
        final inspection =
            savedInspection ?? await _inspectOriginalFrame(task, source);
        _checkRun(epoch);
        if (!await _imageOriginalTaskCurrent(task)) return;
        final candidates = ImageOriginalLocator.locate(
            inspection, task.customer, task.senderAt);
        if (type.kind == 'video' && candidates.isNotEmpty) {
          await _queueTimedVideoFrame(task, source, inspection);
          _imageOriginalTasks.complete(task);
          return;
        }
        if (candidates.isEmpty) {
          final hash = source.metadata['chatContentSHA256']?.toString();
          final times = const OcrCaptureExtractor()
              .incomingMessageBlocks(inspection)
              .map((block) => block.sentAt)
              .toList()
            ..sort();
          final exhausted = (hash != null && hash == task.previousPageHash) ||
              (times.isNotEmpty &&
                  (task.senderAt.isAfter(times.last) ||
                      !_database.isOnCurrentBusinessDay(times.first)));
          if (exhausted) {
            task.searchPage = 0;
            _imageOriginalTasks.waitForCache(task);
          } else {
            task.searchPage = inspectedPage + 1;
          }
          task.previousPageHash = hash;
          task.reason = 'complete_timestamped_card_not_visible';
          return;
        }

        final region = candidates.first;
        final revision = _mediaCacheRevision;
        final crop = await _matchOriginalFrame(source, region, task.senderAt);
        _checkRun(epoch);
        if (!await _imageOriginalTaskCurrent(task)) return;
        final provedVideo = crop.video != null || crop.playbackOverlayDetected;
        if (provedVideo) {
          await _classifyMediaCard(task.customer, task.receiptId, crop, region,
              evidenceId: source.id);
          if ((await _imageOriginalType(task)).kind == 'video') {
            await _queueTimedVideoFrame(task, source, inspection);
            _imageOriginalTasks.complete(task);
            return;
          }
        }
        if (crop.kind == 'image' &&
            crop.captureSource == 'jd-image-cache' &&
            crop.reason == 'pixel_matched_image_original' &&
            crop.bytes?.isNotEmpty == true) {
          await _acceptImageOriginal(task, crop, evidenceId: source.id);
          return;
        }
        task.reason = 'cache_match_waiting_for_new_material';
        if (revision == _mediaCacheRevision) {
          _imageOriginalTasks.waitForCache(task, frame: source);
        } else {
          task.freshFrame = source;
        }
      } on _AutomationStopped {
        // Old-run acquisition is not permission to update a new-run message.
      } catch (error) {
        task.reason = error is PlatformException
            ? error.code
            : error.runtimeType.toString();
        RuntimeTrace.record('media.original_acquisition_failed', {
          'customer': task.customer,
          'messageId': task.messageId,
          'receiptId': task.receiptId,
          'reason': task.reason,
          'originalQuestionPreserved': true,
        });
      } finally {
        _imageOriginalTasks.release(task,
            retryAfter: task.freshFrame == null
                ? const Duration(seconds: 2)
                : const Duration(milliseconds: 200),
            reason: task.reason);
        if (epoch == _runEpoch && _autoCaptureRunning) {
          // A completed job frees a slot immediately for a different receipt.
          _armImageOriginalWork(Duration.zero);
        }
      }
    } finally {
      releaseDiagnosticWork();
    }
  }

  Future<void> _acceptImageOriginal(
      ImageOriginalTask task, VisibleImagePayload image,
      {String? evidenceId}) async {
    _checkRun(task.epoch);
    if (!await _imageOriginalTaskCurrent(task)) {
      _imageOriginalTasks.complete(task);
      return;
    }
    if (!MediaTimelineProgress.isVerifiedImageOriginal(
        nativeKind: image.kind,
        captureSource: image.captureSource,
        hasImageBytes: image.bytes?.isNotEmpty == true,
        playbackOverlayDetected: image.playbackOverlayDetected,
        hasVideoPayload: image.video != null,
        verifiedOriginal: true)) {
      task.reason = 'image_original_not_verified';
      return;
    }
    var saved = await _saveVisibleImage(task.customer, image,
        sentAt: task.senderAt,
        cacheCopy: true,
        mediaReceiptId: task.receiptId,
        evidenceId: evidenceId);
    _checkRun(task.epoch);
    if (saved == null) {
      // A native recheck can return the exact full image already stored while
      // its old type hint is still pending. A duplicate file is not a reason
      // to abandon this message's type resolution or generation wake-up.
      final document = await (await _database.history).read(task.customer);
      final existing = (document?['messages'] as List? ?? const [])
          .whereType<Map>()
          .where((item) =>
              item['id'] == task.messageId && item['direction'] == 'incoming')
          .firstOrNull;
      final digest = sha256.convert(image.bytes!).toString();
      for (final media in (existing?['media'] as List? ?? const [])
          .whereType<Map>()
          .where((media) =>
              media['type'] == 'image' &&
              media['is_partial'] != true &&
              media['is_loading_preview'] != true &&
              const {
                'jd_image_cache',
                'jd_clipboard_copy',
                'jd_image_viewer_download',
              }.contains(media['capture_source']))) {
        final path = media['path']?.toString();
        if (path == null || path.isEmpty) continue;
        final file = path.startsWith('file:')
            ? File.fromUri(Uri.parse(path))
            : File(path);
        if (!await file.exists() ||
            sha256.convert(await file.readAsBytes()).toString() != digest) {
          continue;
        }
        saved = CapturedMessage(
            stableId: task.messageId,
            direction: 'incoming',
            sender: task.customer,
            sentAt: task.senderAt,
            body: existing?['body']?.toString() ?? '[Customer sent an image]',
            axPath: 'jd-image-original-type-rechecked',
            mediaReceiptId: task.receiptId,
            captureEvidenceId: evidenceId,
            media: [CapturedMedia.fromMap(media)]);
        break;
      }
      if (saved == null) return;
    }
    _checkRun(task.epoch);
    if (!await _imageOriginalTaskCurrent(task)) return;
    final capture = CapturedConversation(
        stableKey: task.customer,
        customerName: task.customer,
        customerExternalId: task.customer,
        capturedAt: DateTime.now(),
        automationSessionId: task.sessionId,
        messages: [saved]);
    await _database.saveCapture(capture,
        activateReplies: true, activeIncomingIds: {task.messageId});
    await _mediaInventory.persist(capture,
        verifiedAnchor: true, currentTaskOnly: true);
    _checkRun(task.epoch);
    // Clear a pending media-type hint only after the full native original has
    // been saved under this same customer/sender-second record.
    await _mediaInventory.resolveMediaTypeVerification(task.customer,
        receiptId: task.receiptId,
        nativeKind: image.kind,
        captureSource: image.captureSource,
        playbackOverlayDetected: image.playbackOverlayDetected,
        hasVideoObject: image.video != null,
        hasImageBytes: image.bytes?.isNotEmpty == true,
        verifiedOriginal: true);
    _checkRun(task.epoch);
    await _mediaAudit.resolveCaptured(capture);
    await _database.retireStaleMediaDraft(task.customer);
    await _evidenceStore.wakeMediaForProgress(task.customer,
        progressKey:
            'original:${task.receiptId}:${sha256.convert(image.bytes!)}',
        ownerKeys: {task.receiptId, task.messageId});
    _checkRun(task.epoch);
    _imageOriginalTasks.complete(task);
    _scheduleDraftGeneration(task.customer, newEvidence: true);
    unawaited(_drainEvidenceInbox(mediaOnly: true));
    await _refreshTickets();
  }

  Future<void> _pollActiveChatSignal() async {
    final releaseDiagnosticWork = _diagnosticWork.acquire();
    try {
      if (!_autoCaptureRunning || _activeChatSignalBusy) return;
      final epoch = _runEpoch;
      final elapsed = Stopwatch()..start();
      _activeChatSignalBusy = true;
      try {
        if (_pendingJdUiOperations > 0 || _priorityUiOperations > 0) return;
        await _captureViewport(fastSampling: true);
      } on _AutomationStopped {
        return;
      } on PlatformException catch (error) {
        if (!const {
          'snapshot_customer_mismatch',
          'snapshot_customer_changed',
          'snapshot_geometry_changed',
          'snapshot_chat_missing'
        }.contains(error.code)) {
          RuntimeTrace.record(
              'evidence.capture_failed', {'errorCode': error.code});
        }
      } catch (error) {
        RuntimeTrace.record('evidence.capture_failed',
            {'errorCode': error.runtimeType.toString()});
      } finally {
        if (epoch == _runEpoch && _autoCaptureRunning && mounted) {
          _activeChatSignalBusy = false;
          _activeChatSignalTimer?.cancel();
          final target =
              widget.scanIntervalOverride ?? const Duration(milliseconds: 250);
          final remaining = target - elapsed.elapsed;
          _activeChatSignalTimer = Timer(
              remaining > Duration.zero ? remaining : Duration.zero,
              () => unawaited(_pollActiveChatSignal()));
        }
      }
    } finally {
      releaseDiagnosticWork();
    }
  }

  Future<CachedMediaPayload?> _pinnedEvidenceMedia(
      ViewportEvidence evidence) async {
    final raw = evidence.pinnedMedia;
    if (raw == null) return null;
    final values = {...raw};
    if (raw['kind'] == 'image') {
      final path = raw['evidenceFile'];
      if (path is! String || !await File(path).exists()) return null;
      values['dataBase64'] = base64Encode(await File(path).readAsBytes());
    }
    return CachedMediaPayload(
        kind: raw['kind']! as String,
        cacheKey: raw['cacheKey']! as String,
        cacheModifiedAt: DateTime.fromMillisecondsSinceEpoch(
            (raw['cacheModifiedAtMs']! as num).toInt()),
        image:
            raw['kind'] == 'image' ? VisibleImagePayload.fromMap(values) : null,
        video: raw['kind'] == 'video'
            ? DownloadedVideoPayload.fromMap(values)
            : null);
  }

  Future<OcrInspection> _refineShortCustomerText(
      ViewportEvidence evidence, OcrInspection inspection) async {
    var lines = inspection.observations;
    for (final region
        in const OcrCaptureExtractor().shortCustomerTextRegions(inspection)) {
      try {
        final refined = await _adapter
            .refineEvidenceText(
                manifestPath: evidence.manifestPath,
                expectedCustomer: evidence.customer,
                region: region)
            .timeout(const Duration(seconds: 2));
        if (refined.isEmpty) continue;
        final old = lines
            .where((o) =>
                o.confidence < .45 &&
                o.x >= region.x &&
                o.x < region.x + region.width &&
                o.y >= region.y &&
                o.y < region.y + region.height)
            .toList();
        lines = [...lines.where((o) => !old.contains(o)), ...refined];
        RuntimeTrace.record('capture.short_text_refined', {
          'customer': evidence.customer,
          'evidenceId': evidence.id,
          'before': old.map((o) => o.text).toList(),
          'after': refined
              .map((o) => {'text': o.text, 'confidence': o.confidence})
              .toList()
        });
      } catch (error) {
        RuntimeTrace.record('capture.short_text_refinement_deferred', {
          'customer': evidence.customer,
          'evidenceId': evidence.id,
          'errorCode': error.runtimeType.toString()
        });
      }
    }
    return inspection.withObservations(lines);
  }

  /// Decode an already admitted unknown body in its original saved pixels.
  /// This runs in the media/background lane, after registration, never in the
  /// formal-send path. A successful empty crop is not repeated on every tick.
  Future<OcrInspection> _refineRegisteredUnknownBodies(
      ViewportEvidence evidence, OcrInspection inspection) async {
    final session = _automationSessionId;
    final epoch = _runEpoch;
    if (session == null ||
        evidence.metadata['automationSessionId'] != session ||
        inspection.activeCustomerId != evidence.customer) {
      return inspection;
    }
    final db = await _database.database;
    final rows = await db.rawQuery('''SELECT DISTINCT m.item_id,w.message_id,
        o.region_json FROM media_card_observations o
      JOIN customer_media_items m ON m.customer=o.customer
        AND (m.item_id=o.item_id OR m.item_id=o.canonical_id)
      JOIN automation_session_messages w ON w.session_id=m.admission_session_id
        AND w.user_id=m.customer AND w.message_id=m.message_id
      WHERE o.customer=? AND o.evidence_id=? AND m.admission_session_id=?
        AND m.canonical_id IS NULL AND m.identity_ambiguous=0
        AND m.kind='unknown' AND m.media_json='[]'
        AND w.response_state='pending' ''',
        [evidence.customer, evidence.id, session]);
    _checkRun(epoch);
    if (rows.isEmpty) return inspection;
    const extractor = OcrCaptureExtractor();
    final media = const OcrImageCandidateSelector().select(
        inspection, evidence.customer,
        includeTextDense: true,
        customerText: extractor
                .analyze(inspection)
                .capture
                ?.messages
                .where((m) => m.direction == 'incoming' && m.media.isEmpty)
                .map((m) => m.body) ??
            const []);
    final blocks = extractor.incomingMessageBlocks(inspection,
        excludedMediaRegions: media);
    var lines = inspection.observations;
    for (final row in rows) {
      final box =
          (jsonDecode(row['region_json']! as String) as List).cast<num>();
      if (box.length != 4) continue;
      final matches = blocks
          .where((block) =>
              box[1] >= block.header.y + block.header.height - .008 &&
              box[1] <= block.region.y + .08 &&
              box[1] < block.region.y + block.region.height &&
              box[0] < block.region.x + block.region.width &&
              box[0] + box[2] > block.region.x)
          .toList();
      if (matches.length != 1) continue;
      final block = matches.single;
      // A now-visible image must acquire its original, not turn its printed
      // words into a text reply while its unknown owner is being classified.
      if (IncomingMessageOwnership.occupiesBlock(inspection, evidence.customer,
          header: block.header,
          bodyRegion: block.region,
          mediaRegions: media)) {
        continue;
      }
      for (final tile in block.textRecoveryRegions.take(4)) {
        final key = '${evidence.id}:${row['item_id']}:'
            '${tile.x}:${tile.y}:${tile.width}:${tile.height}';
        if (_refinedUnknownBlockKeys.contains(key)) continue;
        try {
          final refined = await _adapter
              .refineEvidenceText(
                  manifestPath: evidence.manifestPath,
                  expectedCustomer: evidence.customer,
                  region: tile)
              .timeout(const Duration(seconds: 2));
          _checkRun(epoch);
          _refinedUnknownBlockKeys.add(key);
          if (_refinedUnknownBlockKeys.length > 512) {
            _refinedUnknownBlockKeys.remove(_refinedUnknownBlockKeys.first);
          }
          final valid = refined.where((line) {
            final cx = line.x + line.width / 2;
            final cy = line.y + line.height / 2;
            if (line.confidence < .45 ||
                line.isWatermark ||
                line.rotationDegrees.abs() > 10 ||
                line.text.trim().isEmpty ||
                line.x < tile.x - .002 ||
                line.y < tile.y - .002 ||
                line.x + line.width > tile.x + tile.width + .002 ||
                line.y + line.height > tile.y + tile.height + .002 ||
                cy < block.region.y ||
                cy > block.region.y + block.region.height) {
              return false;
            }
            return !inspection.observations.any((old) =>
                (old.isWatermark ||
                    (old.rotationDegrees.abs() > 10 && old.confidence < .75)) &&
                cx >= old.x &&
                cx <= old.x + old.width &&
                cy >= old.y &&
                cy <= old.y + old.height);
          }).toList();
          if (valid.isEmpty) continue;
          final current = await db.query('customer_media_items',
              columns: ['kind', 'canonical_id', 'media_json'],
              where: 'item_id=? AND customer=? AND admission_session_id=?',
              whereArgs: [row['item_id'], evidence.customer, session]);
          _checkRun(epoch);
          if (current.isEmpty ||
              current.single['kind'] != 'unknown' ||
              current.single['canonical_id'] != null ||
              current.single['media_json'] != '[]') {
            break;
          }
          lines = [
            ...lines.where((old) => !(old.confidence < .45 &&
                old.x + old.width / 2 >= tile.x &&
                old.x + old.width / 2 <= tile.x + tile.width &&
                old.y + old.height / 2 >= tile.y &&
                old.y + old.height / 2 <= tile.y + tile.height)),
            ...valid,
          ];
          RuntimeTrace.record('capture.short_text_refined', {
            'customer': evidence.customer,
            'evidenceId': evidence.id,
            'parentMessageId': row['message_id'],
            'source': 'registered_unknown_block',
          });
          break;
        } catch (error) {
          _checkRun(epoch);
          RuntimeTrace.record('capture.short_text_refinement_deferred', {
            'customer': evidence.customer,
            'evidenceId': evidence.id,
            'errorCode': error.runtimeType.toString(),
          });
          // Busy/native errors are not successful OCR of these pixels. Keep
          // the obligation and its decoding attempt available for recovery.
          break;
        }
      }
    }
    return inspection.withObservations(lines);
  }

  /// Captured inputs enter the current workflow independently of observation
  /// delay or an unrelated seller reply. The DB excludes Start baseline IDs.
  Set<String> _activeIncomingIds(
      ViewportEvidence evidence, CapturedConversation? capture) {
    final cutoff = evidence.metadata['historyCutoffMs'] as num?;
    final active = activeLiveIncomingIds(capture,
        replyActivationAllowed:
            evidence.metadata['replyActivationAllowed'] == true,
        historyCutoff: cutoff == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(cutoff.toInt(), isUtc: true),
        signalAt: _unreadRecovery[evidence.customer]?.detectedAt ??
            evidence.capturedAt,
        knownIncomingIds:
            _unreadRecovery[evidence.customer]?.knownIncomingIds ?? const {});
    if (evidence.metadata['liveTextInputIds'] case final List textIds) {
      active.removeWhere((id) =>
          !textIds.contains(id) &&
          (capture?.messages.any((message) =>
                  message.stableId == id &&
                  message.mediaReceiptId == null &&
                  message.media.isEmpty) ??
              false));
    }
    if (evidence.metadata['acquisitionOnly'] != true) return active;
    final allowed = _acquisitionInputKeys(evidence);
    return {
      for (final message in capture?.messages ?? const <CapturedMessage>[])
        if (message.direction == 'incoming' &&
            active.contains(message.stableId) &&
            ((evidence.metadata['liveTextInputIds'] as List? ?? const [])
                    .contains(message.stableId) ||
                allowed.contains(message.stableId) ||
                allowed.contains(message.mediaReceiptId)))
          message.stableId,
    };
  }

  Set<String> _acquisitionInputKeys(ViewportEvidence evidence) =>
      (evidence.metadata['acquisitionInputKeys'] as List? ?? const [])
          .whereType<String>()
          .toSet();

  /// A recovery-only history page authorizes the already received media, not
  /// every older question that happens to share its viewport. Keep other
  /// incoming content in the immutable frame rather than stamping it live.
  CapturedConversation? _scopeAcquisitionCapture(
      ViewportEvidence evidence, CapturedConversation? capture) {
    if (capture == null ||
        (evidence.metadata['acquisitionOnly'] != true &&
            evidence.metadata['liveTextInputIds'] == null)) {
      return capture;
    }
    final allowed = _activeIncomingIds(evidence, capture);
    return CapturedConversation(
        stableKey: capture.stableKey,
        customerName: capture.customerName,
        customerExternalId: capture.customerExternalId,
        capturedAt: capture.capturedAt,
        automationSessionId: capture.automationSessionId,
        messages: capture.messages
            .where((message) =>
                message.direction != 'incoming' ||
                allowed.contains(message.stableId))
            .toList());
  }

  /// The first passive frame marks only proven pre-Start clocks as history.
  /// A current-run clock in this same frame continues through registration;
  /// unreadable clocks stay in the saved observation, not the old-ID baseline.
  Future<bool> _saveDiscoveryBaseline(ViewportEvidence evidence,
      OcrInspection inspection, OcrExtractionAttempt extraction) async {
    final epoch = _runEpoch;
    final session = _automationSessionId;
    final customer = evidence.customer;
    const selector = OcrImageCandidateSelector();
    final owned = selector.select(inspection, customer,
        includeTextDense: true,
        customerText:
            (extraction.capture?.messages ?? const <CapturedMessage>[])
                .where((m) => m.direction == 'incoming' && m.media.isEmpty)
                .map((m) => m.body));
    final candidates = [
      ...owned,
      ...selector.unboundCandidates(inspection, owned)
    ];
    final masked = const OcrCaptureExtractor()
        .analyze(inspection, excludedMediaRegions: candidates)
        .capture;
    final candidateClocks = {
      for (final region in candidates.take(24))
        region:
            const OcrCaptureExtractor().mediaClockForRegion(inspection, region)
    };
    final currentFrame = ViewportEvidence({
      ...evidence.metadata,
      'replyActivationAllowed': true,
      'capturePurpose': 'active_discovery',
    });
    final hasCurrentMessages = <DateTime>[
      for (final message in masked?.messages ?? const <CapturedMessage>[])
        if (message.direction == 'incoming' && message.sentAt != null)
          message.sentAt!,
      for (final block
          in const OcrCaptureExtractor().incomingMessageBlocks(inspection))
        block.sentAt,
      for (final clock in candidateClocks.values)
        if (clock.source == 'ocr_media_sender_header' && clock.sentAt != null)
          clock.sentAt!,
      if (extraction.latestIncomingSentAt case final at?) at,
    ].any((at) => LiveMediaArrival.admitsCurrentTimestamp(
        evidence: currentFrame, inspection: inspection, senderAt: at));
    final messages = <CapturedMessage>[
      for (final message in masked?.messages ?? const <CapturedMessage>[])
        if (message.direction != 'incoming' ||
            LiveMediaArrival.isBeforeSessionStart(evidence, message.sentAt))
          CapturedMessage(
              stableId: message.stableId,
              direction: message.direction,
              body: message.body,
              sender: message.sender,
              sentAt: message.sentAt,
              axPath: message.axPath,
              media: message.media,
              deliveryConfirmed: message.deliveryConfirmed,
              observationTurnKey: message.observationTurnKey,
              mediaReceiptId: message.mediaReceiptId,
              captureEvidenceId: evidence.id),
    ];
    final slots = <String, int>{};
    for (final region in candidates.take(24)) {
      _checkRun(epoch);
      final clock = candidateClocks[region]?.source == 'ocr_media_sender_header'
          ? candidateClocks[region]?.sentAt
          : null;
      if (!LiveMediaArrival.isBeforeSessionStart(evidence, clock)) continue;
      final slot = slots.update(
          clock?.toIso8601String() ?? 'unclocked', (n) => n + 1,
          ifAbsent: () => 0);
      // Sender time is sufficient for a historical baseline. Media decoding
      // must remain available for current messages rather than old previews.
      final receipt = await _mediaInventory.observe(
          customer: customer,
          evidenceId: evidence.id,
          observedAt: evidence.capturedAt,
          senderAt: clock,
          slot: slot,
          region: [region.x, region.y, region.width, region.height],
          current: false);
      if (inspection.unboundMediaRegions.contains(region)) {
        final id = await _mediaAudit.discoverUnbound(evidence, region,
            current: false, receiptId: receipt, inspection: inspection);
        await _mediaAudit.groupUnbound(evidence, region, id,
            inspection: inspection);
      }
      final canonical =
          await _mediaInventory.canonicalMessageId(receipt, customer: customer);
      messages.add(CapturedMessage(
          stableId: canonical ?? 'media-pending:$receipt',
          direction: 'incoming',
          body: '[Customer sent media; acquisition pending.]',
          sender: customer,
          sentAt: clock,
          axPath: 'media-receipt:$receipt',
          mediaReceiptId: receipt,
          captureEvidenceId: evidence.id));
    }
    _checkRun(epoch);
    final baseline = CapturedConversation(
        stableKey: masked?.stableKey ??
            extraction.capture?.stableKey ??
            'customer:${sha256.convert(utf8.encode(customer))}',
        customerName: customer,
        customerExternalId: customer,
        capturedAt: evidence.capturedAt,
        automationSessionId: session,
        messages: messages);
    await _database.saveCapture(baseline,
        isCurrentViewport: false, activateReplies: false);
    _checkRun(epoch);
    await _mediaInventory.persist(baseline, notify: false);
    _checkRun(epoch);
    await _database.registerDiscoveryBaseline(
        customer, messages.map((m) => m.stableId),
        evidenceId: evidence.id, expectedSessionId: session!);
    _checkRun(epoch);
    return hasCurrentMessages;
  }

  Future<OcrInspection?> _readRegisteredEvidenceOcr(
      ViewportEvidence evidence) async {
    try {
      final file = File('${evidence.manifestPath}.ocr.json');
      if (!await file.exists()) return null;
      final value = Map<String, Object?>.from(
          jsonDecode(await file.readAsString()) as Map);
      if (!value.containsKey('physicalMediaRegions') ||
          value['evidenceId'] != evidence.id ||
          value['capturedAtMs'] != evidence.capturedAt.millisecondsSinceEpoch ||
          !customerIdentitiesMatch(
              value['activeCustomerId']?.toString(), evidence.customer) ||
          (evidence.metadata['pngSHA256'] != null &&
              value['sourcePngSHA256'] != evidence.metadata['pngSHA256'])) {
        return null;
      }
      value['pngBase64'] =
          base64Encode(await File(evidence.imagePath).readAsBytes());
      return OcrInspection.fromMap(value);
    } catch (_) {
      return null;
    }
  }

  Future<void> _drainMediaEvidence() async {
    final releaseDiagnosticWork = _diagnosticWork.acquire();
    try {
      final epoch = _runEpoch;
      if (_mediaEvidenceWorkerEpoch == epoch) {
        _mediaEvidenceWakeRequested = true;
        return;
      }
      _mediaEvidenceWorkerEpoch = epoch;
      try {
        do {
          _mediaEvidenceWakeRequested = false;
          await _ensureEvidenceRecovered();
          _checkRun(epoch);
          final customers = await _evidenceStore.dueMediaCustomers();
          _checkRun(epoch);
          for (final customer in customers) {
            if (_mediaEvidenceWorkers[customer] == epoch) {
              _mediaEvidenceCustomerWakes.add(customer);
              continue;
            }
            _mediaEvidenceWorkers[customer] = epoch;
            unawaited(_claimCustomerMedia(customer, epoch).whenComplete(() {
              if (_mediaEvidenceWorkers[customer] != epoch) return;
              _mediaEvidenceWorkers.remove(customer);
              if (_mediaEvidenceCustomerWakes.remove(customer) &&
                  _autoCaptureRunning &&
                  _runEpoch == epoch) {
                unawaited(_drainMediaEvidence());
              }
            }));
          }
        } while (_mediaEvidenceWakeRequested);
      } on _AutomationStopped {
        return;
      } catch (error) {
        if (_autoCaptureRunning && _runEpoch == epoch) {
          RuntimeTrace.record('media.dispatch_failed', {'error': '$error'});
        }
      } finally {
        if (_mediaEvidenceWorkerEpoch == epoch)
          _mediaEvidenceWorkerEpoch = null;
      }
    } finally {
      releaseDiagnosticWork();
    }
  }

  Future<void> _claimCustomerMedia(String customer, int epoch) async {
    final releaseDiagnosticWork = _diagnosticWork.acquire();
    try {
      try {
        while (_autoCaptureRunning && _runEpoch == epoch) {
          final claim = await _evidenceStore.claim(
              mediaOnly: true, mediaCustomer: customer);
          _checkRun(epoch);
          if (claim == null) break;
          unawaited(_drainEvidenceInbox(mediaOnly: true, mediaClaim: claim)
              .whenComplete(() {
            if (_autoCaptureRunning && _runEpoch == epoch) {
              unawaited(_drainMediaEvidence());
            }
          }));
        }
      } on _AutomationStopped {
        return;
      } catch (error) {
        if (_autoCaptureRunning && _runEpoch == epoch) {
          RuntimeTrace.record(
              'media.claim_failed', {'customer': customer, 'error': '$error'});
        }
      }
    } finally {
      releaseDiagnosticWork();
    }
  }

  void _startViewportOcr(ViewportEvidence evidence) {
    if (evidence.metadata['replyActivationAllowed'] != true &&
        evidence.metadata['capturePurpose'] != 'discovery_baseline' &&
        evidence.metadata['historyCutoffMs'] == null) {
      return;
    }
    if (_viewportOcrTasks.containsKey(evidence.id)) return;
    final priorityRecovery =
        evidence.metadata['captureRequestedBackfill'] == true &&
            evidence.metadata['replyActivationAllowed'] == true;
    if (_viewportOcrTasks.length >= (priorityRecovery ? 120 : 96)) return;
    final epoch = _runEpoch;
    // Speculative recognition reads immutable pixels only. The normal
    // customer lease still decides whether and when to register the result.
    _viewportOcrTasks[evidence.id] = () async {
      try {
        final inspection = _registeredEvidenceOcr[evidence.id] ??
            await _readRegisteredEvidenceOcr(evidence) ??
            await (priorityRecovery
                ? _adapter.inspectViewportEvidence(evidence,
                    mediaRecognition: true)
                : _inspectForRegistration(evidence));
        _startExactTimedMatches(evidence, inspection, epoch);
        unawaited(_sharePendingMediaFrame(evidence, inspection, epoch));
        return inspection;
      } catch (_) {
        return null; // The regular claim path retains its retry handling.
      }
    }();
  }

  void _startExactTimedMatches(
      ViewportEvidence frame, OcrInspection inspection, int epoch,
      {Map<OcrVisualRegion, DateTime>? registeredCards}) {
    if (!_autoCaptureRunning ||
        epoch != _runEpoch ||
        frame.metadata['automationSessionId'] != _automationSessionId ||
        _timedMatchesInFlight.length >= _maxParallelTimedMatches) return;
    final cards = registeredCards == null
        ? ExactTimedMedia.select(frame, inspection,
            sessionStartedAt: _database.automationSessionStartedAt)
        : ExactTimedMedia.registered(frame, inspection, registeredCards);
    _launchDiagnosticWork(ExactTimedMedia.run(cards, (card) async {
      if (_timedMatchesInFlight.length >= _maxParallelTimedMatches) return;
      final messageId =
          CustomerMessageTime.incomingId(frame.customer, card.sentAt);
      final workKey = (epoch, frame.id, messageId);
      if (_testedTimedCards.contains(workKey) ||
          !_timedMatchesInFlight.add(workKey)) return;
      _testedTimedCards.add(workKey);
      if (_testedTimedCards.length > 1024) {
        _testedTimedCards.remove(_testedTimedCards.first);
      }
      try {
        if (await _database.isHumanContacting(frame.customer) ||
            await _database.isMessageFormallyAnswered(
                frame.customer, messageId)) return;
        _checkRun(epoch);
        RuntimeTrace.record('media.timed_parallel_candidate', {
          'customer': frame.customer,
          'evidenceId': frame.id,
          'messageId': messageId,
          'senderAt': card.sentAt.toUtc().toIso8601String(),
          'capturedAt': frame.capturedAt.toUtc().toIso8601String(),
        });
        final raw = await _matchOriginalFrame(frame, card.region, card.sentAt);
        _checkRun(epoch);
        final original =
            await _verifyFrameMatchedVideoOwner(frame.customer, raw);
        final video = original.video != null && original.kind == 'video';
        final image = original.kind == 'image' &&
            original.captureSource == 'jd-image-cache' &&
            original.reason == 'pixel_matched_image_original' &&
            original.bytes?.isNotEmpty == true;
        if (!video && !image) return;
        // A slow crop or a miss cannot hold the time-key guard. Only a
        // verified original takes it, and only for this sender second.
        await _timedMediaWrites.run(
            (epoch, messageId),
            () => _publishExactTimedOriginal(frame, inspection, card, original,
                epoch: epoch,
                messageId: messageId,
                isVideo: video,
                requireRegistered: registeredCards != null));
      } on _AutomationStopped {
        // Run ownership ended while background matching was in flight.
      } catch (error) {
        RuntimeTrace.record('media.timed_parallel_failed', {
          'customer': frame.customer,
          'evidenceId': frame.id,
          'messageId': messageId,
          'reason': error is PlatformException
              ? error.code
              : error.runtimeType.toString(),
        });
      } finally {
        _timedMatchesInFlight.remove(workKey);
      }
    }));
  }

  Future<void> _publishExactTimedOriginal(
      ViewportEvidence frame,
      OcrInspection inspection,
      ExactTimedCard card,
      VisibleImagePayload original,
      {required int epoch,
      required String messageId,
      required bool isVideo,
      required bool requireRegistered}) async {
    final customer = frame.customer;
    final session = _automationSessionId;
    _checkRun(epoch);
    if (session == null ||
        frame.metadata['automationSessionId'] != session ||
        await _database.isHumanContacting(customer) ||
        await _database.isMessageFormallyAnswered(customer, messageId)) return;
    final ready = await _mediaInventory.analysisReadyMessageIds(customer);
    if (ready.contains(messageId)) return;
    var parent = await _mediaInventory.findTimeParent(customer, card.sentAt);
    if ((requireRegistered && parent == null) ||
        (parent != null &&
            (!parent.isCurrentSession || parent.messageId != messageId))) {
      return;
    }
    final existing =
        await _database.incomingMessageIdAtTime(customer, card.sentAt);
    // The ordered lane can resolve a genuine ambiguity. Do not overwrite
    // existing text or revive a message from a previous run.
    if (parent == null &&
        (existing != null ||
            !LiveMediaArrival.admitsCurrentTimestamp(
                evidence: frame,
                inspection: inspection,
                senderAt: card.sentAt,
                sessionStartedAt: _database.automationSessionStartedAt)))
      return;
    _checkRun(epoch);
    final observation = await _mediaAudit.discover(frame, card.region,
        inspection: inspection, physicalCards: inspection.physicalMediaRegions);
    await _mediaAudit.bindMessageTime(observation,
        senderAt: card.sentAt, parent: parent);
    if (parent == null) {
      await _mediaAudit.rememberLiveArrival(observation,
          evidence: frame,
          occurrenceKey: messageId,
          arrivalKey: messageId,
          senderAt: card.sentAt,
          slot: 0);
    }
    final r = card.region;
    final observed = await _mediaInventory.observe(
        customer: customer,
        evidenceId: frame.id,
        observedAt: frame.capturedAt,
        senderAt: card.sentAt,
        slot: 0,
        region: [r.x, r.y, r.width, r.height],
        current: true,
        occurrenceKey: messageId,
        parentReceiptId: parent?.receiptId);
    final receipt = await _classifyMediaCard(customer, observed, original, r,
        evidenceId: frame.id);
    _checkRun(epoch);
    if (parent == null) {
      final admission = await _database.admitMediaMessage(customer,
          receiptId: receipt,
          evidenceId: frame.id,
          occurrenceKey: messageId,
          receivedAt: frame.capturedAt,
          senderAt: card.sentAt,
          messageId: messageId);
      _checkRun(epoch);
      parent = await _mediaInventory.resolveParent(customer,
          receiptId: admission.receiptId, requireCurrentSession: true);
    }
    if (parent == null ||
        !parent.isCurrentSession ||
        parent.messageId != messageId) return;
    await _mediaAudit.bindParent(observation,
        receiptId: parent.receiptId, messageId: parent.messageId);
    RuntimeTrace.record('media.timed_parallel_matched', {
      'customer': customer,
      'messageId': messageId,
      'evidenceId': frame.id,
      'kind': isVideo ? 'video' : 'image',
      'frameCapturedAt': frame.capturedAt.toIso8601String()
    });

    final saved = isVideo
        ? await _processDownloadedVideo(
            customer, original.video!, original.visualFingerprint ?? '',
            cover: await _saveVideoCover(customer, original),
            sentAt: card.sentAt,
            mediaReceiptId: parent.receiptId)
        : await _saveVisibleImage(customer, original,
            sentAt: card.sentAt,
            cacheCopy: true,
            mediaReceiptId: parent.receiptId,
            evidenceId: frame.id);
    _checkRun(epoch);
    if (saved == null ||
        await _database.isMessageFormallyAnswered(customer, messageId)) return;
    final capture = CapturedConversation(
        stableKey: customer,
        customerName: customer,
        customerExternalId: customer,
        capturedAt: frame.capturedAt,
        automationSessionId: session,
        messages: [
          CapturedMessage(
              stableId: messageId,
              direction: 'incoming',
              body: saved.body,
              sender: customer,
              sentAt: card.sentAt,
              axPath: saved.axPath,
              media: saved.media,
              mediaReceiptId: parent.receiptId,
              captureEvidenceId: frame.id)
        ]);
    await _database.saveCapture(capture,
        activateReplies: true,
        isCurrentViewport: false,
        activeIncomingIds: {messageId});
    _checkRun(epoch);
    await _mediaInventory.persist(capture,
        verifiedAnchor: true, currentTaskOnly: true);
    _checkRun(epoch);
    await _mediaInventory.resolveMediaTypeVerification(customer,
        receiptId: parent.receiptId,
        nativeKind: original.kind,
        captureSource: original.captureSource,
        playbackOverlayDetected: original.playbackOverlayDetected,
        hasVideoObject: original.video != null,
        hasImageBytes: original.bytes?.isNotEmpty == true,
        verifiedOriginal: true);
    await _mediaAudit.resolveCaptured(capture);
    _checkRun(epoch);
    _scheduleVideoAudioEnrichment(capture);
    await _database.retireStaleMediaDraft(customer);
    _checkRun(epoch);
    _scheduleDraftGeneration(customer, newEvidence: true);
  }

  Future<OcrInspection> _inspectForRegistration(
      ViewportEvidence evidence) async {
    final live = evidence.metadata['historyCutoffMs'] == null;
    final epoch = _runEpoch;
    if (live &&
        evidence.metadata['replyActivationAllowed'] == true &&
        evidence.metadata['capturePurpose'] != 'discovery_baseline' &&
        evidence.metadata['acquisitionOnly'] != true &&
        !_textFirstProbes.containsKey(evidence.customer) &&
        _textFirstOcrPolicy.shouldTry(evidence.customer, DateTime.now())) {
      _textFirstProbes[evidence.customer] = epoch;
      try {
        final first = await _adapter.inspectViewportEvidence(evidence,
            liveRegistration: true, textFirst: true);
        if (_autoCaptureRunning && _runEpoch == epoch) {
          final plan = const OcrCaptureExtractor()
              .planTextFirst(first, evidence.customer);
          _textFirstOcrPolicy.record(
              evidence.customer, evidence.id, DateTime.now(),
              useful:
                  !plan.needsFullRecognition || plan.independentText != null);
        }
        return first;
      } catch (_) {
        // The complete OCR path keeps ownership of recovery and retries.
      } finally {
        if (_textFirstProbes[evidence.customer] == epoch) {
          _textFirstProbes.remove(evidence.customer);
        }
      }
    }
    return _adapter.inspectViewportEvidence(evidence, liveRegistration: live);
  }

  Future<void> _dispatchViewportRegistration() async {
    final releaseDiagnosticWork = _diagnosticWork.acquire();
    try {
      final epoch = _runEpoch;
      if (_evidenceWorkerEpoch == epoch) {
        _evidenceWakeRequested = true;
        return;
      }
      _evidenceWorkerEpoch = epoch;
      try {
        do {
          _evidenceWakeRequested = false;
          await _ensureEvidenceRecovered();
          _checkRun(epoch);
          final customers = await _evidenceStore.dueRegistrationCustomers();
          _checkRun(epoch);
          for (final customer in customers) {
            if (_registrationWorkers[customer] == epoch) {
              _registrationCustomerWakes.add(customer);
              continue;
            }
            _registrationWorkers[customer] = epoch;
            unawaited(_drainEvidenceInbox(registrationCustomer: customer)
                .whenComplete(() {
              if (_registrationWorkers[customer] != epoch) return;
              _registrationWorkers.remove(customer);
              final wake = _registrationCustomerWakes.remove(customer);
              if (_autoCaptureRunning && _runEpoch == epoch) {
                if (wake) unawaited(_dispatchViewportRegistration());
                unawaited(_drainMediaEvidence());
              }
            }));
          }
        } while (_evidenceWakeRequested);
      } on _AutomationStopped {
        return;
      } catch (error) {
        if (_autoCaptureRunning && epoch == _runEpoch) {
          RuntimeTrace.record(
              'evidence.registration_dispatch_failed', {'error': '$error'});
        }
      } finally {
        if (_evidenceWorkerEpoch == epoch) _evidenceWorkerEpoch = null;
      }
    } finally {
      releaseDiagnosticWork();
    }
  }

  Future<void> _drainEvidenceInbox(
      {bool mediaOnly = false,
      String? registrationCustomer,
      ViewportEvidence? mediaClaim}) async {
    final releaseDiagnosticWork = _diagnosticWork.acquire();
    try {
      if (!_autoCaptureRunning) return;
      if (mediaOnly && mediaClaim == null) return await _drainMediaEvidence();
      if (!mediaOnly && registrationCustomer == null) {
        return await _dispatchViewportRegistration();
      }
      final epoch = _runEpoch;
      try {
        await _ensureEvidenceRecovered();
        var claimToProcess = mediaClaim;
        while (_autoCaptureRunning && epoch == _runEpoch) {
          final claimed = mediaOnly
              ? claimToProcess
              : await _evidenceStore.claim(
                  mediaOnly: false, registrationCustomer: registrationCustomer);
          claimToProcess = null;
          _checkRun(epoch);
          if (claimed == null) break;
          ViewportEvidence evidence = claimed;
          var visualCommitHeld = false;
          final manualCoverageExcludedIds = <String>{};
          try {
            if (evidence.metadata['replyActivationAllowed'] != true &&
                evidence.metadata['capturePurpose'] != 'discovery_baseline' &&
                evidence.metadata['capturePurpose'] != 'arrival_observation' &&
                evidence.metadata['historyCutoffMs'] == null) {
              if (!mediaOnly) _viewportOcrTasks.remove(evidence.id);
              await _evidenceStore.complete(evidence);
              RuntimeTrace.record('evidence.history_only_skipped', {
                'customer': evidence.customer,
                'evidenceId': evidence.id,
                'reason': 'no_current_session_signal',
                'ocrStarted': false
              });
              continue;
            }
            if (mediaOnly && _evidencePins[evidence.id] != null) {
              await _evidencePins[evidence.id];
            }
            final currentClaim = await _evidenceStore.refreshClaim(evidence);
            _checkRun(epoch);
            if (currentClaim == null) continue;
            evidence = currentClaim;
            var inspection =
                mediaOnly || evidence.metadata['captureReplayOcr'] == true
                    ? _registeredEvidenceOcr[evidence.id] ??
                        await _readRegisteredEvidenceOcr(evidence)
                    : null;
            final registeredOcr = inspection != null;
            if (!mediaOnly) {
              final prefetched = _viewportOcrTasks.remove(evidence.id);
              if (prefetched != null) {
                inspection ??=
                    await prefetched.timeout(const Duration(seconds: 30));
              }
            }
            inspection ??= await (mediaOnly
                    ? _adapter.inspectViewportEvidence(evidence,
                        mediaRecognition: true)
                    : _inspectForRegistration(evidence))
                .timeout(const Duration(seconds: 30));
            _checkRun(epoch);
            if (!customerIdentitiesMatch(
                inspection.activeCustomerId, evidence.customer)) {
              throw StateError('Saved evidence customer does not match.');
            }
            if (await _database.isHumanContacting(evidence.customer)) {
              final unresolvedMedia =
                  await _mediaAudit.unresolvedCount(evidence.id);
              await _evidenceStore.complete(evidence,
                  partial: unresolvedMedia > 0);
              continue;
            }
            var recovery = _unreadRecovery[evidence.customer];
            if (mediaOnly && _evidencePins[evidence.id] != null) {
              await _evidencePins[evidence.id];
            }
            if (!registeredOcr &&
                inspection.ocrEngine == 'apple_vision_text_first') {
              const extractor = OcrCaptureExtractor();
              var plan = extractor.planTextFirst(inspection, evidence.customer);
              final capture = plan.independentText;
              var early = 0;
              if (plan.needsFullRecognition && capture != null) {
                final current = await _evidenceStore.refreshClaim(evidence);
                _checkRun(epoch);
                if (current == null) continue;
                evidence = current;
                if (evidence.metadata['replyActivationAllowed'] == true &&
                    evidence.metadata['historyCutoffMs'] == null &&
                    evidence.metadata['acquisitionOnly'] != true) {
                  final frontier = evidence.metadata
                          .containsKey('admissionFrontier')
                      ? evidence.metadata['admissionFrontier'] as Map? ??
                          await _mediaConversationFrontier(evidence.customer,
                              baselineOnly: true)
                      : await _mediaConversationFrontier(evidence.customer);
                  _checkRun(epoch);
                  final admitted = await _authorizeTextObservation(
                      evidence, inspection, capture, frontier);
                  early = admitted.length;
                  manualCoverageExcludedIds.addAll(admitted);
                }
              }
              if (plan.reasons.contains('weak_text') ||
                  plan.reasons.contains('unresolved_header')) {
                inspection = await extractor.refineIncomingClockHeaders(
                    inspection,
                    refine: (region) => _adapter
                        .refineEvidenceText(
                            manifestPath: evidence.manifestPath,
                            expectedCustomer: evidence.customer,
                            region: region)
                        .timeout(const Duration(seconds: 2)));
                inspection =
                    await _refineShortCustomerText(evidence, inspection);
                _checkRun(epoch);
                plan = extractor.planTextFirst(inspection, evidence.customer);
              }
              RuntimeTrace.record('capture.text_first_decision', {
                'customer': evidence.customer,
                'evidenceId': evidence.id,
                'confirmedText': capture?.messages.length ?? 0,
                'earlyAdmitted': early,
                'fullRecognition': plan.needsFullRecognition,
                'reasons': plan.reasons.toList(),
              });
              if (plan.needsFullRecognition) {
                // Reuse the immutable full result for a re-registration of
                // these exact pixels rather than queueing another Vision pass.
                inspection = _registeredEvidenceOcr[evidence.id] ??
                    await _readRegisteredEvidenceOcr(evidence) ??
                    await _adapter
                        .inspectViewportEvidence(evidence,
                            liveRegistration: true)
                        .timeout(const Duration(seconds: 30));
                _checkRun(epoch);
              }
            }
            if (!registeredOcr &&
                inspection.ocrEngine != 'apple_vision_text_first') {
              inspection = await const OcrCaptureExtractor()
                  .refineIncomingClockHeaders(inspection,
                      refine: (region) => _adapter
                          .refineEvidenceText(
                              manifestPath: evidence.manifestPath,
                              expectedCustomer: evidence.customer,
                              region: region)
                          .timeout(const Duration(seconds: 2)));
              inspection = await _refineShortCustomerText(evidence, inspection);
            }
            if (mediaOnly) {
              inspection =
                  await _refineRegisteredUnknownBodies(evidence, inspection);
            }
            _checkRun(epoch);
            // Live activation can arrive while immutable OCR is in flight.
            // Apply it under the original lease rather than reopening the same
            // frame for another worker. Completion replays only registration if
            // activation changes again after this acknowledgement.
            final activatedClaim = await _evidenceStore.refreshClaim(evidence);
            _checkRun(epoch);
            if (activatedClaim == null) continue;
            evidence = activatedClaim;
            _registeredEvidenceOcr[evidence.id] = inspection;
            if (!mediaOnly) {
              _startExactTimedMatches(evidence, inspection, epoch);
              unawaited(_sharePendingMediaFrame(evidence, inspection, epoch));
            }
            while (_registeredEvidenceOcr.length > 24) {
              _registeredEvidenceOcr.remove(_registeredEvidenceOcr.keys.first);
            }
            final extraction = _analyzeUnreadInspection(inspection, recovery);
            await _recordOcrEvidence(evidence, inspection, extraction);
            _checkRun(epoch);
            final persistedClaim = await _evidenceStore.refreshClaim(evidence);
            _checkRun(epoch);
            if (persistedClaim == null) continue;
            evidence = persistedClaim;
            if (evidence.metadata['capturePurpose'] == 'discovery_baseline') {
              final hasCurrentMessages = await _saveDiscoveryBaseline(
                  evidence, inspection, extraction);
              _checkRun(epoch);
              if (!hasCurrentMessages) {
                await _evidenceStore.complete(evidence);
                continue;
              }
              // First observation is not necessarily old history. Process the
              // exact same saved pixels now; waiting for another frame can lose
              // a newly received bubble after it scrolls offscreen.
              await _evidenceStore.record(ViewportEvidence({
                ...evidence.metadata,
                'replyActivationAllowed': true,
                'capturePurpose': 'live_signal',
              }));
              _checkRun(epoch);
              final promoted = await _evidenceStore.refreshClaim(evidence);
              _checkRun(epoch);
              if (promoted == null) continue;
              evidence = promoted;
            }
            if (!extraction.transferNoticeVisible) {
              _visibleTransferWelcomes.remove(evidence.customer);
            }
            final incomingAt = extraction.latestIncomingSentAt;
            final headerNeedsRecovery =
                await _evidenceStore.needsHeaderRecovery(evidence, incomingAt);
            if (evidence.metadata['replyActivationAllowed'] == true &&
                evidence.metadata['acquisitionOnly'] != true &&
                headerNeedsRecovery &&
                recovery == null &&
                extraction.latestVisibleSenderIsIncoming &&
                incomingAt != null &&
                _handledIncomingSenderKeys[evidence.customer] !=
                    extraction.latestIncomingSenderKey) {
              final recoveryAt = await _evidenceStore.claimHeaderRecoveryAnchor(
                  evidence, incomingAt);
              _checkRun(epoch);
              if (recoveryAt != null) {
                await _beginUnreadRecovery(evidence.customer, 0,
                    detectedAt: recoveryAt);
                recovery = _unreadRecovery[evidence.customer];
              }
            }
            recovery?.latestIncomingSenderKey =
                extraction.latestIncomingSenderKey;
            // Media eligibility follows receipt/task ownership. Sender clocks
            // guide backfill navigation, never whether an input deserves a reply.
            if (mediaOnly &&
                (inspection.visualRegions.isNotEmpty ||
                    inspection.unboundMediaRegions.isNotEmpty ||
                    evidence.pinnedMedia != null)) {
              _visualMediaCaptures[evidence.customer] =
                  (_visualMediaCaptures[evidence.customer] ?? 0) + 1;
              visualCommitHeld = true;
            }
            _checkRun(epoch);
            final businessClaim = await _evidenceStore.refreshClaim(evidence);
            _checkRun(epoch);
            if (businessClaim == null) continue;
            evidence = businessClaim;
            final liveTextInputIds = <String>{};
            var capture = await _captureWithVisibleMedia(inspection, extraction,
                allowUnlabeledLatestImage: recovery != null ||
                    evidence.metadata['unreadArrivalKey'] != null,
                allowRecoveryAfterHolding: recovery?.holdingSent == true,
                registerOnly: !mediaOnly,
                evidence: evidence,
                liveTextInputIds: liveTextInputIds,
                manualCoverageExcludedIds: manualCoverageExcludedIds);
            if (_automationSessionId != null) {
              evidence = ViewportEvidence({
                ...evidence.metadata,
                'liveTextInputIds': liveTextInputIds.toList(),
              });
            }
            final firstSeen =
                await _evidenceStore.firstObserved(evidence.customer);
            final visibleTimes = <DateTime>[
              ...(capture?.messages ??
                      extraction.capture?.messages ??
                      const <CapturedMessage>[])
                  .where((m) => m.direction == 'incoming')
                  .map((m) => m.sentAt)
                  .whereType<DateTime>(),
              if (extraction.latestIncomingSentAt case final at?) at,
            ];
            String? coverageProgressKey;
            if (evidence.metadata['historyCutoffMs'] case final num cutoffMs) {
              final cutoff = DateTime.fromMillisecondsSinceEpoch(
                  cutoffMs.toInt(),
                  isUtc: true);
              if (visibleTimes.any(
                  (at) => !at.isAfter(cutoff.add(EvidenceCoverage.overlap)))) {
                if (await _evidenceStore.covered(evidence.customer,
                    cutoff: DateTime.fromMillisecondsSinceEpoch(
                        cutoffMs.toInt(),
                        isUtc: true))) {
                  coverageProgressKey = 'coverage:${cutoffMs.toInt()}:covered';
                }
              }
              if (visibleTimes.isNotEmpty) {
                final oldest =
                    visibleTimes.reduce((a, b) => a.isBefore(b) ? a : b);
                if (await _evidenceStore.reportBackfillProgress(
                    evidence.customer, cutoff, oldest)) {
                  coverageProgressKey =
                      'coverage:${cutoffMs.toInt()}:oldest:${oldest.millisecondsSinceEpoch}';
                  RuntimeTrace.record('evidence.backfill_progress', {
                    'customer': evidence.customer,
                    'cutoff': cutoff.toIso8601String(),
                    'oldestVerified': oldest.toIso8601String(),
                    'evidenceId': evidence.id,
                    'coverageConfirmed': false,
                  });
                }
              }
            } else if (firstSeen != null &&
                EvidenceCoverage.needsBackfill(
                    firstObserved: firstSeen,
                    capturedAt: evidence.capturedAt,
                    visibleIncoming: visibleTimes)) {
              await _evidenceStore.requestBackfill(evidence.customer, firstSeen,
                  stepPixels: _historyScrollStep(evidence));
              RuntimeTrace.record('evidence.coverage_gap', {
                'customer': evidence.customer,
                'firstObserved': firstSeen.toIso8601String(),
                'evidenceId': evidence.id
              });
            }
            _checkRun(epoch);
            if (capture != null) {
              capture = CapturedConversation(
                  stableKey: capture.stableKey,
                  customerName: capture.customerName,
                  customerExternalId: capture.customerExternalId,
                  capturedAt: capture.capturedAt,
                  messages: [
                    for (final message in capture.messages)
                      CapturedMessage(
                          stableId: message.stableId,
                          direction: message.direction,
                          body: message.body,
                          sender: message.sender,
                          sentAt: message.sentAt,
                          axPath: message.axPath,
                          media: message.media,
                          deliveryConfirmed: message.deliveryConfirmed,
                          observationTurnKey: message.observationTurnKey,
                          mediaReceiptId: message.mediaReceiptId,
                          captureEvidenceId:
                              message.captureEvidenceId ?? evidence.id),
                  ],
                  automationSessionId: _automationSessionId);
            }
            capture = _scopeAcquisitionCapture(evidence, capture);
            final inserted = capture == null
                ? 0
                : await _database.saveCapture(capture,
                    isCurrentViewport:
                        evidence.metadata['historyCutoffMs'] == null,
                    activateReplies:
                        evidence.metadata['replyActivationAllowed'] == true,
                    activeIncomingIds: _activeIncomingIds(evidence, capture),
                    manualCoverageExcludedIds: manualCoverageExcludedIds);
            await _mediaAudit.resolveCaptured(capture);
            await _evidenceStore.retireResolvedMedia(evidence.customer);
            final priorMediaRevision =
                await _mediaInventory.revision(evidence.customer);
            final upgradedPreviews = await _mediaInventory.persist(capture,
                verifiedAnchor: true, currentTaskOnly: true);
            // Publish the exact receipt family before even cached speech can
            // complete. Speech never holds a send or an evidence inbox worker.
            _scheduleVideoAudioEnrichment(capture);
            if (inserted > 0) _slaPreparedReplies.remove(evidence.customer);
            await _database.retireMediaPreviews(
                evidence.customer, upgradedPreviews);
            await _database.retireStaleMediaDraft(evidence.customer);
            if ((priorMediaRevision !=
                        await _mediaInventory.revision(evidence.customer) &&
                    _activeDraftMediaSensitive[evidence.customer] == true) &&
                _activeDraftMessageIds.containsKey(evidence.customer) &&
                _activeDraftCancellations[evidence.customer]?.isCancelled ==
                    false) {
              await _cancelGenerationForChangedInputs(evidence.customer, {
                'previewMessageIds': upgradedPreviews,
              });
            }
            if (inserted > 0) {
              final merged = await _database.mergeMediaCaptionBatch(
                  evidence.customer, capture);
              if (merged.contains(_activeDraftMessageIds[evidence.customer])) {
                _activeDraftCancellations[evidence.customer]?.cancel();
                final token = _activeDraftTokens[evidence.customer];
                if (token != null) {
                  await _database.abandonGeneration(evidence.customer, token);
                }
                // A save already racing cancellation is safe to retire only
                // while still unclicked. Never touch sending/unknown attempts.
                await _database.mergeMediaCaptionBatch(
                    evidence.customer, capture);
              }
            }
            final socialAt = _activeSocialTurnClocks[evidence.customer];
            if (inserted > 0 &&
                socialAt != null &&
                (capture?.messages ?? <CapturedMessage>[]).any((m) =>
                    m.direction == 'incoming' &&
                    m.media.isEmpty &&
                    m.body.isNotEmpty &&
                    m.sentAt != null &&
                    m.sentAt!.isAfter(socialAt) &&
                    !ResponseTimingPolicy.isSocialAcknowledgement(m.body))) {
              _activeDraftCancellations[evidence.customer]?.cancel();
              RuntimeTrace.record('generation.social_turn_superseded', {
                'customer': evidence.customer,
                'oldSenderAt': socialAt.toUtc().toIso8601String()
              });
            }
            final activeBatch = _activeDraftMessageIds[evidence.customer];
            if (activeBatch != null &&
                !await _database.isBatchUnanswered(
                    evidence.customer, activeBatch)) {
              _activeDraftCancellations[evidence.customer]?.cancel();
              RuntimeTrace.record('generation.cancelled_stale_batch', {
                'customer': evidence.customer,
                'batchEndMessageId': activeBatch
              });
            }
            RuntimeTrace.record('evidence.persisted', {
              'customer': evidence.customer,
              'evidenceId': evidence.id,
              'insertedMessageCount': inserted,
              'candidateMediaIds': [
                for (final message in capture?.messages ?? <CapturedMessage>[])
                  if (message.direction == 'incoming' &&
                      message.media.isNotEmpty)
                    message.stableId
              ],
              'messageIdSource': 'local_capture_not_platform_id',
              'queuedMessageId':
                  await _database.pendingMessageId(evidence.customer),
            });
            final auditedUnresolved =
                await _mediaAudit.unresolvedCount(evidence.id);
            // A verified/native-owned original can arrive without any Vision
            // rectangle (or with its sender header above the viewport). Keep its
            // acquisition lane even after the clear text was saved first.
            final pinAcquisitionPending = !mediaOnly &&
                (evidence.pinnedMedia != null ||
                    _evidencePins.containsKey(evidence.id));
            final unresolvedMedia = auditedUnresolved > 0
                ? auditedUnresolved
                : pinAcquisitionPending
                    ? 1
                    : 0;
            final mediaAuditStates = await _mediaAudit.stateCounts(evidence.id);
            final mediaBodyState = await _mediaInventory.bodyState(
                customer: evidence.customer,
                evidenceId: evidence.id,
                senderAt: extraction.latestIncomingSentAt);
            RuntimeTrace.record('capture.latest_body_state', {
              'customer': evidence.customer,
              'evidenceId': evidence.id,
              'senderAt':
                  extraction.latestIncomingSentAt?.toUtc().toIso8601String(),
              'hasText': extraction.latestIncomingHasText,
              'mediaState': mediaBodyState,
              'mediaAuditStates': mediaAuditStates,
              'acquisitionFailed': (mediaAuditStates['failed'] ?? 0) > 0,
              'capturePurpose': evidence.metadata['capturePurpose'],
            });
            final visibleBodyClipped =
                extraction.latestVisibleSenderIsIncoming &&
                    mediaBodyState == null &&
                    !extraction.latestIncomingHasText &&
                    unresolvedMedia == 0 &&
                    !(capture?.messages.any((m) =>
                            m.direction == 'incoming' && m.media.isNotEmpty) ??
                        false);
            final newestBodyMissing = headerNeedsRecovery && visibleBodyClipped;
            if (newestBodyMissing) {
              RuntimeTrace.record('capture.latest_customer_body_missing', {
                'customer': evidence.customer,
                'evidenceId': evidence.id,
                'senderAt':
                    extraction.latestIncomingSentAt?.toUtc().toIso8601String(),
                'redClockKnown':
                    _redClocks.remaining(evidence.customer) != null,
                'holdingDoesNotResolveContent': true
              });
            }
            if (!newestBodyMissing &&
                recovery != null &&
                await _hasRecoveredIncoming(recovery)) {
              await _database.capSlaFallbackDue(
                  userId: evidence.customer,
                  dueAt: recovery.detectedAt.add(_database.holdingDelay));
              if (recovery.holdingSentAt case final at?) {
                await _database.acknowledgeUncapturedHolding(
                    userId: evidence.customer, sentAt: at);
              }
              _finishUnreadRecovery(evidence.customer);
            }
            if (!newestBodyMissing &&
                capture != null &&
                capture.messages.isEmpty &&
                recovery != null &&
                !await _database.hasPendingUnanswered(evidence.customer)) {
              _finishUnreadRecovery(evidence.customer);
            }
            if ((capture == null || newestBodyMissing) &&
                unresolvedMedia == 0 &&
                (newestBodyMissing ||
                    (recovery != null &&
                        !await _hasRecoveredIncoming(recovery)))) {
              final cutoff = await _evidenceStore.backfillCutoffFor(evidence,
                  currentSignalAt: recovery?.detectedAt);
              await _evidenceStore.requestBackfill(evidence.customer, cutoff,
                  stepPixels: _historyScrollStep(evidence),
                  reopenCovered: true);
              RuntimeTrace.record('evidence.backfill_requested', {
                'customer': evidence.customer,
                'evidenceId': evidence.id,
                'reason': 'unread_without_extractable_incoming',
                'cutoffMs': cutoff.millisecondsSinceEpoch,
                'isProofOfMissingPlatformMessage': false,
              });
              // OCR completed for these immutable pixels. A clipped bubble is
              // recovered by another coverage page, not by retrying the same
              // successful OCR forever. Real media duties remain partial below.
            }
            await _database.reconcileOrphanSla(evidence.customer);
            if (capture != null &&
                evidence.metadata['historyCutoffMs'] == null &&
                await _database.refineResumedResponseClock(evidence.customer,
                    visibleIncomingIds: capture.messages
                        .where((m) => m.direction == 'incoming')
                        .map((m) => m.stableId),
                    capturedAt: capture.capturedAt)) {
              final cycle =
                  await _database.platformResponseCycle(evidence.customer);
              _redClocks.restartFromEvidence(
                  evidence.customer,
                  DateTime.fromMillisecondsSinceEpoch(
                      cycle!['started_at_ms']! as int));
              unawaited(_scheduleSlaFallback(evidence.customer));
            }
            await _database.ensurePendingForUnanswered(evidence.customer);
            if (_autoCaptureRunning &&
                await _database.hasPendingUnanswered(evidence.customer)) {
              _scheduleDraftGeneration(evidence.customer,
                  newEvidence: inserted > 0);
            }
            await _evidenceStore.complete(evidence,
                partial: unresolvedMedia > 0);
            if (!mediaOnly && coverageProgressKey != null) {
              final ownerKeys =
                  await _evidenceStore.currentAcquisitionOwnerKeys(evidence);
              _checkRun(epoch);
              if (ownerKeys.isNotEmpty) {
                await _evidenceStore.wakeMediaForProgress(evidence.customer,
                    progressKey: coverageProgressKey, ownerKeys: ownerKeys);
              }
            }
            if (!mediaOnly) unawaited(_drainEvidenceInbox(mediaOnly: true));
            if (unresolvedMedia > 0) {
              final bool retry;
              if (mediaOnly) {
                await _evidenceStore.waitForMediaProgress(evidence);
                retry = false;
              } else {
                retry = await _evidenceStore.retryMedia(evidence.id,
                    delay: Duration.zero, background: true);
              }
              if (!mediaOnly && retry) {
                unawaited(_drainEvidenceInbox(mediaOnly: true));
              }
              RuntimeTrace.record('media.pending_retry', {
                'customer': evidence.customer,
                'evidenceId': evidence.id,
                'scheduled': retry,
                'originalFrameRetained': true,
                'newerFramesMayOvertake': true,
                'blocksHolding': false,
                'blocksDelivery': false,
                'awaitsMaterialProgress': mediaOnly,
              });
            }
            if (unresolvedMedia > 0 && !mediaOnly) {
              final cutoff = await _evidenceStore.backfillCutoffFor(evidence,
                  currentSignalAt: recovery?.detectedAt);
              await _evidenceStore.requestBackfill(evidence.customer, cutoff,
                  stepPixels: _historyScrollStep(evidence),
                  reopenCovered: true);
              RuntimeTrace.record('media.backfill_requested', {
                'customer': evidence.customer,
                'evidenceId': evidence.id,
                'cutoffMs': cutoff.millisecondsSinceEpoch,
                'unresolvedObservations': unresolvedMedia,
                'reason': 'incomplete_media_capture',
                'isProofOfMissingPlatformMessage': false,
              });
            } else if (!visibleBodyClipped &&
                (recovery == null || await _hasRecoveredIncoming(recovery)) &&
                (capture?.messages.any((message) =>
                        message.direction == 'incoming' &&
                        message.media.any((media) => !media.isPartial)) ??
                    false) &&
                (await _mediaInventory.pendingMediaForTask(evidence.customer))
                    .isEmpty &&
                (await _mediaAudit.pendingUnboundForCustomer(evidence.customer))
                    .isEmpty) {
              // An exact original was persisted and no other acquisition owns
              // this customer's coverage. Restoring the viewport still runs.
              await _evidenceStore.covered(evidence.customer);
            }
            RuntimeTrace.record('evidence.extracted', {
              'customer': evidence.customer,
              'evidenceId': evidence.id,
              'messageCount': capture?.messages.length ?? 0,
              'outcome': unresolvedMedia > 0 ? 'partial' : 'extracted',
              'unresolvedMediaObservations': unresolvedMedia,
              'platformMessageCompleteness': 'unknown'
            });
            final coverage =
                await _evidenceStore.coverageState(evidence.customer);
            if (mounted) {
              setState(() {
                _ocrInspection = inspection;
                _diagnostics =
                    '已从保存画面提取 ${capture?.messages.length ?? 0} 条内容。${unresolvedMedia > 0 ? '有 $unresolvedMedia 个媒体候选尚未确认，原画面已保留。' : ''}${coverage == 'pending' || coverage == 'exhausted' ? '仍有范围缺口，未确认完整捕获。' : ''}$_visibleMediaTrace';
              });
            }
            await _coordinator.refresh();
            if (_autoCaptureRunning &&
                evidence.metadata['historyCutoffMs'] == null &&
                extraction.transferNoticeVisible &&
                extraction.latestVisibleSenderIsIncoming &&
                recovery != null) {
              try {
                await _withJdUiOperation(() => _handleTransferNotice(
                    evidence.customer,
                    extraction.transferNoticeKey ?? 'evidence:${evidence.id}'));
              } catch (error) {
                RuntimeTrace.record('transfer.welcome_failed', {
                  'customer': evidence.customer,
                  'evidenceId': evidence.id,
                  'errorCode': error is PlatformException
                      ? error.code
                      : error.runtimeType.toString(),
                  'extractionPreserved': true,
                });
              }
            }
          } on _AutomationStopped {
            return;
          } catch (error, stack) {
            if (epoch != _runEpoch || !_autoCaptureRunning) return;
            await _evidenceStore.fail(evidence, error);
            RuntimeTrace.record('evidence.extract_failed', {
              'customer': evidence.customer,
              'evidenceId': evidence.id,
              'error': '$error',
              'stack': '$stack',
              'errorCode': error is PlatformException
                  ? error.code
                  : error.runtimeType.toString()
            });
            if (mounted)
              setState(() => _diagnostics = '画面已保存，尚未完整提取；不会标记为已回复。');
          } finally {
            if (visualCommitHeld && epoch == _runEpoch) {
              final remaining =
                  (_visualMediaCaptures[evidence.customer] ?? 1) - 1;
              if (remaining <= 0) {
                _visualMediaCaptures.remove(evidence.customer);
              } else {
                _visualMediaCaptures[evidence.customer] = remaining;
              }
            }
          }
        }
        await _evidenceStore.pruneProcessed();
      } on _AutomationStopped {
        return;
      } catch (error, stack) {
        if (!_autoCaptureRunning || epoch != _runEpoch || !mounted) return;
        RuntimeTrace.record('evidence.inbox_failed',
            {'epoch': epoch, 'error': '$error', 'stack': '$stack'});
      }
    } finally {
      releaseDiagnosticWork();
    }
  }

  bool get _retryUiIdle => failedSendRetryCanRun(
        captureBusy: _autoCaptureBusy,
        activeSignalBusy: _activeChatSignalBusy,
        unreadSignalBusy: _unreadSignalBusy,
        deliveryBusy: _deliveryWorkerRunning,
        priorityUiBusy: _responseUiReserved,
        transferBusy: _transferringCustomers.isNotEmpty,
        incomingRecoveryPending:
            _unreadRecovery.isNotEmpty || _startingUnreadRecovery.isNotEmpty,
        fallbackPending: _slaFallbackTimers.isNotEmpty,
        draftingPending: _activeDraftUsers.isNotEmpty ||
            _draftQueue.isNotEmpty ||
            _batchCollectionTimers.isNotEmpty,
      );

  Future<void> _observeFailedSendInspection(
      FailedSendInspection inspection) async {
    final releaseDiagnosticWork = _diagnosticWork.acquire();
    try {
      try {
        var attributed = false;
        for (final candidate in inspection.candidates) {
          attributed = await _database.noteObservedRejection(
                  customer: inspection.customer,
                  body: candidate['bodyText']?.toString() ?? '',
                  fingerprint: candidate['fingerprint']?.toString() ?? '',
                  capturedAt: inspection.capturedAt) ||
              attributed;
        }
        if (attributed) {
          await _database.recoverDeliveryReceipts();
          JdV2Delivery.afterReceipts(_database);
        }
        if (mounted && _autoCaptureRunning) {
          setState(() => _error =
              '京麦显示 ${inspection.customer} 的发送失败标记，正在核实；未确认的回复不会被直接重发。');
        }
        _queueFailedSendRetry(inspection.customer, inspection.candidates,
            capturedAt: inspection.capturedAt);
      } catch (error) {
        RuntimeTrace.record('delivery.failed_bubble_observation_error', {
          'customer': inspection.customer,
          'error': error.runtimeType.toString()
        });
      }
    } finally {
      releaseDiagnosticWork();
    }
  }

  void _queueFailedSendRetry(
      String customer, List<Map<String, Object?>> candidates,
      {required DateTime capturedAt}) {
    _failedSendRetryTimer?.cancel();
    _failedSendRetryTimer = null;
    // Ordinary chats never enqueue retry work. A detected icon is optional
    // maintenance: skip instead of waiting behind capture, delivery, or SLA.
    if (candidates.isEmpty ||
        _failedSendRetryBusy ||
        !_autoCaptureRunning ||
        !mounted ||
        DateTime.now().difference(capturedAt) > const Duration(seconds: 15)) {
      return;
    }
    if (!_retryUiIdle || _pendingJdUiOperations != 0) {
      // Keep only this recently observed candidate, outside the UI queue.
      // This avoids starvation if the 2s capture and 3s OCR timers overlap.
      _failedSendRetryTimer = Timer(const Duration(milliseconds: 400), () {
        _queueFailedSendRetry(customer, candidates, capturedAt: capturedAt);
      });
      return;
    }
    _failedSendRetryBusy = true;
    // Do not delay the existing incoming-message/SLA poll behind the UI lock.
    unawaited(() async {
      try {
        await _withJdUiOperation(() async {
          if (!mounted ||
              !_autoCaptureRunning ||
              !_retryUiIdle ||
              _pendingJdUiOperations > 1 ||
              await _database.isHumanContacting(customer)) {
            return;
          }
          if (!_retryUiIdle ||
              _pendingJdUiOperations > 1 ||
              !_autoCaptureRunning ||
              !mounted) {
            return;
          }
          for (final candidate in candidates) {
            if (await _database.isDraftOwnedFailure(
                customer, candidate['fingerprint']?.toString() ?? '')) {
              RuntimeTrace.record('outgoing.retry_skipped', {
                'customer': customer,
                'fingerprint': candidate['fingerprint'],
                'reason': 'draft_queue_owns_rejected_attempt'
              });
              continue;
            }
            if (!_retryUiIdle ||
                _pendingJdUiOperations > 1 ||
                !_autoCaptureRunning ||
                !mounted) {
              break;
            }
            final retry = await _adapter.retryFailedOutgoingMessage(
                expectedCustomer: customer, candidate: candidate);
            if (retry['retried'] == true) {
              if (mounted) {
                setState(() => _diagnostics =
                    'Retried the existing failed JD message for $customer; no reply was regenerated or retyped.');
              }
              break; // One existing-icon click per poll, including multiple failures.
            }
          }
        });
      } catch (_) {
        // Retry inspection must never interrupt normal capture or generation.
      } finally {
        _failedSendRetryBusy = false;
      }
    }());
  }

  final Map<String, int> _recoveryNoticeDelegatedEpoch = {};

  void _armUnreadRecoveryTimers(UnreadCaptureRecovery recovery) {
    final customer = recovery.customer;
    _unreadHoldingTimers.remove(customer)?.cancel();
    _unreadResendTimers.remove(customer)?.cancel();
    if (_recoveryNoticeDelegatedEpoch[customer] == _runEpoch) return;
    // Discovery/cache ownership is independent of the platform warning clock.
    // A media card without an AX red marker must not start timeout notices.
    if (_redClocks.remaining(customer) == null) return;
    final now = DateTime.now();
    // Only the durable sidebar red-clock cycle owns timeout holding.
    if (recovery.holdingSent && !recovery.resendSent) {
      final due = recovery.resendDueAt;
      _unreadResendTimers[customer] = Timer(
        due.isAfter(now) ? due.difference(now) : Duration.zero,
        () => unawaited(_sendUnreadRecoveryNotice(recovery, resend: true)),
      );
    }
  }

  void _finishUnreadRecovery(String customer, {DateTime? handledAt}) {
    final recovery = _unreadRecovery.remove(customer);
    _unreadHoldingTimers.remove(customer)?.cancel();
    _unreadResendTimers.remove(customer)?.cancel();
    if (recovery != null) {
      _handledUnreadEvidence[customer] = recovery.unreadEvidence;
      _handledUnreadAt[customer] = handledAt ?? DateTime.now();
      _processingUnreadEvidence[customer] = recovery.unreadEvidence;
      if (recovery.latestIncomingSenderKey case final senderKey?) {
        _handledIncomingSenderKeys[customer] = senderKey;
      }
    }
  }

  Future<UnreadCaptureRecovery?> _bindObservedRow(
      String observed, String actual,
      {required int evidence, required DateTime detectedAt}) async {
    final epoch = _runEpoch;
    _checkRun(epoch);
    _redClocks.rebind(observed, actual);
    if (_liveUnreadArrivals[observed] case final arrival?) {
      if (!arrival.startsWith('arrival:new-row:') ||
          !_observedCaptureCustomers.contains(actual)) {
        _liveUnreadArrivals[actual] = arrival;
      }
    }
    if (observed == actual) {
      await _database.rebindPlatformResponse(observed, actual);
      _checkRun(epoch);
      await _database.wakeCurrentHandoffAfterIdentity(actual);
      unawaited(_scheduleSlaFallback(actual));
      return _unreadRecovery[actual];
    }
    if (MacOSCaptureAdapter.isProvisionalIdentity(actual) || actual.isEmpty) {
      throw PlatformException(code: 'row_identity_unconfirmed');
    }
    // Rebinding follows an independently confirmed native AX identity, so a
    // previous identity-mismatch quarantine may now be safely resumed.
    await _resumeVisibleConversations([actual], verifiedActive: [actual]);
    await _database.rebindPlatformResponse(observed, actual);
    _checkRun(epoch);
    await _database.wakeCurrentHandoffAfterIdentity(actual);
    unawaited(_scheduleSlaFallback(actual));
    final staged = _unreadRecovery[observed];
    final originalAt = staged?.detectedAt ??
        await _evidenceStore.firstObserved(observed) ??
        detectedAt;
    await _evidenceStore.rebindObservation(observed, actual);
    _checkRun(epoch);
    _finishUnreadRecovery(observed);
    _mediaAcquisition.remove(observed);
    var recovery = _unreadRecovery[actual];
    if (recovery == null) {
      await _beginUnreadRecovery(actual, evidence, detectedAt: originalAt);
      recovery = _unreadRecovery[actual];
    } else if (recovery.inheritDetection(originalAt, evidence)) {
      final document = await (await _database.history).read(actual);
      final messages = (document?['messages'] as List<Object?>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .toList();
      recovery.knownIncomingIds
        ..clear()
        ..addAll(_incomingIdentitySnapshot(messages));
      recovery.knownOutgoingIds
        ..clear()
        ..addAll(messages
            .where((message) => message['direction'] == 'outgoing')
            .map((m) => m['id']?.toString() ?? ''));
    }
    if (recovery != null) {
      if (staged?.holdingSent == true) {
        recovery.holdingSent = true;
        recovery.holdingSentAt ??= staged?.holdingSentAt;
      }
      recovery.resendSent = recovery.resendSent || staged?.resendSent == true;
      _armUnreadRecoveryTimers(recovery);
      await _database.capSlaFallbackDue(
          userId: actual,
          dueAt: recovery.detectedAt.add(_database.holdingDelay));
      RuntimeTrace.record('identity.recovery_rebound', {
        'observedRow': observed,
        'customer': actual,
        'detectedAt': recovery.detectedAt.toUtc().toIso8601String(),
        'ageMs': DateTime.now().difference(recovery.detectedAt).inMilliseconds,
        'deadlineReset': false,
      });
    }
    return recovery;
  }

  static Set<String> _incomingIdentitySnapshot(
          Iterable<Map<String, dynamic>> messages) =>
      {
        for (final message in messages)
          if (message['direction'] == 'incoming') ...{
            if (message['id'] case final String id when id.isNotEmpty) id,
            ...(message['observed_ids'] as List? ?? const [])
                .whereType<String>()
                .where((id) => id.isNotEmpty),
          },
      };

  Future<bool> _hasRecoveredIncoming(UnreadCaptureRecovery recovery) async {
    // A current pending input remains recovered even when it was stored before
    // the sidebar event or the OCR clock differs from the unread clock.
    if (await _database.hasPendingUnanswered(recovery.customer)) return true;
    final document = await (await _database.history).read(recovery.customer);
    final messages = (document?['messages'] as List<Object?>? ?? const [])
        .whereType<Map<String, dynamic>>();
    for (final message in messages) {
      if (message['direction'] != 'incoming') continue;
      final id = message['id']?.toString() ?? '';
      final identities = _incomingIdentitySnapshot([message]);
      if (id.isEmpty ||
          identities.any(recovery.knownIncomingIds.contains) ||
          !await _database.isCurrentSessionMessage(recovery.customer, id)) {
        continue;
      }
      return true;
    }
    return false;
  }

  Future<DateTime?> _newOutgoingAt(UnreadCaptureRecovery recovery) async {
    final document = await (await _database.history).read(recovery.customer);
    final messages = (document?['messages'] as List<Object?>? ?? const [])
        .whereType<Map<String, dynamic>>();
    DateTime? newest;
    for (final message in messages) {
      if (message['direction'] != 'outgoing' ||
          message['source'] == 'sla_fallback' ||
          message['delivery_status'] == 'delivery_unknown' ||
          message['delivery_status'] == 'unverified_observation' ||
          recovery.knownOutgoingIds.contains(message['id']?.toString() ?? '') ||
          isRecoveryReply(message['body'])) {
        continue;
      }
      final sentAt = DateTime.tryParse(message['sent_at']?.toString() ?? '') ??
          DateTime.tryParse(message['captured_at']?.toString() ?? '');
      if (sentAt == null || sentAt.isBefore(recovery.detectedAt)) continue;
      if (newest == null || sentAt.isAfter(newest)) newest = sentAt;
    }
    return newest;
  }

  Future<DateTime?> _holdingSentSinceRecovery(
      UnreadCaptureRecovery recovery) async {
    final document = await (await _database.history).read(recovery.customer);
    final messages = (document?['messages'] as List<Object?>? ?? const [])
        .whereType<Map<String, dynamic>>();
    return recovery.holdingReplySentAt(messages);
  }

  Future<void> _sendUnreadRecoveryNotice(UnreadCaptureRecovery recovery,
      {required bool resend}) async {
    final releaseDiagnosticWork = _diagnosticWork.acquire();
    try {
      if (_rowsWaitingVisibility.contains(recovery.customer)) return;
      if (!_autoCaptureRunning ||
          !identical(_unreadRecovery[recovery.customer], recovery) ||
          recovery.noticeSending) {
        return;
      }
      if (resend) {
        if (_redClocks.remaining(recovery.customer) == null) return;
        if (_recoveryNoticeDelegatedEpoch[recovery.customer] == _runEpoch)
          return;
        final cycle = await _database.platformResponseCycle(recovery.customer);
        final job = await _database.slaFallbackJob(recovery.customer);
        if (cycle != null ||
            await _database.hasActiveSlaFallback(recovery.customer)) {
          // The reservation would reject this recovery later. Do the same
          // check before acquiring a deadline lease or reopening a customer.
          // Keep detectedAt unchanged: it still owns cached-media evidence.
          _recoveryNoticeDelegatedEpoch[recovery.customer] = _runEpoch;
          _unreadResendTimers.remove(recovery.customer)?.cancel();
          RuntimeTrace.record('sla.recovery_notice_delegated', {
            'customer': recovery.customer,
            'cycleId': cycle?['cycle_id'],
            'cycleState': cycle?['state'],
            'dueAt': job?.dueAt.toUtc().toIso8601String(),
            'due': job != null && !DateTime.now().isBefore(job.dueAt),
            'reason': 'durable_response_cycle_owns_notice',
            'uiAcquired': false,
            'mediaDetectionClockPreserved': true,
          });
          if (job != null) unawaited(_scheduleSlaFallback(recovery.customer));
          return;
        }
      }
      if (!resend) {
        final cycle = await _database.platformResponseCycle(recovery.customer);
        final started = cycle?['started_at_ms'] as int?;
        // Old recovery timers survive a pause for evidence recovery. They must
        // never override the currently observed red round or open it early.
        final remaining = _redClocks.remaining(recovery.customer);
        if (cycle?['state'] != 'waiting' ||
            started == null ||
            (remaining != null
                ? remaining > Duration.zero
                : DateTime.now().millisecondsSinceEpoch <
                    started + _database.holdingDelay.inMilliseconds)) {
          unawaited(_scheduleSlaFallback(recovery.customer));
          return;
        }
      }
      if (!_adapter.rowResolutionDue(recovery.customer)) {
        _retryUnreadRecoveryNotice(recovery, resend: resend);
        return;
      }
      if (await _database.isConversationUnavailable(recovery.customer)) return;
      if (resend && await _transferWorkOwnsUi()) {
        _retryUnreadRecoveryNotice(recovery, resend: true);
        return;
      }
      if (resend &&
          !MacOSCaptureAdapter.isProvisionalIdentity(recovery.customer)) {
        final pending = await _mediaAudit.pendingForCustomer(recovery.customer,
            before: DateTime.now().toUtc());
        if (pending.isNotEmpty) {
          RuntimeTrace.record('media.resend_notice_deferred', {
            'customer': recovery.customer,
            'pendingEvidenceCount': pending.length,
            'reason': 'received_media_still_awaiting_verified_original',
          });
          if (_autoCaptureRunning &&
              identical(_unreadRecovery[recovery.customer], recovery)) {
            _unreadResendTimers.remove(recovery.customer)?.cancel();
            _unreadResendTimers[recovery.customer] = Timer(
                const Duration(seconds: 30),
                () => unawaited(
                    _sendUnreadRecoveryNotice(recovery, resend: true)));
          }
          return;
        }
      }
      recovery.noticeSending = true;
      try {
        if (MacOSCaptureAdapter.isProvisionalIdentity(recovery.customer)) {
          UnreadCaptureRecovery? canonical;
          await _withFallbackPriority(() async {
            if (!_autoCaptureRunning ||
                !identical(_unreadRecovery[recovery.customer], recovery)) {
              return;
            }
            await _adapter.openConversation(recovery.customer,
                allowActivation: true);
            final actual = _adapter.verifiedCustomerIdentity(recovery.customer);
            canonical = await _bindObservedRow(recovery.customer, actual,
                evidence: recovery.unreadEvidence,
                detectedAt: recovery.detectedAt);
          },
              deadline: recovery.detectedAt.add(_database.holdingDelay),
              preemptTransfer: !resend);
          if (canonical != null && _autoCaptureRunning) {
            await _sendUnreadRecoveryNotice(canonical!, resend: resend);
          }
          return;
        }

        await _withFallbackPriority(() async {
          if (!_autoCaptureRunning ||
              !identical(_unreadRecovery[recovery.customer], recovery) ||
              await _database.isConversationUnavailable(recovery.customer)) {
            return;
          }
          if (await _database.isHumanContacting(recovery.customer)) {
            _finishUnreadRecovery(recovery.customer);
            return;
          }
          if (await _newOutgoingAt(recovery) case final sentAt?) {
            _finishUnreadRecovery(recovery.customer, handledAt: sentAt);
            return;
          }
          if (!resend) {
            if (await _holdingSentSinceRecovery(recovery) case final sentAt?) {
              recovery.holdingSent = true;
              recovery.holdingSentAt = sentAt;
              _armUnreadRecoveryTimers(recovery);
              return;
            }
          }
          if (await _hasRecoveredIncoming(recovery)) {
            if (recovery.holdingSentAt case final sentAt?) {
              await _database.acknowledgeUncapturedHolding(
                  userId: recovery.customer, sentAt: sentAt);
              _slaFallbackTimers.remove(recovery.customer)?.cancel();
            }
            _finishUnreadRecovery(recovery.customer);
            _scheduleDraftGeneration(recovery.customer, newEvidence: false);
            return;
          }
          if (!resend &&
              await _database.hasActiveSlaFallback(recovery.customer,
                  excludingMessageIds: recovery.knownIncomingIds)) {
            // OCR already captured this turn. Its durable SLA row owns the only
            // holding message and draft generation; never race a second send.
            _finishUnreadRecovery(recovery.customer);
            unawaited(_scheduleSlaFallback(recovery.customer));
            _scheduleDraftGeneration(recovery.customer, newEvidence: false);
            return;
          }
          final now = DateTime.now();
          if (resend
              ? !recovery.resendDue(now)
              : !recovery.holdingDue(now,
                  holdingDelay: _database.holdingDelay)) {
            return;
          }
          final preClickDeadline = _replyClickDeadline(recovery.detectedAt);
          await _directDelivery.open(recovery.customer,
              preClickDeadline: preClickDeadline);
          if (!_autoCaptureRunning ||
              !identical(_unreadRecovery[recovery.customer], recovery)) {
            return;
          }
          if (await _database.isHumanContacting(recovery.customer)) {
            _finishUnreadRecovery(recovery.customer);
            return;
          }
          if (await _newOutgoingAt(recovery) case final sentAt?) {
            _finishUnreadRecovery(recovery.customer, handledAt: sentAt);
            return;
          }
          if (!resend) {
            if (await _holdingSentSinceRecovery(recovery) case final sentAt?) {
              recovery.holdingSent = true;
              recovery.holdingSentAt = sentAt;
              _armUnreadRecoveryTimers(recovery);
              return;
            }
          }
          if (await _hasRecoveredIncoming(recovery)) {
            if (recovery.holdingSentAt case final sentAt?) {
              await _database.acknowledgeUncapturedHolding(
                  userId: recovery.customer, sentAt: sentAt);
              _slaFallbackTimers.remove(recovery.customer)?.cancel();
            }
            _finishUnreadRecovery(recovery.customer);
            _scheduleDraftGeneration(recovery.customer, newEvidence: false);
            return;
          }
          final reply = FixedReplies.text(
              resend ? FixedReplies.resend : FixedReplies.uncapturedHolding,
              ChineseOnlyReplyPolicy.language);
          final recoveryJob = await _database.reserveRecoveryFallback(
              userId: recovery.customer,
              detectedAt: recovery.detectedAt,
              resend: resend);
          if (recoveryJob == null) {
            unawaited(_scheduleSlaFallback(recovery.customer));
            return;
          }
          try {
            final attempt = await _database.beginSlaAttempt(recoveryJob, reply);
            await _directDelivery.sendConfirmed(
                customer: recovery.customer,
                reply: reply,
                mediaPaths: const [],
                attemptId: attempt['attemptId'],
                receiptPath: attempt['receiptPath'],
                preClickDeadline: preClickDeadline,
                requireRedClock: !resend);
            await _database.markSlaFallbackSent(
                userId: recovery.customer,
                messageId: recoveryJob.messageId,
                reply: reply,
                batchStartMessageId:
                    recoveryJob.batchStartMessageId ?? recoveryJob.messageId,
                nativeConfirmed: true);
          } catch (error) {
            await _database.releaseSlaFallback(
                userId: recovery.customer, messageId: recoveryJob.messageId);
            rethrow;
          }
          final sentAt = DateTime.now();
          RuntimeTrace.record('sla.recovery_sent', {
            'replyKind': 'holding',
            'businessResponseSent': false,
            'caseResolved': null,
            'customer': recovery.customer,
            'ageMs': sentAt.difference(recovery.detectedAt).inMilliseconds,
            'resend': resend
          });
          if (resend) {
            recovery.resendSent = true;
          } else {
            recovery.holdingSent = true;
            recovery.holdingSentAt = sentAt;
            _armUnreadRecoveryTimers(recovery);
          }
          try {
            if (!resend) {
              await _database.acknowledgeUncapturedHolding(
                  userId: recovery.customer, sentAt: sentAt);
              _slaFallbackTimers.remove(recovery.customer)?.cancel();
            }
          } catch (error) {
            // JD already confirmed the send. Never repeat it merely because
            // local history storage failed afterward.
            if (mounted) {
              setState(() {
                _error = error;
                RuntimeTrace.record('ui.error', {'error': '$error'});
              });
            }
          }
          if (mounted) {
            setState(() => _diagnostics = resend
                ? 'Asked ${recovery.customer} to resend content that could not be captured.'
                : 'Sent a holding message to ${recovery.customer} while capture retries continue.');
          }
        },
            deadline: resend
                ? recovery.resendDueAt
                : recovery.detectedAt.add(_database.holdingDelay),
            preemptTransfer: !resend);
      } on PlatformException catch (error) {
        // A notice that was not confirmed returns to its retry timer instead of
        // permanently resolving this recovery without a customer-visible send.
        if (_isMissingConversation(error)) {
          await _suspendMissingConversation(recovery.customer, error);
        } else {
          _retryUnreadRecoveryNotice(recovery, resend: resend);
        }
        if (mounted) {
          setState(() {
            _error = error;
            RuntimeTrace.record('ui.error', {'error': '$error'});
          });
        }
      } catch (error) {
        _retryUnreadRecoveryNotice(recovery, resend: resend);
        if (mounted) {
          setState(() {
            _error = error;
            RuntimeTrace.record('ui.error', {'error': '$error'});
          });
        }
      } finally {
        recovery.noticeSending = false;
      }
    } finally {
      releaseDiagnosticWork();
    }
  }

  void _retryUnreadRecoveryNotice(UnreadCaptureRecovery recovery,
      {required bool resend}) {
    if (!_autoCaptureRunning ||
        !mounted ||
        !identical(_unreadRecovery[recovery.customer], recovery)) {
      return;
    }
    final timers = resend ? _unreadResendTimers : _unreadHoldingTimers;
    timers.remove(recovery.customer)?.cancel();
    if (_adapter.rowResolutionSuspended(recovery.customer)) return;
    final retryAt = _adapter.rowResolutionRetryAt(recovery.customer);
    final delay =
        retryAt?.difference(DateTime.now()) ?? const Duration(seconds: 2);
    timers[recovery.customer] = Timer(
      delay > Duration.zero ? delay : const Duration(seconds: 2),
      () => unawaited(_sendUnreadRecoveryNotice(recovery, resend: resend)),
    );
  }

  bool get _usesHostedReplies =>
      widget.draftSchedulerOverride == null &&
      widget.generateDraftOverride == null &&
      (widget.replyServiceOverride == null ||
          widget.replyServiceOverride is HostedReplyService);

  void _startHostedPrefetch(String customer) {
    if (!_autoCaptureRunning ||
        !_usesHostedReplies ||
        MacOSCaptureAdapter.isProvisionalIdentity(customer)) return;
    final epoch = _runEpoch;
    bool active() => mounted && _autoCaptureRunning && epoch == _runEpoch;
    void completed(HostedReplyCompletion completion) {
      if (!active() || completion.expectedSessionId != _automationSessionId)
        return;
      if (_hostedCompletedJobs.contains(completion.jobId)) return;
      _hostedCompletionQueues
          .putIfAbsent(customer, () => {})
          .putIfAbsent(completion.jobId, () => completion);
      RuntimeTrace.record('delivery.api_result_received', {
        'customer': customer,
        'messageId': completion.sourceMessageId,
        'jobId': completion.jobId,
        'receivedAt': completion.receivedAt.toUtc().toIso8601String()
      });
      unawaited(_drainHostedCompletions(customer, epoch));
    }

    void failed(Object error) {
      if (!active()) return;
      RuntimeTrace.record('generation.api_prefetch_failed',
          {'customer': customer, 'errorCode': error.runtimeType.toString()});
      setState(() => _error = error);
    }

    final injected = widget.replyServiceOverride;
    final work = injected is HostedReplyService
        ? injected.prefetchPending(customer, _database,
            onCompleted: completed,
            onError: failed,
            currentServiceAccount: _adapter.currentServiceAccount,
            isActive: active)
        : HostedReplyService.prefetch(customer, _database,
            onCompleted: completed,
            onError: failed,
            currentServiceAccount: _adapter.currentServiceAccount,
            isActive: active);
    unawaited(work.catchError(failed));
  }

  void _armHostedCompletionRetry(String customer, int epoch) {
    _hostedCompletionTimers.remove(customer)?.cancel();
    if (!_autoCaptureRunning || epoch != _runEpoch) return;
    final queue = _hostedCompletionQueues[customer];
    if (queue == null || queue.isEmpty) return;
    final times = queue.keys
        .map((id) => _hostedCompletionRetryAt[id])
        .whereType<DateTime>()
        .toList()
      ..sort();
    if (times.isEmpty) return;
    final delay = times.first.difference(DateTime.now());
    _hostedCompletionTimers[customer] =
        Timer(delay.isNegative ? Duration.zero : delay, () {
      _hostedCompletionTimers.remove(customer);
      if (_autoCaptureRunning && epoch == _runEpoch) {
        unawaited(_drainHostedCompletions(customer, epoch));
      }
    });
  }

  Future<void> _drainHostedCompletions(String customer, int epoch) async {
    final releaseDiagnosticWork = _diagnosticWork.acquire();
    try {
      if (!_autoCaptureRunning ||
          epoch != _runEpoch ||
          !_hostedCompletionBusy.add(customer)) return;
      var waitingForNative = false;
      try {
        final queue = _hostedCompletionQueues[customer];
        while (_autoCaptureRunning &&
            epoch == _runEpoch &&
            queue != null &&
            queue.isNotEmpty) {
          // Reconcile the uncertain message independently. Only an actual
          // active delivery may retain this customer's native draft slot.
          await _database.isolateUncertainDelivery(customer);
          _checkRun(epoch);
          if (await _database.hasUndeliveredDraft(customer)) {
            waitingForNative = true;
            _requestDelivery();
            return;
          }
          final completion = queue.values
              .where((item) =>
                  _hostedCompletionRetryAt[item.jobId]
                      ?.isAfter(DateTime.now()) !=
                  true)
              .firstOrNull;
          if (completion == null) return;
          if (completion.expectedSessionId != _automationSessionId) {
            queue.remove(completion.jobId);
            continue;
          }
          final db = await _database.database;
          final pending = await db.query('pending_customers',
              columns: ['id'],
              where: 'user_id=?',
              whereArgs: [customer],
              limit: 1);
          if (pending.isEmpty) {
            queue.remove(completion.jobId);
            continue;
          }
          final pendingId = pending.single['id'] as int;
          final claim = await _database.beginCompletedApiDelivery(
              customer: customer,
              pendingId: pendingId,
              source: completion.source,
              expectedSessionId: completion.expectedSessionId);
          if (claim == null) {
            final states = await db.query('automation_session_messages',
                columns: ['response_state'],
                where: 'session_id=? AND user_id=? AND message_id=?',
                whereArgs: [
                  completion.expectedSessionId,
                  customer,
                  completion.sourceMessageId
                ]);
            if (states.isNotEmpty &&
                states.every((row) => row['response_state'] != 'pending')) {
              queue.remove(completion.jobId);
              _hostedCompletedJobs.add(completion.jobId);
              continue;
            }
            // Only this result is deferred; another completed message can proceed.
            _hostedCompletionRetryAt[completion.jobId] =
                DateTime.now().add(const Duration(seconds: 2));
            continue;
          }
          try {
            final injected = widget.replyServiceOverride;
            final service = injected is HostedReplyService
                ? injected
                : await HostedReplyService.discoverHosted(_database);
            late AiDraft draft;
            try {
              draft = await service.finishCompletion(completion, _database,
                  currentServiceAccount: _adapter.currentServiceAccount);
            } finally {
              if (!identical(service, injected) && service.ownsClient)
                service.client.close();
            }
            _checkRun(epoch);
            final frozen = [Map<String, dynamic>.from(completion.source)];
            final explicitTransfer = JdV2Payload.requestsTransfer(draft);
            final saved = await _database.saveCompletedApiDraft(
                pendingId: pendingId,
                customer: customer,
                draft: draft,
                source: completion.source,
                generationToken: claim.token,
                deliverable: !explicitTransfer);
            _checkRun(epoch);
            if (saved.outcome != AutomaticDraftSaveOutcome.transferOnly) {
              queue.remove(completion.jobId);
              _hostedCompletedJobs.add(completion.jobId);
              _hostedCompletionRetryAt.remove(completion.jobId);
            }
            RuntimeTrace.record('delivery.api_result_queued', {
              'customer': customer,
              'messageId': completion.sourceMessageId,
              'jobId': completion.jobId,
              'outcome': saved.outcome.name,
              'elapsedSinceApiMs': DateTime.now()
                  .difference(completion.receivedAt)
                  .inMilliseconds
            });
            if (saved.outcome == AutomaticDraftSaveOutcome.ready) {
              unawaited(_yieldUnclickedHoldingForFormal(customer));
              _completedApiDeliveryCustomers.add(customer);
              _requestDelivery();
            }
            if (saved.outcome == AutomaticDraftSaveOutcome.needsAnswer ||
                saved.outcome == AutomaticDraftSaveOutcome.awaitingDependency) {
              if (mounted)
                setState(
                    () => _diagnostics = '$customer 的原消息仍未形成正式答复，保留未回复状态。');
            } else if (draftRequiresHumanReview(draft) &&
                saved.outcome != AutomaticDraftSaveOutcome.stale) {
              final ticket = await _database.createHumanReviewTicket(
                  userId: customer,
                  customerRequest: explicitTransfer
                      ? handoffContextSummary(frozen)
                      : completion.source['body']?.toString() ?? '',
                  reason: draftHumanReviewReason(draft),
                  requestMessageId:
                      explicitTransfer ? completion.sourceMessageId : null);
              if (explicitTransfer) {
                _checkRun(epoch);
                await _autoTransferTicket(ticket);
              }
              unawaited(_refreshTickets());
            }
            // Presentation refresh cannot run ahead of a newly ready send.
            if (saved.outcome != AutomaticDraftSaveOutcome.ready) {
              unawaited(_coordinator.refresh());
            }
          } catch (error) {
            if (error is _AutomationStopped) rethrow;
            _checkRun(epoch);
            RuntimeTrace.record('delivery.api_result_failed', {
              'customer': customer,
              'messageId': completion.sourceMessageId,
              'jobId': completion.jobId,
              'errorCode': error.runtimeType.toString()
            });
            if (mounted) setState(() => _error = error);
            // A rejected result stays locally visible as unanswered; it cannot
            // retain another message's completed reply behind it.
            if (error is JdV2ApiException &&
                error.code == 'unsupported_action_or_empty_answer') {
              queue.remove(completion.jobId);
              _hostedCompletedJobs.add(completion.jobId);
            } else {
              _hostedCompletionRetryAt[completion.jobId] =
                  DateTime.now().add(const Duration(seconds: 10));
            }
            continue;
          } finally {
            if (epoch == _runEpoch)
              await _database.abandonGeneration(customer, claim.token);
          }
        }
        if (epoch == _runEpoch &&
            queue?.isEmpty == true &&
            identical(_hostedCompletionQueues[customer], queue)) {
          _hostedCompletionQueues.remove(customer);
        }
      } catch (error) {
        if (error is! _AutomationStopped && mounted && epoch == _runEpoch) {
          setState(() => _error = error);
          RuntimeTrace.record('delivery.api_completion_failed', {
            'customer': customer,
            'errorCode': error.runtimeType.toString()
          });
        }
      } finally {
        if (epoch == _runEpoch) {
          _hostedCompletionBusy.remove(customer);
          if (waitingForNative) {
            _hostedCompletionTimers.remove(customer)?.cancel();
          } else {
            _armHostedCompletionRetry(customer, epoch);
          }
        }
      }
    } finally {
      releaseDiagnosticWork();
    }
  }

  void _scheduleDraftGeneration(String userId, {required bool newEvidence}) {
    if (!_autoCaptureRunning) return;
    if (widget.draftSchedulerOverride case final scheduler?) {
      scheduler(userId);
      return;
    }
    unawaited(_scheduleSlaFallback(userId));
    if (_usesHostedReplies) {
      // Launch independent API work before any per-customer delivery/worker
      // gate. New messages must not wait for an earlier answer's generation.
      _startHostedPrefetch(userId);
      unawaited(_drainHostedCompletions(userId, _runEpoch));
      return;
    }
    if (newEvidence) {
      _draftRetryTimers.remove(userId)?.cancel();
      // Anchor collection to the first received input. Continuous incoming
      // messages join the first frozen batch without postponing it forever.
      if (_batchCollectionTimers.containsKey(userId)) return;
      _batchCollectionTimers[userId] = Timer(
          widget.batchCollectionWindowOverride ?? _batchCollectionWindow, () {
        _batchCollectionTimers.remove(userId);
        unawaited(_queueDraftIfPending(userId));
      });
      return;
    }
    if (_batchCollectionTimers.containsKey(userId)) return;
    if (!newEvidence &&
        (_draftRetryTimers.containsKey(userId) ||
            _draftQueue.contains(userId) ||
            _activeDraftUsers.contains(userId))) {
      return;
    }
    unawaited(_queueDraftIfPending(userId));
  }

  void _wakeGenerationAfterFormalCommit(String userId) {
    if (!_autoCaptureRunning ||
        MacOSCaptureAdapter.isProvisionalIdentity(userId)) {
      return;
    }
    if (_usesHostedReplies) {
      unawaited(_drainHostedCompletions(userId, _runEpoch));
      return;
    }
    _batchCollectionTimers.remove(userId)?.cancel();
    _draftQueue.add(userId);
    _runDraftWorkers();
  }

  Future<void> _queueDraftIfPending(String userId) async {
    if (!_autoCaptureRunning) {
      return;
    }
    final epoch = _runEpoch;
    if (MacOSCaptureAdapter.isProvisionalIdentity(userId)) return;
    if (_usesHostedReplies) {
      await _drainHostedCompletions(userId, epoch);
      return;
    }
    await _database.detachUnknownForNewInput(userId);
    if (!await _database.generationDue(userId)) return;
    if (await _database.isConversationUnavailable(userId) ||
        !await _database.hasPendingUnanswered(userId) ||
        await _database.isHumanContacting(userId)) {
      return;
    }
    if (_activeDraftUsers.contains(userId) ||
        await _database.hasUndeliveredDraft(userId)) {
      return;
    }
    final pendingMessageId = await _database.pendingMessageId(userId);
    if (pendingMessageId == null ||
        !_autoCaptureRunning ||
        epoch != _runEpoch ||
        _activeDraftUsers.contains(userId)) {
      return;
    }
    // Generate from already durable inputs while optional media acquisition
    // continues. A material receipt upgrade invalidates the frozen revision;
    // continuous captures must never starve a formal reply.
    _draftQueue.add(userId);
    _runDraftWorkers();
  }

  Future<void> _scheduleSlaFallback(String userId,
      {Duration minimumDelay = Duration.zero}) async {
    if (!_autoCaptureRunning) return;
    final epoch = _runEpoch;
    final previousTimer = _slaFallbackTimers[userId];
    final job = await _database.slaFallbackJob(userId);
    final pending =
        job != null && await _database.isPlatformResponsePending(job);
    if (!_autoCaptureRunning || epoch != _runEpoch) return;
    if (!pending) {
      if (identical(_slaFallbackTimers[userId], previousTimer)) {
        _forgetSlaTimer(userId);
      }
      return;
    }
    _armSlaFallback(job, minimumDelay: minimumDelay);
  }

  void _forgetSlaTimer(String customer, {String? expectedCycleId}) {
    if (expectedCycleId != null &&
        _slaTimerPlans[customer]?.cycle != expectedCycleId) {
      return;
    }
    _slaFallbackTimers.remove(customer)?.cancel();
    _slaTimerPlans.remove(customer);
    _slaUiDeadlines.remove(customer);
  }

  void _armSlaFallback(SlaFallbackJob job,
      {Duration minimumDelay = Duration.zero}) {
    if (_slaDispatchInFlight.contains(job.userId) ||
        MacOSCaptureAdapter.isProvisionalIdentity(job.userId)) {
      return;
    }
    final plan = (
      cycle: job.batchStartMessageId ?? job.messageId,
      due: job.dueAt,
      retry: job.retryAt,
    );
    // Repeated sidebar observations are samples of the same red clock. Keep
    // its wake rather than continually cancelling it under multi-user load.
    if (_slaTimerPlans[job.userId] == plan &&
        _slaFallbackTimers[job.userId]?.isActive == true) {
      return;
    }
    if (_slaTimerPlans[job.userId]?.cycle != plan.cycle) {
      _slaPreparationTimers.remove(job.userId)?.cancel();
      _slaPreparedReplies.remove(job.userId);
    }
    _slaFallbackTimers.remove(job.userId)?.cancel();
    _slaTimerPlans[job.userId] = plan;
    _slaUiDeadlines[job.userId] = job.dueAt;
    final retryDelay = job.retryAt?.difference(DateTime.now()) ?? Duration.zero;
    final minimum = retryDelay > minimumDelay ? retryDelay : minimumDelay;
    final localRemaining = _redClocks.remaining(job.userId);
    final remaining = localRemaining ?? job.dueAt.difference(DateTime.now());
    final preparationKey = '${job.userId}:${job.batchStartMessageId}';
    if (remaining > Duration.zero &&
        !_slaPreparedCycles.contains(preparationKey) &&
        !_slaPreparingCustomers.contains(job.userId) &&
        !_slaPreparationTimers.containsKey(job.userId)) {
      _slaPreparationTimers[job.userId] =
          Timer(ResponseTimingPolicy.preparationDelay(remaining), () {
        _slaPreparationTimers.remove(job.userId);
        unawaited(_prepareSlaConversation(job));
      });
    }
    final delay = localRemaining == null
        ? ResponseTimingPolicy.delayUntilDispatch(job.dueAt, DateTime.now(),
            minimumDelay: minimum)
        : (localRemaining - ResponseTimingPolicy.dispatchLead > minimum
            ? localRemaining - ResponseTimingPolicy.dispatchLead
            : minimum);
    RuntimeTrace.record('sla.timer_armed', {
      'customer': job.userId,
      'cycleId': job.batchStartMessageId,
      'dueAt': job.dueAt.toUtc().toIso8601String(),
      'dispatchInMs': delay.inMilliseconds,
      'retryAt': job.retryAt?.toIso8601String()
    });
    _slaFallbackTimers[job.userId] = Timer(delay, () {
      if (_slaTimerPlans[job.userId] != plan) return;
      RuntimeTrace.record('sla.timer_fired',
          {'customer': job.userId, 'cycleId': job.batchStartMessageId});
      _slaFallbackTimers.remove(job.userId);
      unawaited(_sendSlaFallback(job));
    });
  }

  Future<bool> _hasReplySinceSlaMessage(SlaFallbackJob job) async {
    // A platform response cycle is not an incoming message ID. Its completion
    // is proved by the exact cycle's receipt, never by scanning old bubbles.
    if (job.messageId.startsWith('response-cycle:')) {
      return _database.hasConfirmedResponseForCycle(job);
    }
    final document = await (await _database.history).read(job.userId);
    final messages = (document?['messages'] as List<Object?>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList(growable: false);
    final incoming = messages
        .where((message) =>
            message['id'] == job.messageId &&
            message['direction'] == 'incoming')
        .firstOrNull;
    if (incoming == null) return false;
    final formallyAnswered =
        await _database.isMessageFormallyAnswered(job.userId, job.messageId);
    if (_automationSessionId != null || formallyAnswered) {
      return formallyAnswered;
    }
    final matched = messages
        .where((message) => ResponseTimingPolicy.isReplyForBatch(message,
            batchEndMessageId: job.messageId,
            isHolding: _isOwnHoldingReply(message['body']?.toString())))
        .firstOrNull;
    if (matched != null) {
      RuntimeTrace.record('sla.reply_coverage_confirmed', {
        'customer': job.userId,
        'messageId': job.messageId,
        'proof': 'answered_batch_end_id',
        'replyId': matched['id']
      });
    }
    return matched != null;
  }

  void _recordSlaSkipped(SlaFallbackJob job, String reason, String stage) =>
      RuntimeTrace.record('sla.skipped', {
        'customer': job.userId,
        'messageId': job.messageId,
        'batchStartMessageId': job.batchStartMessageId,
        'reason': reason,
        'stage': stage
      });

  final Set<String> _slaDispatchInFlight = {};
  final Map<String, DateTime> _slaUiDeadlines = {};
  final Map<String, ({String cycle, DateTime due, DateTime? retry})>
      _slaTimerPlans = {};
  final Map<String, ({SlaFallbackJob job, String attemptId, int epoch})>
      _nativeSlaAttempts = {};

  DateTime _replyClickDeadline(DateTime responseStarted) {
    final now = DateTime.now();
    final platformLimit = responseStarted.add(const Duration(seconds: 28));
    final bounded = now.add(const Duration(seconds: 6));
    if (!platformLimit.isAfter(now)) {
      RuntimeTrace.record('delivery.overdue_bounded_attempt', {
        'responseStartedAt': responseStarted.toUtc().toIso8601String(),
        'budgetMs': 6000
      });
      return bounded;
    }
    return platformLimit.isBefore(bounded) ? platformLimit : bounded;
  }

  final Map<String, Timer> _slaPreparationTimers = {};
  final Set<String> _slaPreparedCycles = {};
  final Set<String> _slaPreparingCustomers = {};
  final Map<String, ({String? cycle, String reply})> _slaPreparedReplies = {};

  Future<String> _holdingReplyForJob(SlaFallbackJob job) async {
    final document = await (await _database.history).read(job.userId);
    final messages = (document?['messages'] as List? ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList();
    final text = messages
            .where((message) => message['direction'] == 'incoming')
            .map((message) => message['body']?.toString() ?? '')
            .where(
                (body) => body.isNotEmpty && !body.startsWith('[Customer sent'))
            .lastOrNull ??
        '';
    return chooseHoldingReply(text, language: ChineseOnlyReplyPolicy.language);
  }

  Future<void> _prepareSlaConversation(SlaFallbackJob job) async {
    final releaseDiagnosticWork = _diagnosticWork.acquire();
    try {
      if (!_autoCaptureRunning ||
          _slaDispatchInFlight.contains(job.userId) ||
          !_slaPreparingCustomers.add(job.userId)) {
        return;
      }
      final epoch = _runEpoch;
      try {
        final remaining = _redClocks.remaining(job.userId) ??
            job.dueAt.difference(DateTime.now());
        if (remaining <= ResponseTimingPolicy.dispatchLead) return;
        if (!await _database.isPlatformResponsePending(job) ||
            await _database.isHumanContacting(job.userId)) {
          return;
        }
        final reply = await _holdingReplyForJob(job);
        _checkRun(epoch);
        _slaPreparedReplies[job.userId] =
            (cycle: job.batchStartMessageId, reply: reply);
        // Do not queue a speculative switch behind active sends. Cache the
        // wording above so the actual deadline job will not repeat file work.
        if (_pendingJdUiOperations > 0 ||
            _priorityUiOperations > 0 ||
            await _transferWorkOwnsUi()) {
          RuntimeTrace.record('sla.preparation_deferred',
              {'customer': job.userId, 'reason': 'ui_transaction_in_progress'});
          return;
        }
        final earlier = await _database.responseSlotOwner(job.userId,
            ownDeadline: job.dueAt);
        if (earlier != null) return;
        await _withJdUiOperation(() async {
          _checkRun(epoch);
          if (await _transferWorkOwnsUi()) return;
          final stillRemaining = _redClocks.remaining(job.userId) ??
              job.dueAt.difference(DateTime.now());
          if (stillRemaining <= ResponseTimingPolicy.dispatchLead) return;
          if (!await _database.isPlatformResponsePending(job)) return;
          final clock = Stopwatch()..start();
          final available = stillRemaining - ResponseTimingPolicy.dispatchLead;
          const maxWarmup = Duration(seconds: 2);
          await _directDelivery.open(job.userId,
              maxOpenDuration: available < maxWarmup ? available : maxWarmup);
          _slaPreparedCycles.add('${job.userId}:${job.batchStartMessageId}');
          RuntimeTrace.record('sla.conversation_prepared', {
            'customer': job.userId,
            'cycleId': job.batchStartMessageId,
            'elapsedMs': clock.elapsedMilliseconds,
            'remainingMs': job.dueAt.difference(DateTime.now()).inMilliseconds,
            'sent': false
          });
        }, deadline: job.dueAt);
      } catch (error) {
        RuntimeTrace.record('sla.preparation_failed', {
          'customer': job.userId,
          'errorCode': error is PlatformException
              ? error.code
              : error.runtimeType.toString(),
          'actualSendStillScheduled': true
        });
      } finally {
        if (epoch == _runEpoch) _slaPreparingCustomers.remove(job.userId);
      }
    } finally {
      releaseDiagnosticWork();
    }
  }

  bool get _responseUiReserved {
    final now = DateTime.now();
    return _priorityUiOperations > 0 ||
        _deliveryWorkerRunning ||
        _slaUiDeadlines.entries.any((entry) =>
            _slaTimerPlans[entry.key]?.retry == null &&
            ResponseTimingPolicy.reservesUiForFirstAttempt(entry.value, now));
  }

  Future<bool> _transferWorkOwnsUi() async =>
      _transferringCustomers.isNotEmpty ||
      await _database.hasResumableHandoffCheckpoint();

  Future<bool> _hasEarlyFormalReply() async =>
      await _database.nextReadyDelivery(onlyWithinResponseWindow: true) != null;

  Future<bool> _readyFormalCanAnswerSla(SlaFallbackJob job) async =>
      await _database.nextReadyDelivery(
          userId: job.userId,
          onlyWithinResponseWindow: true,
          expectedResponseCycleId: job.batchStartMessageId ?? job.messageId) !=
      null;

  Future<void> _yieldUnclickedHoldingForFormal(String customer) async {
    final current = _nativeSlaAttempts[customer];
    if (current == null || current.epoch != _runEpoch || !_autoCaptureRunning) {
      return;
    }
    try {
      if (!await _readyFormalCanAnswerSla(current.job) ||
          _nativeSlaAttempts[customer] != current ||
          !_autoCaptureRunning ||
          current.epoch != _runEpoch) {
        return;
      }
      final yielded = await _yieldNativeHolding(customer, current.attemptId);
      if (yielded) {
        RuntimeTrace.record('sla.preclick_yield_requested', {
          'customer': customer,
          'cycleId': current.job.batchStartMessageId,
          'attemptId': current.attemptId
        });
      }
    } catch (error) {
      RuntimeTrace.record('sla.preclick_yield_unavailable', {
        'customer': customer,
        'errorCode': error.runtimeType.toString(),
      });
    }
  }

  Future<bool> _yieldNativeHolding(String customer, String attemptId) async {
    try {
      return await _adapter.requestHoldingSendYield(
          expectedCustomer: customer, attemptId: attemptId);
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<SlaFallbackJob?> _dueHoldingBeforeTransfer() async {
    final now = DateTime.now();
    for (final job in await _database.pendingSlaFallbackJobs()) {
      if (job.retryAt == null &&
          !job.dueAt.isAfter(now) &&
          now.difference(job.dueAt) <= const Duration(seconds: 15) &&
          await _database.isPlatformResponsePending(job)) {
        return job;
      }
    }
    return null;
  }

  Future<void> _reusePreparedSlaConversation(SlaFallbackJob job,
      {required DateTime preClickDeadline}) async {
    final key = '${job.userId}:${job.batchStartMessageId}';
    if (_slaPreparedCycles.contains(key)) {
      try {
        // The prepared window may have changed while another customer was
        // served. Re-read exact AX identity; native send still repeats all
        // identity, composer, insertion and click checks.
        await _adapter.checkDeliveryReadiness(job.userId);
        return;
      } on PlatformException catch (error) {
        _slaPreparedCycles.remove(key);
        if (error.code != 'delivery_readiness_unconfirmed' &&
            !ResponseTimingPolicy.shouldRecoverHoldingOpen(error.code,
                nativeAttemptStarted: false, alreadyRetried: false)) {
          rethrow;
        }
      }
    }
    final remaining = preClickDeadline.difference(DateTime.now());
    const maxOpen = Duration(seconds: 4);
    await _directDelivery.open(job.userId,
        preClickDeadline: preClickDeadline,
        maxOpenDuration: remaining < maxOpen ? remaining : maxOpen);
  }

  Future<void> _sendSlaFallback(SlaFallbackJob job) async {
    final releaseDiagnosticWork = _diagnosticWork.acquire();
    try {
      if (!_autoCaptureRunning || !_slaDispatchInFlight.add(job.userId)) return;
      final dispatchEpoch = _runEpoch;
      var admitted = false;
      var yieldedToFormal = false;
      var recoverHoldingOpen = false;
      try {
        if (!_autoCaptureRunning ||
            await _database.isConversationUnavailable(job.userId)) {
          return;
        }
        admitted = true;
        if (!await _database.isPlatformResponsePending(job)) {
          _recordSlaSkipped(job, 'red_cycle_not_pending', 'before_open');
          return;
        }
        if (await _hasReplySinceSlaMessage(job)) {
          final completed = await _database.completeSlaForObservedReply(job);
          RuntimeTrace.record('sla.completed_by_observed_reply', {
            'customer': job.userId,
            'messageId': job.messageId,
            'completed': completed,
            'stage': 'before_open',
          });
          return;
        }
        if (await _readyFormalCanAnswerSla(job)) {
          _requestDelivery();
          _recordSlaSkipped(job, 'ready_final_answer_preferred', 'before_open');
          return;
        }
        RuntimeTrace.record('sla.dispatch', {
          'customer': job.userId,
          'deadline': job.dueAt.toUtc().toIso8601String(),
          'batchStartMessageId': job.batchStartMessageId,
          'batchStartedAt': job.startedAt?.toUtc().toIso8601String(),
          'batchClockSource':
              job.hasVerifiedSenderClock ? 'sender_clock' : 'unread_or_capture',
          'messageId': job.messageId,
          'remainingMs': job.dueAt.difference(DateTime.now()).inMilliseconds
        });
        try {
          final prepared = _slaPreparedReplies[job.userId];
          final holdingReply =
              prepared != null && prepared.cycle == job.batchStartMessageId
                  ? prepared.reply
                  : await _holdingReplyForJob(job);
          _checkRun(dispatchEpoch);
          await _withFallbackPriority(() async {
            if (!_autoCaptureRunning) return;
            if (!await _database.isPlatformResponsePending(job)) {
              _recordSlaSkipped(job, 'red_cycle_not_pending', 'ui_lease');
              return;
            }
            if ((_redClocks.remaining(job.userId) ?? Duration.zero) >
                ResponseTimingPolicy.dispatchLead) {
              _recordSlaSkipped(
                  job, 'monotonic_deadline_not_reached', 'ui_lease');
              unawaited(_scheduleSlaFallback(job.userId));
              return;
            }
            final monotonicRemaining = _redClocks.remaining(job.userId);
            if (!await _database.reserveSlaFallback(
                userId: job.userId,
                messageId: job.messageId,
                dueAt: job.dueAt,
                requireDue: true,
                dispatchLead: ResponseTimingPolicy.dispatchLead,
                monotonicDueProof: monotonicRemaining != null &&
                        monotonicRemaining <= ResponseTimingPolicy.dispatchLead
                    ? job.dueAt.subtract(monotonicRemaining)
                    : null)) {
              _recordSlaSkipped(job, 'reservation_not_acquired', 'before_open');
              return;
            }
            var nativeAttemptStarted = false;
            String? nativeAttemptId;
            try {
              final preClickDeadline = _replyClickDeadline(
                  job.startedAt ?? job.dueAt.subtract(_database.holdingDelay));
              await _reusePreparedSlaConversation(job,
                  preClickDeadline: preClickDeadline);
              // The timer may have reserved this job before a generated or manual
              // reply completed. Recheck at the last possible point so a holding
              // message can never follow a real reply from the same SLA window.
              if (!_autoCaptureRunning ||
                  await _database.isHumanContacting(job.userId)) {
                _recordSlaSkipped(
                    job, 'stopped_or_human_takeover', 'after_open');
                return;
              }
              if (!await _database.isPlatformResponsePending(job) ||
                  !await _database.isSlaFallbackReservedForSend(
                      userId: job.userId, messageId: job.messageId)) {
                _recordSlaSkipped(job, 'reservation_invalidated', 'after_open');
                return;
              }
              if (await _hasReplySinceSlaMessage(job)) {
                await _database.completeSlaForObservedReply(job);
                _recordSlaSkipped(
                    job, 'final_reply_already_observed', 'after_open');
                return;
              }
              if (await _readyFormalCanAnswerSla(job)) {
                _requestDelivery();
                _recordSlaSkipped(
                    job, 'ready_final_answer_preferred', 'before_native_write');
                return;
              }
              final attempt = await _database.beginSlaAttempt(job, holdingReply,
                  yieldToReadyReply: true,
                  readyReplyMustBeWithinResponseWindow: true);
              if (attempt.isEmpty) {
                _requestDelivery();
                _recordSlaSkipped(
                    job, 'ready_final_answer_preferred', 'attempt_reservation');
                return;
              }
              nativeAttemptId = attempt['attemptId'];
              nativeAttemptStarted = true;
              final cycleId = job.batchStartMessageId ?? job.messageId;
              final native =
                  (job: job, attemptId: nativeAttemptId!, epoch: dispatchEpoch);
              _nativeSlaAttempts[job.userId] = native;
              try {
                final remaining = _redClocks.remaining(job.userId);
                final notBefore = remaining == null
                    ? job.dueAt
                    : DateTime.now().add(remaining);
                await _directDelivery.sendConfirmed(
                  customer: job.userId,
                  reply: holdingReply,
                  mediaPaths: const [],
                  attemptId: native.attemptId,
                  receiptPath: attempt['receiptPath'],
                  requireRedClock: true,
                  preClickDeadline: preClickDeadline,
                  holdingClickNotBefore: notBefore,
                  responseCycleId: cycleId,
                );
              } finally {
                if (_nativeSlaAttempts[job.userId] == native) {
                  _nativeSlaAttempts.remove(job.userId);
                }
              }
              _forgetSlaTimer(job.userId, expectedCycleId: cycleId);
              RuntimeTrace.record('sla.sent', {
                'replyKind': 'holding',
                'businessResponseSent': false,
                'caseResolved': null,
                'localRedObservationToClickMs': _lastPhysicalReplyAt[job.userId]
                    ?.difference(job.startedAt ??
                        job.dueAt.subtract(_database.holdingDelay))
                    .inMilliseconds,
                'clockSource': 'local_red_observation',
                'platformSlaVerified': false,
                'customer': job.userId,
                'deadline': job.dueAt.toUtc().toIso8601String(),
                'batchStartMessageId': job.batchStartMessageId,
                'batchStartedAt': job.startedAt?.toUtc().toIso8601String(),
                'batchClockSource': job.hasVerifiedSenderClock
                    ? 'sender_clock'
                    : 'unread_or_capture',
                'messageId': job.messageId,
                'lateMs': DateTime.now().difference(job.dueAt).inMilliseconds
              });
              final recorded = await _database.markSlaFallbackSent(
                userId: job.userId,
                messageId: job.messageId,
                reply: holdingReply,
                batchStartMessageId: job.batchStartMessageId ?? job.messageId,
                nativeConfirmed: true,
              );
              if (recorded && mounted) {
                setState(() => _diagnostics =
                    'Sent a holding message to ${job.userId}; the final answer remains queued.');
              }
            } on PlatformException catch (error) {
              if (nativeAttemptStarted) {
                await _database.releaseSlaFallback(
                  userId: job.userId,
                  messageId: job.messageId,
                  expectedAttemptId: nativeAttemptId,
                  nativeNotInvoked:
                      error.code == 'send_preclick_budget_exceeded' &&
                          error.details is Map &&
                          (error.details as Map)['nativeInvoked'] == false &&
                          (error.details as Map)['clickDispatched'] == false &&
                          (error.details as Map)['sendStage'] ==
                              'before_native_send',
                );
              }
              if (error.code == 'red_clock_cleared') {
                await _database.observePlatformResponse(job.userId,
                    red: false,
                    expectedCycleId: job.batchStartMessageId ?? job.messageId);
                _recordSlaSkipped(
                    job, 'native_red_clock_cleared', 'before_click');
                return;
              }
              if (error.code == 'holding_yielded_to_formal') {
                yieldedToFormal = true;
                _recordSlaSkipped(
                    job, 'ready_final_answer_preferred', 'before_click');
                _requestDelivery();
                return;
              }
              if (ResponseTimingPolicy.shouldRecoverHoldingOpen(error.code,
                  nativeAttemptStarted: nativeAttemptStarted,
                  alreadyRetried: job.retryAt != null)) {
                recoverHoldingOpen = true;
                _slaPreparedCycles
                    .remove('${job.userId}:${job.batchStartMessageId}');
                RuntimeTrace.record('sla.open_recovery_queued', {
                  'customer': job.userId,
                  'cycleId': job.batchStartMessageId,
                  'errorCode': error.code,
                  'originalDeadlinePreserved': true,
                });
                return;
              }
              if (_isMissingConversation(error)) {
                await _suspendMissingConversation(job.userId, error);
              } else {
                unawaited(_scheduleSlaFallback(job.userId,
                    minimumDelay: const Duration(seconds: 1)));
              }
              rethrow;
            } catch (_) {
              if (nativeAttemptStarted) {
                await _database.releaseSlaFallback(
                  userId: job.userId,
                  messageId: job.messageId,
                  expectedAttemptId: nativeAttemptId,
                );
              }
              unawaited(_scheduleSlaFallback(job.userId,
                  minimumDelay: const Duration(seconds: 1)));
              rethrow;
            } finally {
              // Every pre-native exit relinquishes this exact reservation. Once
              // an attempt exists, receipt-based failure handling owns it so an
              // uncertain Send click can never authorize another write.
              if (!nativeAttemptStarted) {
                await _database.releaseUnstartedSlaFallback(job,
                    retryDelay: recoverHoldingOpen
                        ? Duration.zero
                        : const Duration(seconds: 5));
              }
            }
          },
              deadline: ResponseTimingPolicy.holdingQueueDeadline(
                  job.dueAt, DateTime.now(),
                  retry: job.retryAt != null));
          await _coordinator.refresh();
        } catch (error) {
          if (mounted) {
            setState(() => _error = '等待提示发送失败（切换会话/身份核验）：$error');
          }
        }
      } finally {
        if (dispatchEpoch == _runEpoch) _slaDispatchInFlight.remove(job.userId);
        if (admitted && _autoCaptureRunning && dispatchEpoch == _runEpoch) {
          unawaited(_scheduleSlaFallback(job.userId,
              minimumDelay: yieldedToFormal || recoverHoldingOpen
                  ? Duration.zero
                  : const Duration(seconds: 1)));
        }
      }
    } finally {
      releaseDiagnosticWork();
    }
  }

  Future<void> _pollMediaCacheProgress() async {
    final releaseDiagnosticWork = _diagnosticWork.acquire();
    try {
      if (!_autoCaptureRunning || _mediaCacheProgressBusy) return;
      _mediaCacheProgressBusy = true;
      final epoch = _runEpoch;
      try {
        final revision = await _adapter.recentMediaCacheRevision();
        _checkRun(epoch);
        if (revision == null) return;
        final previous = _mediaCacheRevision;
        _mediaCacheRevision = revision;
        if (previous == revision) return;
        if (_imageOriginalTasks.wakeCacheWaiters()) {
          _armImageOriginalWork(Duration.zero);
        }
        if (previous == null) return;
        for (final customer in await _evidenceStore.waitingMediaCustomers()) {
          _checkRun(epoch);
          await _evidenceStore.retireResolvedMedia(customer);
          _checkRun(epoch);
          final owners = <String>{};
          for (final item
              in await _mediaInventory.pendingMediaForTask(customer)) {
            if (item['receiptId'] case final String receipt) {
              final parent = await _mediaInventory.resolveParent(customer,
                  receiptId: receipt, requireCurrentSession: true);
              if (parent != null &&
                  !await _database.isMessageFormallyAnswered(
                      customer, parent.messageId)) {
                owners.addAll({
                  parent.receiptId,
                  parent.messageId,
                  ...(item['aliases'] as List? ?? const []).whereType<String>()
                });
              }
            }
          }
          _checkRun(epoch);
          if (owners.isEmpty) continue;
          await _evidenceStore.wakeMediaForProgress(customer,
              progressKey: 'cache:$revision', ownerKeys: owners);
          _checkRun(epoch);
        }
        unawaited(_drainEvidenceInbox(mediaOnly: true));
      } on _AutomationStopped {
        return;
      } catch (_) {
        // A cache metadata probe never fails or consumes a customer's duty.
      } finally {
        if (epoch == _runEpoch) _mediaCacheProgressBusy = false;
      }
    } finally {
      releaseDiagnosticWork();
    }
  }

  Future<void> _runAutoCaptureCycle() async {
    final releaseDiagnosticWork = _diagnosticWork.acquire();
    try {
      if (!_autoCaptureRunning || _autoCaptureBusy) return;
      _autoCaptureBusy = true;
      final epoch = _runEpoch;
      var observedStartupRows = false;
      try {
        await _ensureEvidenceRecovered();
        unawaited(_drainEvidenceInbox());
        if (_pendingJdUiOperations > 0 || _priorityUiOperations > 0) return;
        final rows = await _adapter
            .listConversationRows()
            .timeout(_unreadOperationTimeout);
        _checkRun(epoch);
        final visibleRowKeys =
            rows.map((row) => row.rowKey).whereType<String>().toSet();
        for (final key in _rowsWaitingVisibility.toList()) {
          final rowKey =
              key.substring(MacOSCaptureAdapter.provisionalPrefix.length);
          if (visibleRowKeys.contains(rowKey)) {
            _rowsWaitingVisibility.remove(key);
            if (_unreadRecovery[key] case final recovery?) {
              _armUnreadRecoveryTimers(recovery);
            }
          }
        }
        for (final row in rows) {
          // A selected row may have a red response clock without unread=true.
          // Establish that first AX observation before passive history is
          // admitted; subsequent scans keep the independent clock poll behavior.
          final bootstrap =
              !_initialCaptureScanReady || _passiveBaselineScans.isNotEmpty;
          if (bootstrap) {
            await _observePlatformClock(row);
            _checkRun(epoch);
          }
          _refreshHandledUnread(row, observeClock: !bootstrap);
          if (row.unread &&
              !_unreadRecovery.containsKey(row.customer) &&
              !_handledUnreadEvidence.containsKey(row.customer) &&
              !await _database.isHumanContacting(row.customer)) {
            await _beginUnreadRecovery(row.customer, row.unreadEvidence,
                detectedAt: _unreadDetectedAt(row));
          }
        }
        final needed = await _evidenceStore.awaitingFrameCustomers();
        final captureFailures = await _evidenceStore.failedCaptures();
        final restores = await _evidenceStore.restoreCutoffs();
        final ordered = rows
            .where((row) =>
                (row.unread &&
                    (!_handledUnreadEvidence.containsKey(row.customer) ||
                        _unreadSignals.needsProbe(
                            row.customer, _handledUnreadAt[row.customer]))) ||
                needed.contains(row.customer))
            .toList()
          ..sort((a, b) => (_unreadRecovery[a.customer]?.detectedAt ??
                  DateTime.now())
              .compareTo(
                  _unreadRecovery[b.customer]?.detectedAt ?? DateTime.now()));
        for (final customer in needed) {
          if (MacOSCaptureAdapter.isProvisionalIdentity(customer) &&
              !visibleRowKeys.contains(customer
                  .substring(MacOSCaptureAdapter.provisionalPrefix.length))) {
            _unreadHoldingTimers.remove(customer)?.cancel();
            _unreadResendTimers.remove(customer)?.cancel();
            if (_rowsWaitingVisibility.add(customer)) {
              RuntimeTrace.record('identity.row_waiting_visibility', {
                'observedRow': customer,
                'deadlineReset': false,
                'reason': 'row_moved_out_of_visible_list',
              });
            }
            continue;
          }
          if (!ordered.any((row) => row.customer == customer)) {
            ordered.add(QianniuConversationRow(
                customer: customer,
                unread: false,
                unreadEvidence: 0,
                evidenceAvailable: false));
          }
        }
        for (final row in ordered) {
          if (!_autoCaptureRunning) break;
          final urgentIdentity = row.unread &&
              MacOSCaptureAdapter.isProvisionalIdentity(row.customer);
          if (_responseUiReserved && !urgentIdentity) {
            RuntimeTrace.record(
                'capture.yielded_to_response', {'customer': row.customer});
            break;
          }
          if (!_adapter.rowResolutionDue(row.customer)) continue;
          if (captureFailures.contains(row.customer) ||
              await _database.isConversationUnavailable(row.customer)) {
            continue;
          }
          if (await _database.isHumanContacting(row.customer)) continue;
          _pendingJdUiOperations++;
          try {
            await _jdUiScheduler.run(
                () => runZoned(() async {
                      _checkRun(epoch);
                      if (_responseUiReserved && !urgentIdentity) return;
                      final handledProbe =
                          _handledUnreadEvidence.containsKey(row.customer);
                      if (handledProbe) {
                        _unreadSignals.markProbe(row.customer);
                        RuntimeTrace.record('unread.handled_probe', {
                          'customer': row.customer,
                          'handledAt': _handledUnreadAt[row.customer]
                              ?.toUtc()
                              .toIso8601String(),
                          'badgeAgeSeconds': row.unreadAgeSeconds,
                          'reason': 'persistent_unread_after_handled',
                          'doesNotMarkAnswered': true
                        });
                      }
                      await _adapter.openConversation(row.customer,
                          allowActivation: false);
                      _checkRun(epoch);
                      final customer =
                          _adapter.verifiedCustomerIdentity(row.customer);
                      if (customer != row.customer) {
                        await _bindObservedRow(row.customer, customer,
                            evidence: row.unreadEvidence,
                            detectedAt:
                                _unreadRecovery[row.customer]?.detectedAt ??
                                    _unreadDetectedAt(row));
                      }
                      if (restores.containsKey(customer)) {
                        await _adapter.scrollConversation(
                            expectedCustomer: customer, deltaY: -10000);
                        await _evidenceStore.setRestore(customer, false);
                      }
                      await _captureViewport(
                          customer: customer, hasUiLease: true);
                    }, zoneValues: {
                      MacOSCaptureAdapter.automationEpochZoneKey: epoch
                    }),
                priority: urgentIdentity
                    ? JdUiPriority.responseDeadline
                    : JdUiPriority.capture,
                deadline: urgentIdentity
                    ? (_unreadRecovery[row.customer]?.detectedAt ??
                            DateTime.now())
                        .add(_database.holdingDelay)
                    : null);
          } catch (error) {
            if (!_autoCaptureRunning || epoch != _runEpoch) return;
            if (_isMissingConversation(error)) {
              await _suspendMissingConversation(row.customer, error);
            }
            if (error is! PlatformException ||
                !const {
                  'qianniu_not_frontmost',
                  'composer_not_empty',
                  'snapshot_customer_changed',
                  'snapshot_customer_mismatch',
                  'row_reference_expired',
                  'row_changed',
                  'row_layout_changed',
                  'row_open_timeout',
                  'row_activation_unconfirmed',
                  'row_identity_unconfirmed',
                  'row_resolution_deferred',
                }.contains(error.code)) {
              await _evidenceStore.captureFailed(row.customer);
            }
            RuntimeTrace.record('evidence.capture_failed', {
              'customer': row.customer,
              'errorCode': error is PlatformException
                  ? error.code
                  : error.runtimeType.toString()
            });
          } finally {
            _pendingJdUiOperations--;
          }
        }
        observedStartupRows = true;
        await _dispatchBackfill();
      } catch (error) {
        RuntimeTrace.record('evidence.poll_failed',
            {'errorCode': error.runtimeType.toString()});
      } finally {
        if (epoch == _runEpoch) {
          if (observedStartupRows) {
            _initialCaptureScanReady = true;
            _completedCaptureScans++;
          }
          _autoCaptureBusy = false;
        }
      }
    } finally {
      releaseDiagnosticWork();
    }
  }

  int _historyScrollStep(ViewportEvidence evidence) {
    final bounds = evidence.metadata['windowBounds'] as Map?;
    final chat = evidence.metadata['chatRegion'] as Map?;
    final height = (bounds?['height'] as num?)?.toDouble() ?? 600;
    final fraction = ((chat?['bottom'] as num?)?.toDouble() ?? .9) -
        ((chat?['top'] as num?)?.toDouble() ?? .2);
    return (height * fraction * .30).round().clamp(80, 700);
  }

  Future<void> _dispatchBackfill() => BackfillDispatcher(
        store: _evidenceStore,
        canRun: () => _autoCaptureRunning && !_responseUiReserved,
        canVisit: (customer) async =>
            !await _database.isHumanContacting(customer) &&
            !await _database.isConversationUnavailable(customer) &&
            !await _hasEarlyFormalReply(),
        withUi: (work) async {
          final epoch = _runEpoch;
          _pendingJdUiOperations++;
          try {
            await _jdUiScheduler.run(
                () => runZoned(() async {
                      _checkRun(epoch);
                      await work();
                    }, zoneValues: {
                      MacOSCaptureAdapter.automationEpochZoneKey: epoch
                    }),
                priority: JdUiPriority.capture);
          } finally {
            _pendingJdUiOperations--;
          }
        },
        open: (customer) async {
          await _adapter.openConversation(customer, allowActivation: false);
          if (_adapter.verifiedCustomerIdentity(customer) != customer) {
            throw PlatformException(code: 'backfill_customer_mismatch');
          }
        },
        scroll: (customer, delta) => _adapter.scrollConversation(
            expectedCustomer: customer, deltaY: delta, waitForViewport: true),
        capture: (customer, cutoff) =>
            _captureViewport(customer: customer, historyCutoff: cutoff),
      ).runOnePage();

  Future<void> _handleTransferNotice(String userId, String eventKey) async {
    if (!_visibleTransferWelcomes.add(userId)) return;
    // A transferred chat can already contain the customer's real question.
    // Preserve that queued answer and record the transfer as handled without
    // inserting a generic welcome in front of it.
    if (await _database.hasPendingUnanswered(userId) ||
        await _database.hasUndeliveredDraft(userId)) {
      await _database.reserveTransferWelcome(
          userId: userId, eventKey: eventKey);
      // Return-to-reception evidence may arrive after the old attempt's
      // completion has released generation. Wake actual work, not a welcome.
      _scheduleDraftGeneration(userId, newEvidence: false);
      _requestDelivery();
      return;
    }
    await _sendTransferWelcomeOnce(userId, eventKey);
  }

  Future<bool> _sendTransferWelcomeOnce(String userId, String eventKey) async {
    if (!_autoCaptureRunning) return false;
    final welcome = FixedReplies.text(
        LocalReplyRouter.transferWelcome, ChineseOnlyReplyPolicy.language);
    if (!await _database.reserveTransferWelcome(
        userId: userId, eventKey: eventKey)) {
      return false;
    }
    var sendStarted = false;
    try {
      await _directDelivery.open(userId);
      if (!_autoCaptureRunning ||
          await _database.hasPendingUnanswered(userId) ||
          await _database.hasUndeliveredDraft(userId) ||
          await _database.isHumanContacting(userId)) {
        RuntimeTrace.record('transfer.welcome_skipped',
            {'customer': userId, 'reason': 'state_changed_after_open'});
        return false;
      }

      sendStarted = true;
      await _adapter.sendDraftOnce(
        expectedCustomer: userId,
        reply: welcome,
        mediaPaths: const [],
      );
    } catch (error) {
      final knownNotSent = !sendStarted ||
          (error is PlatformException &&
              error.details is Map &&
              (error.details as Map)['clickDispatched'] == false);
      if (knownNotSent) {
        await _database.releaseTransferWelcomeReservation(
            userId: userId, eventKey: eventKey);
        _visibleTransferWelcomes.remove(userId);
      }
      RuntimeTrace.record('transfer.welcome_attempt_failed', {
        'customer': userId,
        'stage': sendStarted ? 'native_send' : 'open_conversation',
        'knownNotSent': knownNotSent,
        'reservationPreserved': !knownNotSent,
        'errorCode': error is PlatformException
            ? error.code
            : error.runtimeType.toString(),
      });
      rethrow;
    }
    await _database.appendAutomatedNoticeSent(userId: userId, reply: welcome);
    _handledUnreadEvidence[userId] = int.tryParse(eventKey) ?? 0;
    _handledUnreadAt[userId] = DateTime.now();
    if (mounted) {
      setState(() => _diagnostics =
          'Detected a JD transfer and sent one welcome message to $userId.');
    }
    return true;
  }

  void _runDraftWorkers() {
    while (_autoCaptureRunning &&
        _activeDraftUsers.length < _maxConcurrentDraftWorkers &&
        _draftQueue.isNotEmpty) {
      String? userId;
      for (final candidate in _draftQueue) {
        // Keep one draft/commit owner per customer. This does not serialize
        // hosted API generation: each source message was submitted separately,
        // and only completed results enter this collection queue.
        if (!_activeDraftUsers.contains(candidate)) {
          userId = candidate;
          break;
        }
      }
      if (userId == null) break;
      _draftQueue.remove(userId);
      _activeDraftUsers.add(userId);
      _draftWorkerEpochs[userId] = _runEpoch;
      final cancellation = CodexGenerationCancellation();
      _activeDraftCancellations[userId] = cancellation;
      unawaited(_runDraftWorker(userId, cancellation));
    }
  }

  Future<void> _runDraftWorker(
      String userId, CodexGenerationCancellation cancellation) async {
    final workerEpoch = _runEpoch;
    try {
      await _processDraftUser(userId, cancellation);
    } on _AutomationStopped {
      // Old run owns no UI permissions; its pending work remains durable.
    } on CodexGenerationCancelled {
      // A later saved customer message owns the queued replacement turn.
    } on CodexGenerationTimedOut {
      if (workerEpoch != _runEpoch || !_autoCaptureRunning) return;
      await _scheduleDraftRetry(userId);
      // The holding-message sender must not retain this generation worker.
      // Its original 20-second deadline stays independent of the watchdog.
      unawaited(_scheduleSlaFallback(userId).catchError((Object error) {
        if (mounted) {
          setState(() {
            _error = error;
            RuntimeTrace.record('ui.error', {'error': '$error'});
          });
        }
      }));
    } on CodexReplyMediaUnavailable catch (error) {
      if (workerEpoch != _runEpoch || !_autoCaptureRunning) return;
      // Missing original/frame files are acquisition work, not a failed model
      // answer. Keep the exact incoming IDs and let independent text proceed.
      await _evidenceStore.wakeMediaForProgress(userId,
          progressKey:
              'missing-files:$workerEpoch:${error.messageIds.join(',')}',
          ownerKeys: error.messageIds.toSet());
      _checkRun(workerEpoch);
      await _seedImageOriginalTasks(workerEpoch);
      unawaited(_drainEvidenceInbox(mediaOnly: true));
      if (mounted) {
        setState(() {
          _error = null;
          _diagnostics = '媒体文件暂时不可用，原消息保留未答并继续获取；文字消息照常处理。';
        });
      }
    } on CodexReplyException catch (error) {
      if (workerEpoch != _runEpoch || !_autoCaptureRunning) return;
      if (isCodexModelCapacityError(error.message)) {
        if (mounted) {
          setState(() {
            _error = null;
            _diagnostics =
                'Reply generation is retrying because the Codex models are busy.';
          });
        }
      } else if (mounted) {
        setState(() {
          _error = error;
          RuntimeTrace.record('ui.error', {'error': '$error'});
        });
      }
      await _scheduleDraftRetry(userId);
    } catch (error) {
      if (workerEpoch != _runEpoch || !_autoCaptureRunning) return;
      if (mounted) {
        setState(() {
          _error = error;
          RuntimeTrace.record('ui.error', {'error': '$error'});
        });
      }
      await _scheduleDraftRetry(userId);
    } finally {
      if (identical(_activeDraftCancellations[userId], cancellation)) {
        _activeDraftCancellations.remove(userId);
        _activeDraftMessageIds.remove(userId);
        _activeDraftMediaSensitive.remove(userId);
        _activeSocialTurnClocks.remove(userId);
        final token = _activeDraftTokens.remove(userId);
        // Stop already cleared all leases. A cancelled/disposed old worker
        // must not touch storage after shutdown or a new run has started.
        if (token != null &&
            mounted &&
            _autoCaptureRunning &&
            workerEpoch == _runEpoch) {
          await _database.abandonGeneration(userId, token);
        }
      }
      if (_draftWorkerEpochs[userId] == workerEpoch) {
        _draftWorkerEpochs.remove(userId);
        _activeDraftUsers.remove(userId);
        if (workerEpoch == _runEpoch && _autoCaptureRunning) {
          unawaited(_queueDraftIfPending(userId));
          _runDraftWorkers();
          _requestDelivery();
        }
      }
    }
  }

  Future<void> _scheduleDraftRetry(String userId) async {
    _draftRetryTimers.remove(userId)?.cancel();
    if (!_autoCaptureRunning) return;
    final epoch = _runEpoch;
    final retryAt = await _database.recordGenerationFailure(
        userId, _error ?? 'generation_failed');
    if (!_autoCaptureRunning || epoch != _runEpoch) return;
    _draftRetryTimers[userId] =
        Timer(retryAt.difference(DateTime.now()), () async {
      _draftRetryTimers.remove(userId);
      if (!_autoCaptureRunning || epoch != _runEpoch) return;
      if (!await _database.hasPendingUnanswered(userId) ||
          await _database.isHumanContacting(userId)) {
        return;
      }
      _draftQueue.add(userId);
      _runDraftWorkers();
    });
  }

  Future<void> _processDraftUser(
      String userId, CodexGenerationCancellation cancellation) async {
    final epoch = _runEpoch;
    if (_usesHostedReplies) {
      await _drainHostedCompletions(userId, epoch);
      return;
    }
    final sessionId = _automationSessionId;
    _checkRun(epoch);
    cancellation.throwIfCancelled();
    final conversation = await _database.conversation(userId);
    if (conversation == null ||
        await _database.hasUndeliveredDraft(userId) ||
        !await _database.hasPendingUnanswered(userId)) {
      return;
    }
    final initialMessageId = await _database.generationAnchorMessageId(userId);
    if (initialMessageId == null) return;
    var messageIdAtGenerationStart = initialMessageId;
    _checkRun(epoch);
    cancellation.throwIfCancelled();
    final singleMessage = widget.generateDraftOverride == null &&
        (widget.replyServiceOverride == null ||
            widget.replyServiceOverride is HostedReplyService);
    final initialSnapshot = await _database.beginGenerationSnapshot(
        customer: userId,
        pendingId: conversation.id,
        batchEndMessageId: messageIdAtGenerationStart,
        expectedSessionId: sessionId,
        singleMessage: singleMessage);
    if (initialSnapshot == null) return;
    messageIdAtGenerationStart = initialSnapshot.batchEndMessageId;
    var generationToken = initialSnapshot.token;
    _checkRun(epoch);
    cancellation.throwIfCancelled();
    final history = await (await _database.history).read(userId);
    final end = (history?['messages'] as List? ?? const [])
        .whereType<Map>()
        .where((m) =>
            m['id'] == messageIdAtGenerationStart ||
            (m['observed_ids'] as List? ?? const [])
                .contains(messageIdAtGenerationStart))
        .firstOrNull;
    if (end != null &&
        (end['media'] as List? ?? const []).isEmpty &&
        ResponseTimingPolicy.isSocialAcknowledgement(
            end['body']?.toString() ?? '')) {
      final at = DateTime.tryParse(end['sent_at']?.toString() ?? '');
      if (at != null) _activeSocialTurnClocks[userId] = at;
    }
    _activeDraftMessageIds[userId] = messageIdAtGenerationStart;
    _activeDraftTokens[userId] = generationToken;
    final service = widget.generateDraftOverride == null
        ? widget.replyServiceOverride ??
            await CodexReplyService.discover(_database)
        : null;
    final ownedInputs = await _database.generationMessages(userId,
        batchEndMessageId: messageIdAtGenerationStart);
    if (ownedInputs.any((message) =>
        message['direction'] == 'incoming' &&
        message['text_origin'] != 'media' &&
        (message['media'] as List? ?? const []).isEmpty &&
        NamedAgentRequest.parse(message['body']?.toString() ?? '') != null)) {
      await _refreshCurrentServiceAccount();
      _checkRun(epoch);
    }
    cancellation.throwIfCancelled();
    var draft = await RuntimeTrace.measure(
        'draft.generate',
        () =>
            widget.generateDraftOverride?.call(conversation, _database,
                messageIdAtGenerationStart, cancellation) ??
            service!.generate(
                conversation: conversation,
                database: _database,
                currentServiceAccount: _adapter.currentServiceAccount,
                onMediaDependency: (sensitive) {
                  if (identical(
                      _activeDraftCancellations[userId], cancellation)) {
                    _activeDraftMediaSensitive[userId] = sensitive;
                  }
                },
                batchEndMessageId: messageIdAtGenerationStart,
                cancellation: cancellation,
                beforeSubmit: sessionId == null
                    ? null
                    : () async {
                        _checkRun(epoch);
                        cancellation.throwIfCancelled();
                        // Capture must not mistake this owned token exchange
                        // for a stale running generation while CAS is pending.
                        _activeDraftTokens.remove(userId);
                        GenerationSnapshot? refreshed;
                        try {
                          refreshed =
                              await _database.refreezeGenerationBeforeSubmit(
                                  customer: userId,
                                  pendingId: conversation.id,
                                  generationToken: generationToken,
                                  singleMessage: singleMessage,
                                  batchEndMessageId: messageIdAtGenerationStart,
                                  expectedSessionId: sessionId,
                                  canCommit: () =>
                                      _autoCaptureRunning &&
                                      epoch == _runEpoch &&
                                      !cancellation.isCancelled &&
                                      identical(
                                          _activeDraftCancellations[userId],
                                          cancellation));
                          if (refreshed != null) {
                            generationToken = refreshed.token;
                            messageIdAtGenerationStart =
                                refreshed.batchEndMessageId;
                          }
                          _checkRun(epoch);
                          cancellation.throwIfCancelled();
                          if (refreshed == null) {
                            cancellation.cancel();
                            throw const CodexGenerationCancelled();
                          }
                          _activeDraftMessageIds[userId] =
                              refreshed.batchEndMessageId;
                          // Once this request is submitted, later inputs own
                          // the next task; they cannot restart this CLI turn.
                          _activeSocialTurnClocks.remove(userId);
                          return refreshed.expanded
                              ? refreshed.batchEndMessageId
                              : null;
                        } finally {
                          if (refreshed != null &&
                              epoch == _runEpoch &&
                              _autoCaptureRunning &&
                              (cancellation.isCancelled ||
                                  !identical(_activeDraftCancellations[userId],
                                      cancellation))) {
                            await _database.abandonGeneration(
                                userId, refreshed.token);
                          }
                          if (epoch == _runEpoch &&
                              identical(_activeDraftCancellations[userId],
                                  cancellation)) {
                            _activeDraftTokens[userId] = generationToken;
                          }
                        }
                      }),
        fields: {'customer': userId});
    cancellation.throwIfCancelled();
    if (mounted) {
      setState(() {
        final visibleError = _error;
        if (visibleError is CodexReplyException &&
            isCodexModelCapacityError(visibleError.message)) {
          _error = null;
        }
        if (service != null &&
            draft.model == service.capacityFallbackModel &&
            service.capacityFallbackModel != service.model) {
          _diagnostics =
              'The primary Codex model was busy; this reply used ${draft.model}.';
        }
      });
    }
    cancellation.throwIfCancelled();
    _checkRun(epoch);
    await _noteVideoHints(userId, draft);
    final frozenInputs = await _database.generationMessages(userId,
        batchEndMessageId: messageIdAtGenerationStart);
    final explicitTransfer = JdV2Payload.requestsTransfer(draft);
    // A confirmed request hands the conversation to a colleague; it does not
    // answer or complete the media. Only a formal AI answer needs its content.
    if (!explicitTransfer &&
        !await _database.generationInputsAnalysisReady(userId,
            generationToken: generationToken)) {
      return;
    }
    draft = await _database.prepareAutomaticDraft(userId, draft);
    cancellation.throwIfCancelled();
    _checkRun(epoch);
    if (!explicitTransfer &&
        !await _database.mediaContextCurrent(userId, draft)) {
      RuntimeTrace.record('generation.stale_media_result', {
        'customer': userId,
        'messageId': messageIdAtGenerationStart,
        'snapshotRevision': draft.mediaContextRevision,
        'currentRevision': await _mediaInventory.revision(userId)
      });
      cancellation.cancel();
      return;
    }
    final result = await _database.saveAutomaticDraft(conversation.id, draft,
        expectedMessageId: messageIdAtGenerationStart,
        expectedUserId: userId,
        generationToken: generationToken,
        deliverable: !explicitTransfer);
    if (result.outcome == AutomaticDraftSaveOutcome.ready) {
      // Generation is outside the UI lease. A timely ready answer may cancel
      // only this customer's still-unclicked holding attempt for this round.
      unawaited(_yieldUnclickedHoldingForFormal(userId));
    }
    // Contacting or a manually observed seller reply may remove the queue
    // while Codex is generating. Never send a result from that stale turn.
    final humanContacting = await _database.isHumanContacting(userId);
    final deliveryBlocked = await _database.isConversationUnavailable(userId);
    RuntimeTrace.record('draft.save_result', {
      'customer': userId,
      'messageId': messageIdAtGenerationStart,
      'saved': result.outcome == AutomaticDraftSaveOutcome.ready ||
              result.outcome == AutomaticDraftSaveOutcome.transferOnly
          ? 1
          : 0,
      'deliveryBlocked': deliveryBlocked,
      'transferOnly': explicitTransfer,
      'humanContacting': humanContacting,
      'outcome': switch (result.outcome) {
        AutomaticDraftSaveOutcome.stale => 'queue_no_longer_valid',
        AutomaticDraftSaveOutcome.awaitingDependency => 'awaiting_media',
        AutomaticDraftSaveOutcome.needsAnswer => 'needs_answer',
        AutomaticDraftSaveOutcome.transferOnly => 'transfer_only',
        AutomaticDraftSaveOutcome.ready => humanContacting
            ? 'human_takeover'
            : deliveryBlocked
                ? 'blocked_pending_recovery'
                : 'ready_for_delivery',
      },
      if (result.outcome == AutomaticDraftSaveOutcome.needsAnswer)
        'requiresOperator': result.requiresOperator,
    });
    if (result.outcome == AutomaticDraftSaveOutcome.stale &&
        !await _database.mediaContextCurrent(userId, draft)) {
      cancellation.cancel();
    }
    if (result.outcome == AutomaticDraftSaveOutcome.stale || humanContacting) {
      return;
    }
    if (result.outcome == AutomaticDraftSaveOutcome.needsAnswer ||
        result.outcome == AutomaticDraftSaveOutcome.awaitingDependency) {
      if (mounted && result.outcome == AutomaticDraftSaveOutcome.needsAnswer) {
        setState(() => _diagnostics = result.requiresOperator
            ? '$userId 尚未生成正式答复，原问题保留在待补答记录中。'
            : '$userId 的上次结果只有等待通知，正在根据原问题补答。');
      }
      await _refreshTickets();
      await _coordinator.refresh();
      return;
    }
    // A committed formal reply can use the UI immediately; ticket refresh
    // and presentation updates are not prerequisites for physical delivery.
    if (result.outcome == AutomaticDraftSaveOutcome.ready && !deliveryBlocked) {
      _requestDelivery();
    }
    final needsHuman = draftRequiresHumanReview(draft);
    if (needsHuman) {
      final messages = frozenInputs;
      _checkRun(epoch);
      final latestIncoming = messages.reversed
          .firstWhere((message) => message['direction'] == 'incoming');
      final ticket = await _database.createHumanReviewTicket(
        userId: userId,
        customerRequest: explicitTransfer
            ? handoffContextSummary(messages)
            : latestIncoming['body']?.toString() ?? '',
        reason: draftHumanReviewReason(draft),
        requestMessageId:
            explicitTransfer ? latestIncoming['id']?.toString() : null,
      );
      await _refreshTickets();
      if (explicitTransfer) {
        // The API action starts the existing exclusive native transfer flow.
        _checkRun(epoch);
        await _autoTransferTicket(ticket);
      }
      if (draft.attachments.isNotEmpty && mounted) {
        setState(() => _diagnostics =
            'Human-review acknowledgement for $userId unexpectedly contained media and was not sent.');
      }
    }
    await _coordinator.refresh();
    _requestDelivery();
  }

  // Apply this CLI's exact owned-input type hints before the draft can queue.
  // Reclassification itself runs later on frozen pixels, outside UI delivery.
  Future<void> _noteVideoHints(String customer, AiDraft draft) async {
    try {
      final input = await _database.generationMessages(customer);
      RuntimeTrace.record('media.analysis_received', {
        'customer': customer,
        'describedImageCount': draft.imageDescriptions.length,
        'videoHintCount': draft.imageDescriptions.values
            .where(codexIdentifiedVideoThumbnail)
            .length
      });
      for (final entry in draft.imageDescriptions.entries) {
        if (!codexIdentifiedVideoThumbnail(entry.value)) continue;
        final owned = input.where((message) =>
            message['direction'] == 'incoming' &&
            (message['media'] as List? ?? const []).whereType<Map>().any(
                (media) =>
                    media['path'] == entry.key &&
                    const {
                      'jd_image_cache',
                      'verified_window_crop',
                      'verified_media_preview'
                    }.contains(media['capture_source'])));
        for (final message in owned) {
          final receipt = message['media_receipt_id'] as String?;
          final blocked =
              await _mediaInventory.markMediaTypeVerificationPending(customer,
                  messageId: message['id']! as String,
                  receiptId: receipt,
                  imagePath: entry.key);
          if (!blocked) continue;
          final source = message['capture_evidence_id'] as String?;
          final affected = <String>{
            if (source != null || receipt != null)
              ...await _mediaAudit.noteVideoHint(customer, entry.key,
                  evidenceId: source, receiptId: receipt),
            if (source != null) source,
            if (receipt != null)
              ...await _mediaInventory.typeVerificationEvidenceIds(customer,
                  receiptId: receipt),
          };
          for (final evidenceId in affected) {
            final queued =
                await _evidenceStore.requestMediaTypeRecheck(evidenceId);
            RuntimeTrace.record('media.video_original_retry', {
              'customer': customer,
              'evidenceId': evidenceId,
              'queued': queued,
              'source': 'saved_frame_only',
              'reason':
                  queued ? 'model_video_hint' : 'current_frame_not_available'
            });
          }
        }
      }
      unawaited(_drainEvidenceInbox(mediaOnly: true));
    } catch (error) {
      RuntimeTrace.record('media.enrichment_failed',
          {'customer': customer, 'errorCode': error.runtimeType.toString()});
      rethrow;
    }
  }

  Future<void> _armDeliveryWake() async {
    _deliveryRetryTimer?.cancel();
    final at = await _database.nextDeliveryWakeAt();
    if (!_autoCaptureRunning || at == null) return;
    final delay = at.difference(DateTime.now());
    _deliveryRetryTimer =
        Timer(delay.isNegative ? Duration.zero : delay, _requestDelivery);
  }

  Future<void> _maintainQueues() async {
    final releaseDiagnosticWork = _diagnosticWork.acquire();
    try {
      if (!_autoCaptureRunning || _maintenanceBusy) return;
      if (_database.businessDayHasChanged) {
        await _rollBusinessDay(_runEpoch);
        return;
      }
      _maintenanceBusy = true;
      final epoch = _runEpoch;
      unawaited(_seedImageOriginalTasks(epoch));
      try {
        await _database.recoverDeliveryReceipts();
        _checkRun(epoch);
        final reconciliation = await _database.reconciliationWork();
        for (final customer in reconciliation
            .where((row) =>
                row['blocksCustomer'] != false &&
                row['state'] == 'delivery_unknown')
            .map((row) => row['user_id']! as String)
            .toSet()) {
          if (await _database.isolateUncertainDelivery(customer)) {
            _checkRun(epoch);
            unawaited(_drainHostedCompletions(customer, epoch));
            _scheduleDraftGeneration(customer, newEvidence: false);
          }
        }
        JdV2Delivery.afterReceipts(_database);
        await _database.recheckHistoryFaults();
        if (!_autoCaptureRunning || epoch != _runEpoch) return;
        final recoverableAdmissions =
            await _mediaAudit.pendingAdmissionRecoveries();
        _checkRun(epoch);
        final ownerRepairCustomers =
            await _mediaRegistrar.pendingOwnerRepairCustomers();
        _checkRun(epoch);
        var resumedMedia = false;
        for (final customer in {
          ...recoverableAdmissions.map((gap) => gap['customer']! as String),
          ...ownerRepairCustomers,
        }) {
          try {
            final recovered = await _mediaRegistrar.recoverPendingAdmissions(
                customer: customer, checkCurrent: () => _checkRun(epoch));
            _checkRun(epoch);
            final resumed = await _evidenceStore
                .resumeAdmittedMediaEvidence(recovered.originEvidenceIds);
            resumedMedia = resumed > 0 || resumedMedia;
            if (recovered.createdAdmissions.isNotEmpty) {
              _scheduleDraftGeneration(customer, newEvidence: true);
            } else if (ownerRepairCustomers.contains(customer)) {
              _scheduleDraftGeneration(customer, newEvidence: false);
            }
          } catch (error) {
            if (!_autoCaptureRunning || epoch != _runEpoch) return;
            RuntimeTrace.record('queue.maintenance_failed', {
              'customer': customer,
              'stage': 'media_admission_recovery',
              'error': error.runtimeType.toString(),
            });
          }
        }
        if (resumedMedia) unawaited(_drainEvidenceInbox(mediaOnly: true));
        final settledTransfers = await _database.recoverChatTransferAttempts(
            activeCustomers: _transferringCustomers);
        if (_autoCaptureRunning && epoch == _runEpoch) {
          for (final customer in settledTransfers) {
            _scheduleDraftGeneration(customer, newEvidence: false);
          }
        }
        await _refreshTickets();
        if (!_autoCaptureRunning || epoch != _runEpoch) return;
        if (await _database.hasReadyDeliveryWork()) _requestDelivery();
        for (final ticket in await _database.duePreclickHandoffs()) {
          if (!_autoCaptureRunning || epoch != _runEpoch) break;
          unawaited(_autoTransferTicket(ticket));
        }
        if (!_autoCaptureRunning || epoch != _runEpoch) return;
        for (final job in await _database.pendingSlaFallbackJobs()) {
          if (!_autoCaptureRunning || epoch != _runEpoch) return;
          if (!_slaFallbackTimers.containsKey(job.userId) &&
              await _database.isPlatformResponsePending(job)) {
            _armSlaFallback(job);
          }
        }
        if (!_autoCaptureRunning || epoch != _runEpoch) return;
        for (final customer in _mediaAcquisition.keys.toList()) {
          if (!_autoCaptureRunning || epoch != _runEpoch) return;
          if (_unreadRecovery.containsKey(customer) ||
              (_visualMediaCaptures[customer] ?? 0) > 0) {
            continue;
          }
          if (await _database.isHumanContacting(customer) ||
              (await _mediaInventory.pendingMediaForTask(customer)).isEmpty) {
            _mediaAcquisition.remove(customer);
          }
        }
        for (final conversation in await _database.conversations()) {
          if (!_autoCaptureRunning || epoch != _runEpoch) return;
          if (!_draftRetryTimers.containsKey(conversation.userId)) {
            _scheduleDraftGeneration(conversation.userId, newEvidence: false);
          }
        }
        if (!_autoCaptureRunning || epoch != _runEpoch) return;
        for (final item in await _database.pendingHealth()) {
          if (!_autoCaptureRunning || epoch != _runEpoch) return;
          final user = item['user_id']! as String;
          if (await _database.isHandoffPending(user)) {
            final service = await _database.handoffServiceStatus(user);
            final key = '$user:handoff';
            final now = DateTime.now();
            if (now.difference(_healthLoggedAt[key] ?? DateTime(1970)) >=
                const Duration(seconds: 30)) {
              _healthLoggedAt[key] = now;
              RuntimeTrace.record(
                  service?['requiresOperator'] == true
                      ? 'handoff.business_unresolved'
                      : 'handoff.waiting_for_agent',
                  {
                    'customer': user,
                    'ordinaryGenerationPaused': false,
                    'contextPreserved': true,
                    'handoffCompleted': false,
                    'businessResponseSent': false,
                    'caseResolved': null,
                    'holdingDoesNotResolve': true,
                    'reason': service?['state'],
                    'ticketId': service?['ticketId'],
                    'logId': service?['logId'],
                    'retryAtMs': service?['retryAtMs'],
                    'requiresOperator': service?['requiresOperator'],
                  });
            }
          }
          final age = DateTime.now().millisecondsSinceEpoch -
              (item['waiting_since_ms']! as int);
          if (age < 45000) continue;
          final key = '$user:generation';
          final now = DateTime.now();
          if (now.difference(_healthLoggedAt[key] ?? DateTime(1970)) <
              const Duration(seconds: 10)) {
            continue;
          }
          _healthLoggedAt[key] = now;
          RuntimeTrace.record('generation.overdue', {
            'customer': user,
            'ageMs': age,
            'active': _activeDraftUsers.contains(user),
            'nextActionAtMs': item['generation_retry_at_ms'],
            'attempts': item['generation_attempts'],
            'lastError': item['generation_last_error']
          });
          if (mounted) {
            setState(() => _diagnostics =
                '$user 的正式答复仍在处理中，已等待 ${age ~/ 1000} 秒；队列和原始消息已保留。');
          }
        }
        final faults = await _database.historyFaults();
        if (mounted && faults.isNotEmpty) {
          setState(() => _error =
              '客户 ${faults.map((r) => r['user_id']).join('、')} 的历史文件异常，已隔离并保留；其他客户继续处理。');
        } else if (mounted &&
            _error is String &&
            (_error as String).contains('的历史文件异常，已隔离')) {
          setState(() => _error = null);
        }
        final work = await _database.reconciliationWork();
        for (final item in work) {
          final user = item['user_id']! as String;
          final now = DateTime.now();
          final since = item['since_ms'] as int;
          if (item['state'] == 'quarantined') {
            if (mounted) {
              setState(() => _error = '$user 的草稿记录异常，已隔离并保留；其他客户继续处理。');
            }
            continue;
          }
          if (now.millisecondsSinceEpoch - since < 20000) continue;
          if (now.difference(_healthLoggedAt[user] ?? DateTime(1970)) <
              const Duration(seconds: 10)) {
            continue;
          }
          _healthLoggedAt[user] = now;
          RuntimeTrace.record('delivery.reconciliation_overdue', {
            'customer': user,
            'state': item['state'],
            'ageMs': now.millisecondsSinceEpoch - since,
            'action': 'verify_receipt_without_retyping'
          });
          if (mounted) {
            setState(() => _error = '$user 的发送结果尚待核实，回复已保留；请检查京麦发送状态。');
          }
        }
        if (!_autoCaptureRunning || epoch != _runEpoch) return;
        await _armDeliveryWake();
      } catch (error) {
        RuntimeTrace.record('queue.maintenance_failed',
            {'error': error.runtimeType.toString()});
      } finally {
        if (epoch == _runEpoch) _maintenanceBusy = false;
      }
    } finally {
      releaseDiagnosticWork();
    }
  }

  void _requestDelivery() {
    if (!_autoCaptureRunning) return;
    _deliveryRequested = true;
    if (_deliveryWorkerRunning) return;
    _deliveryWorkerRunning = true;
    _deliveryWorkerEpoch = _runEpoch;
    unawaited(_runDeliveryWorker(_runEpoch));
  }

  Future<void> _runDeliveryWorker(int epoch) async {
    final releaseDiagnosticWork = _diagnosticWork.acquire();
    try {
      var hostedPresentationChanged = false;
      try {
        do {
          _deliveryRequested = false;
          while (_autoCaptureRunning && epoch == _runEpoch) {
            final transferOwnsUi = await _transferWorkOwnsUi();
            final completedCustomer =
                _completedApiDeliveryCustomers.firstOrNull;
            final delivery = await _database.nextReadyDelivery(
                userId: completedCustomer,
                onlyWithinResponseWindow: transferOwnsUi);
            if (!_autoCaptureRunning || epoch != _runEpoch) return;
            if (delivery == null) {
              if (completedCustomer != null) {
                _completedApiDeliveryCustomers.remove(completedCustomer);
                if (transferOwnsUi) _retryDeliveryAfterTransfer();
                continue;
              }
              if (transferOwnsUi) _retryDeliveryAfterTransfer();
              for (final row in await _database.pendingHealth()) {
                unawaited(_queueDraftIfPending(row['user_id']! as String));
              }
              break;
            }
            if (_nativeSlaAttempts.containsKey(delivery.userId)) {
              unawaited(_yieldUnclickedHoldingForFormal(delivery.userId));
            }
            try {
              final deadline =
                  await _database.platformDeliveryDeadline(delivery.userId);
              final reserved = await _database
                  .responseSlotOwner(delivery.userId, ownDeadline: deadline);
              if (reserved != null) {
                RuntimeTrace.record('delivery.yielded_to_red_deadline', {
                  'customer': delivery.userId,
                  'reservedCustomer': reserved.userId,
                  'cycleId': reserved.batchStartMessageId,
                  'deadline': reserved.dueAt.toIso8601String()
                });
                // No lease and no draft mutation. The watchdog retries after the
                // expiring response has had a chance to use the UI.
                _deliveryRetryTimer?.cancel();
                _deliveryRetryTimer =
                    Timer(const Duration(seconds: 1), _requestDelivery);
                break;
              }
              final early = delivery.wasGeneratedWithinResponseWindow;
              if (await _transferWorkOwnsUi() && !early) {
                _retryDeliveryAfterTransfer();
                break;
              }
              await _yieldOptionalUiWorkForReply(epoch,
                  mayInterruptTransfer: early);
              var deferredForTransfer = false;
              await _withJdUiOperation(() async {
                if (await _transferWorkOwnsUi() &&
                    !delivery.wasGeneratedWithinResponseWindow) {
                  deferredForTransfer = true;
                  return;
                }
                await _sendAutomaticallyUnlocked(
                    delivery.userId, delivery.draft,
                    taskId: delivery.taskId);
              },
                  deadline: deadline,
                  priority: early && deadline != null
                      ? JdUiPriority.responseDeadline
                      : JdUiPriority.delivery);
              if (deferredForTransfer) {
                _retryDeliveryAfterTransfer();
                break;
              }
            } catch (error) {
              if (!_autoCaptureRunning || epoch != _runEpoch) return;
              if (error is PlatformException &&
                  error.code == 'media_context_changed') {
                await _database.markGeneratedDraftDeliveryFailure(
                    userId: delivery.userId,
                    taskId: delivery.taskId,
                    error: error.toString(),
                    retryDelay: Duration.zero);
                await _database.retireStaleMediaDraft(delivery.userId);
                unawaited(_queueDraftIfPending(delivery.userId));
                continue;
              }
              // Every retained generated reply returns to the serial delivery
              // queue. A matching observed receipt can reconcile an ambiguous
              // click before the retry fires, but no delivery state may freeze
              // this customer's later work indefinitely.
              if (_isMissingConversation(error)) {
                // Persist the native attempt phase for every suspension. A
                // post-click reception error is uncertainty, not an idle sender.
                await _database.markGeneratedDraftDeliveryFailure(
                    userId: delivery.userId,
                    taskId: delivery.taskId,
                    error: error.toString(),
                    retryDelay: const Duration(seconds: 3));
                await _suspendMissingConversation(delivery.userId, error);
              } else {
                await _database.markGeneratedDraftDeliveryFailure(
                  userId: delivery.userId,
                  taskId: delivery.taskId,
                  error: error.toString(),
                  retryDelay: _deliveryFailureRetryDelay,
                );
                await _armDeliveryWake();
              }
              if (mounted) {
                setState(() {
                  _error = error;
                  RuntimeTrace.record('ui.error', {'error': '$error'});
                });
              }
            }
            if (!_autoCaptureRunning || !mounted) break;
            if (_usesHostedReplies) {
              hostedPresentationChanged = true;
            } else {
              await _coordinator.refresh();
            }
          }
        } while (
            _autoCaptureRunning && epoch == _runEpoch && _deliveryRequested);
      } finally {
        if (_deliveryWorkerEpoch == epoch) {
          _deliveryWorkerRunning = false;
          _deliveryWorkerEpoch = null;
          if (_deliveryRequested && epoch == _runEpoch && _autoCaptureRunning) {
            _requestDelivery();
          } else if (hostedPresentationChanged &&
              epoch == _runEpoch &&
              mounted) {
            // Refresh the conversation list after the ready send lane is drained.
            unawaited(_coordinator.refresh());
          }
        }
      }
    } finally {
      releaseDiagnosticWork();
    }
  }

  void _retryDeliveryAfterTransfer() {
    _deliveryRetryTimer?.cancel();
    _deliveryRetryTimer = Timer(const Duration(seconds: 1), _requestDelivery);
  }

  Future<void> _yieldOptionalUiWorkForReply(int epoch,
      {required bool mayInterruptTransfer}) async {
    // A reply may prepare in the background, but cannot interrupt a transfer's
    // foreground transaction or cause its modal to close.
    _checkRun(epoch);
  }

  Future<T> _withJdUiOperation<T>(Future<T> Function() operation,
      {DateTime? deadline,
      JdUiPriority priority = JdUiPriority.delivery}) async {
    final epoch = _runEpoch;
    _pendingJdUiOperations++;
    final waiting = Stopwatch()..start();
    try {
      return await _jdUiScheduler.run(() {
        _checkRun(epoch);
        RuntimeTrace.record('ui.queue_acquired', {
          'waitMs': waiting.elapsedMilliseconds,
          'queued': _pendingJdUiOperations,
          'priority': deadline == null ? 'delivery' : 'ready_reply',
          'deadline': deadline?.toUtc().toIso8601String(),
        });
        return runZoned(operation,
            zoneValues: {MacOSCaptureAdapter.automationEpochZoneKey: epoch});
      }, priority: priority, deadline: deadline);
    } finally {
      _pendingJdUiOperations--;
    }
  }

  Future<T> _withFallbackPriority<T>(Future<T> Function() operation,
      {required DateTime deadline, bool preemptTransfer = true}) async {
    final epoch = _runEpoch;
    _priorityUiOperations++;
    if (preemptTransfer) _slaPreemptiveUiOperations++;
    final waiting = Stopwatch()..start();
    try {
      await _yieldOptionalUiWorkForReply(epoch,
          mayInterruptTransfer: preemptTransfer);
      return await _jdUiScheduler.run(() {
        _checkRun(epoch);
        RuntimeTrace.record('ui.queue_acquired', {
          'waitMs': waiting.elapsedMilliseconds,
          'priority': 'responseDeadline',
          'deadline': deadline.toUtc().toIso8601String(),
        });
        return runZoned(operation,
            zoneValues: {MacOSCaptureAdapter.automationEpochZoneKey: epoch});
      }, priority: JdUiPriority.responseDeadline, deadline: deadline);
    } finally {
      _priorityUiOperations--;
      if (preemptTransfer) _slaPreemptiveUiOperations--;
    }
  }

  Future<bool> _canDeliverGeneratedDraft(String userId, String reply,
      {String? taskId}) async {
    final completedReady = await _database.isCompletedApiDraftReadyForSend(
        userId: userId, reply: reply, taskId: taskId);
    if (completedReady == null) await _database.retireStaleMediaDraft(userId);
    String? reason;
    final operationEpoch =
        Zone.current[MacOSCaptureAdapter.automationEpochZoneKey];
    if (operationEpoch is int && operationEpoch != _runEpoch) {
      reason = 'automation_epoch_changed';
    } else if (!_autoCaptureRunning) {
      reason = 'automation_stopped';
    } else if (_database.businessDayHasChanged) {
      reason = 'business_day_changed';
      unawaited(_rollBusinessDay(_runEpoch));
    } else if (completedReady == null &&
        !await _database.validateCustomerHistory(userId)) {
      reason = 'customer_history_unavailable';
    } else if (completedReady == false ||
        completedReady == null &&
            !await _database.isGeneratedDraftReadyForSend(
                userId: userId, reply: reply, taskId: taskId)) {
      reason = 'draft_invalidated';
    } else if (await _database.isHumanContacting(userId)) {
      reason = 'human_contacting';
    }
    if (reason != null) {
      RuntimeTrace.record('delivery.skipped', {
        'customer': userId,
        'taskId': taskId,
        'reason': reason,
      });
      RuntimeTrace.record('delivery.condition', {
        'customer': userId,
        'taskId': taskId,
        'stage': 'delivery.state_validation',
        'conditionId': reason,
        'sourceFile': 'lib/main.dart',
        'sourceSymbol': '_canDeliverGeneratedDraft',
        'expression': switch (reason) {
          'automation_epoch_changed' => 'operationEpoch == currentEpoch',
          'automation_stopped' => 'automationRunning == true',
          'business_day_changed' => 'businessDayHasChanged == false',
          'customer_history_unavailable' =>
            'validateCustomerHistory(customer) == true',
          'draft_invalidated' =>
            'isDraftReadyForSend(customer, taskId, reply) == true',
          'human_contacting' => 'isHumanContacting(customer) == false',
          _ => reason,
        },
        'actual': {
          'operationEpoch': operationEpoch,
          'currentEpoch': _runEpoch,
          'automationRunning': _autoCaptureRunning,
          'completedApiDraftReady': completedReady,
          'observedFailure': reason,
        },
        'threshold': {'required': 'condition must be true'},
        'passed': false,
        'outcome': 'blocked',
      });
    }
    return reason == null;
  }

  Future<bool> _sendAutomaticallyUnlocked(String userId, AiDraft draft,
      {String? taskId}) async {
    final deliveryEpoch = _runEpoch;
    if (!await _canDeliverGeneratedDraft(userId, draft.reply, taskId: taskId)) {
      return false;
    }
    var submitted = false;
    try {
      // Draft generation is independent from sidebar scanning. Another unread
      // customer may have become visible while Codex was working, so reopen
      // and verify the draft's exact customer immediately before sending.
      final mediaPaths = draft.attachments
          .where((attachment) => attachment.url.scheme == 'file')
          .map((attachment) => attachment.url.toFilePath())
          .toList(growable: false);
      if (mediaPaths.length != draft.attachments.length) {
        throw StateError(
            'Automatic media sending requires verified local files.');
      }
      final timing = await _database.deliveryTiming(userId, taskId);
      final responseCycle = await _database.platformResponseCycle(userId);
      final responseStart = responseCycle?['state'] == 'waiting'
          ? (responseCycle?['started_at_ms'] as int?)
          : null;
      final responseCycleId = responseCycle?['cycle_id'] as String? ?? '';
      final sent = await _directDelivery.deliver(
        customer: userId,
        reply: draft.reply,
        mediaPaths: mediaPaths,
        responseCycleId: responseCycleId,
        preClickDeadline: responseStart == null
            ? null
            : _replyClickDeadline(
                DateTime.fromMillisecondsSinceEpoch(responseStart)),
        canSend: () =>
            _canDeliverGeneratedDraft(userId, draft.reply, taskId: taskId),
        beforeSend: () async {
          final attempt = await _database.beginDeliveryAttempt(
              userId: userId,
              reply: draft.reply,
              taskId: taskId,
              expectedResponseCycleId: responseCycleId);
          await JdV2Delivery.onAttempt(_database, userId, draft, attempt);
          return attempt;
        },
      );
      if (!sent) {
        unawaited(_queueDraftIfPending(userId));
        return false;
      }
      submitted = true;
      _completedApiDeliveryCustomers.remove(userId);
      await _database.markReplySent(
          userId: userId, reply: draft.reply, expectedTaskId: taskId);
      _checkRun(deliveryEpoch);
      _wakeGenerationAfterFormalCommit(userId);
      final newerPending = await _database.hasPendingUnanswered(userId);
      if (!newerPending) {
        _finishUnreadRecovery(userId);
        final liveCycle = await _database.platformResponseCycle(userId);
        if (liveCycle?['cycle_id'] == responseCycle?['cycle_id'] &&
            liveCycle?['state'] != 'waiting') {
          _forgetSlaTimer(userId,
              expectedCycleId: responseCycle?['cycle_id'] as String?);
        }
        final evidence = _processingUnreadEvidence[userId];
        if (evidence != null) {
          _handledUnreadEvidence[userId] = evidence;
          _handledUnreadAt[userId] = DateTime.now();
        }
      }
      RuntimeTrace.record('delivery.turn_completed', {
        'customer': userId,
        ...formalReplyTiming(timing,
            confirmedAt: DateTime.now(),
            clickedAt: _lastPhysicalReplyAt[userId]),
        'mediaContextRevision': draft.mediaContextRevision,
        'newerPendingPreserved': newerPending,
        'pendingMessageId': await _database.pendingMessageId(userId),
        'answeredMessageId': await _database.answeredMessageId(userId)
      });
      if (mounted) {
        setState(() {
          _diagnostics =
              'Verified and automatically sent ${draft.model} reply to $userId.';
        });
      }
      return true;
    } catch (error) {
      if (error is _AutomationStopped) rethrow;
      if (mounted) {
        setState(() => _diagnostics =
            'Automatic send to $userId failed; the reply remains queued for retry.');
      }
      if (submitted) {
        throw PlatformException(
            code: 'send_unconfirmed',
            message:
                'Native submitted the reply; local completion must be reconciled: $error');
      }
      rethrow;
    }
  }

  Future<void> _recordOcrEvidence(ViewportEvidence evidence,
      OcrInspection inspection, OcrExtractionAttempt extraction) async {
    final path = '${evidence.manifestPath}.ocr.json';
    try {
      final payload = {
        'appVersion': AppRuntime.version,
        'evidenceId': evidence.id,
        'customer': evidence.customer,
        'activeCustomerId': inspection.activeCustomerId,
        'windowId': inspection.windowId,
        'capturedAtMs': inspection.capturedAt.millisecondsSinceEpoch,
        'imageWidth': inspection.imageWidth,
        'imageHeight': inspection.imageHeight,
        'sourcePngSHA256': evidence.metadata['pngSHA256'],
        'ocrEngine': inspection.ocrEngine,
        'chatRegion': {
          'top': inspection.chatTop,
          'bottom': inspection.chatBottom,
          'left': inspection.chatLeft,
          'right': inspection.chatRight
        },
        'observations': [
          for (final o in inspection.observations)
            {
              'text': o.text,
              'confidence': o.confidence,
              'x': o.x,
              'y': o.y,
              'width': o.width,
              'height': o.height,
              'rotationDegrees': o.rotationDegrees,
              'isWatermark': o.isWatermark
            }
        ],
        'visualRegions': [
          for (final o in inspection.visualRegions)
            {
              'confidence': o.confidence,
              'x': o.x,
              'y': o.y,
              'width': o.width,
              'height': o.height
            }
        ],
        if (inspection.physicalMediaRegions != null)
          'physicalMediaRegions': [
            for (final card in inspection.physicalMediaRegions!)
              {
                'x': card.x,
                'y': card.y,
                'width': card.width,
                'height': card.height,
                'confidence': card.confidence,
                'proof': 'full_card_pixels'
              }
          ],
        'unboundMediaRegions': [
          for (final region in inspection.unboundMediaRegions)
            {
              'x': region.x,
              'y': region.y,
              'width': region.width,
              'height': region.height,
              'confidence': region.confidence,
              'proof': 'explicit_play_overlay',
            }
        ],
      };
      await AtomicEvidenceWriter.write(path, jsonEncode(payload),
          session: evidence.metadata['automationSessionId']?.toString() ?? '');
      RuntimeTrace.record('evidence.ocr_trace_saved', {
        'customer': evidence.customer,
        'evidenceId': evidence.id,
        'path': path
      });
    } catch (error) {
      RuntimeTrace.record('evidence.ocr_trace_failed', {
        'customer': evidence.customer,
        'evidenceId': evidence.id,
        'error': '$error'
      });
      rethrow;
    }
    RuntimeTrace.record('capture.text_analysis', {
      'customer': evidence.customer,
      'evidenceId': evidence.id,
      'observationCount': inspection.observations.length,
      'reason': extraction.reason,
      'belowStandardConfidenceCount': inspection.observations
          .where((o) =>
              o.confidence < OcrCaptureExtractor.senderConfidenceThreshold)
          .length,
      'latestIncomingAt':
          extraction.latestIncomingSentAt?.toUtc().toIso8601String(),
      'latestVisibleSenderIsIncoming': extraction.latestVisibleSenderIsIncoming,
      'latestIncomingHasText': extraction.latestIncomingHasText,
      'candidates': [
        for (final m in extraction.capture?.messages ?? <CapturedMessage>[])
          {
            'messageId': m.stableId,
            'direction': m.direction,
            'senderAt': m.sentAt?.toUtc().toIso8601String(),
            'bodyChars': m.body.length,
            'bodyHash': sha256.convert(utf8.encode(m.body)).toString()
          }
      ],
    });
  }

  Future<VisibleImagePayload> _verifyFrameMatchedVideoOwner(
      String customer, VisibleImagePayload visible) async {
    if (visible.reason != 'pixel_matched_unique_video_frame' ||
        visible.video == null) {
      return visible;
    }
    final recovery = _unreadRecovery[customer] ?? _mediaAcquisition[customer];
    if (recovery != null &&
        visible.cacheKey != null &&
        visible.cacheModifiedAt != null &&
        _claimDirectCachedMedia(
            customer,
            recovery,
            CachedMediaPayload(
                kind: 'video',
                cacheKey: visible.cacheKey!,
                cacheModifiedAt: visible.cacheModifiedAt!,
                video: visible.video))) {
      return visible;
    }
    RuntimeTrace.record('media.frame_match_owner_unconfirmed', {
      'customer': customer,
      'cacheKey': visible.cacheKey,
      'action': 'preserve_preview_without_claiming_original',
      'temporalOwnershipChecksPreserved': true
    });
    final doc = await (await _database.history).read(customer);
    final used = (doc?['messages'] as List? ?? const []).whereType<Map>().any(
        (m) => (m['media'] as List? ?? const [])
            .whereType<Map>()
            .any((a) => a['path'] == visible.video!.path));
    if (!used) await _deleteRejectedCachedVideo(visible.video);
    return VisibleImagePayload(
        kind: 'video',
        mimeType: visible.mimeType,
        extension: visible.extension,
        originalName: visible.originalName,
        visualFingerprint: visible.visualFingerprint,
        captureSource: visible.captureSource,
        reason: 'frame_match_owner_unconfirmed',
        foregroundFraction: visible.foregroundFraction,
        cardPreviewBytes: visible.cardPreviewBytes,
        playbackOverlayDetected: visible.playbackOverlayDetected,
        bytes: visible.bytes);
  }

  Future<String> _classifyMediaCard(String customer, String receipt,
      VisibleImagePayload visible, OcrVisualRegion region,
      {String? evidenceId}) async {
    final epoch = _runEpoch;
    final before = await _mediaInventory.revision(customer);
    _checkRun(epoch);
    final result = await _mediaInventory.classify(receipt, visible.kind,
        fingerprint: visible.visualFingerprint,
        previewBytes: visible.cardPreviewBytes ?? visible.bytes,
        evidenceId: evidenceId,
        region: [region.x, region.y, region.width, region.height]);
    await _mediaInventory.resolveMediaTypeVerification(customer,
        receiptId: result,
        nativeKind: visible.kind,
        captureSource: visible.captureSource,
        playbackOverlayDetected: visible.playbackOverlayDetected,
        hasVideoObject: visible.video != null,
        hasImageBytes: visible.bytes != null);
    _checkRun(epoch);
    final after = await _mediaInventory.revision(customer);
    final cancellation = _activeDraftCancellations[customer];
    if (after != before &&
        _activeDraftMediaSensitive[customer] == true &&
        cancellation != null &&
        !cancellation.isCancelled) {
      await _cancelGenerationForChangedInputs(customer, {
        'reason': 'verified_card_type_corrected',
        'beforeRevision': before,
        'afterRevision': after,
        'evidenceId': evidenceId,
        'receiptId': result,
      });
    }
    return result;
  }

  /// Background evidence may update this customer's inventory while a reply
  /// is being generated. Only changes to that reply's leased inputs can
  /// invalidate it; a customer-wide revision is merely a reason to recheck.
  Future<void> _cancelGenerationForChangedInputs(
      String customer, Map<String, Object?> details) async {
    final token = _activeDraftTokens[customer];
    final cancellation = _activeDraftCancellations[customer];
    if (token == null || cancellation == null || cancellation.isCancelled) {
      return;
    }
    if (await _database.generationInputVersionsCurrent(customer,
        generationToken: token)) {
      return;
    }
    if (_activeDraftTokens[customer] != token ||
        !identical(_activeDraftCancellations[customer], cancellation)) {
      return;
    }
    cancellation.cancel();
    RuntimeTrace.record('generation.media_revision_superseded', {
      ...details,
      'customer': customer,
      'generationToken': token,
      'reason': 'leased_message_input_changed',
    });
  }

  /// Clear chat text may explain an obscured bubble or retract its synthetic
  /// fallback preview. Resolve the same receipt before admitting another input.
  Future<Map<String, String>> _clarifyUnknownTextInputs(
    ViewportEvidence evidence,
    OcrInspection inspection,
    CapturedConversation? capture, {
    required Iterable<OcrVisualRegion> excludedRegions,
  }) async {
    final session = _automationSessionId;
    if (session == null ||
        capture == null ||
        inspection.activeCustomerId != evidence.customer) {
      return {};
    }
    final epoch = _runEpoch;
    final db = await _database.database;
    final candidates = await db.rawQuery(
      '''SELECT m.* FROM customer_media_items m
      JOIN automation_session_messages w
        ON w.session_id=m.admission_session_id AND w.user_id=m.customer
        AND w.message_id=m.message_id
      WHERE m.customer=? AND m.admission_session_id=?
        AND m.canonical_id IS NULL AND m.kind IN ('unknown','image')
        AND m.identity_ambiguous=0 AND w.response_state='pending' ''',
      [evidence.customer, session],
    );
    final claims =
        <String, List<({Map<String, Object?> row, CapturedMessage text})>>{};
    for (final row in candidates) {
      _checkRun(epoch);
      final weakImage = row['kind'] == 'image';
      if (weakImage &&
          !await _database.isWeakScreenshotTextCandidate(
              evidence.customer, row['item_id']! as String)) {
        continue;
      }
      if (!weakImage &&
          (jsonDecode(row['media_json']! as String) as List).isNotEmpty) {
        continue;
      }
      // A newer observation may update the inventory's last evidence while
      // this older frozen frame is still being decoded. Its own exact receipt
      // observation is the best source for a same-frame text refinement.
      final currentObservations = await db.query(
        'media_card_observations',
        where: 'customer=? AND evidence_id=? AND (item_id=? OR canonical_id=?)',
        whereArgs: [
          evidence.customer,
          evidence.id,
          row['item_id'],
          row['item_id'],
        ],
      );
      final source = currentObservations.isNotEmpty
          ? evidence
          : await _evidenceStore.lookup(row['evidence_id']! as String);
      if (source == null ||
          source.customer != evidence.customer ||
          source.metadata['automationSessionId'] != session) {
        continue;
      }
      final original = _registeredEvidenceOcr[source.id] ??
          await _readRegisteredEvidenceOcr(source);
      if (original == null) continue;
      final observations = source.id == evidence.id
          ? currentObservations
          : await db.query(
              'media_card_observations',
              where:
                  'customer=? AND evidence_id=? AND (item_id=? OR canonical_id=?)',
              whereArgs: [
                evidence.customer,
                source.id,
                row['item_id'],
                row['item_id'],
              ],
            );
      final proposed = <String, CapturedMessage>{};
      for (final observation in observations) {
        final box = (jsonDecode(observation['region_json']! as String) as List)
            .cast<num>();
        if (box.length != 4) continue;
        final match = weakImage
            ? UnknownMessageClarifier.matchWeakScreenshotText
            : UnknownMessageClarifier.match;
        final text = match(
          customer: evidence.customer,
          original: original,
          originalRegion: OcrVisualRegion(
            x: box[0].toDouble(),
            y: box[1].toDouble(),
            width: box[2].toDouble(),
            height: box[3].toDouble(),
            confidence: 0,
          ),
          current: inspection,
          messages: capture.messages,
          excludedRegions: excludedRegions,
        );
        if (text != null) proposed[text.stableId] = text;
      }
      if (proposed.length != 1) continue;
      final text = proposed.values.single;
      claims.putIfAbsent(text.stableId, () => []).add((row: row, text: text));
    }
    final replacements = <String, String>{};
    for (final entry in claims.entries) {
      // Conflicting ownership stays unresolved; it never merges two bubbles.
      if (entry.value.length != 1) continue;
      final claim = entry.value.single;
      _checkRun(epoch);
      final clarify = claim.row['kind'] == 'image'
          ? _database.clarifyWeakImageMessageAsText
          : _database.clarifyUnknownMessageAsText;
      final parent = await clarify(
        evidence.customer,
        parentMessageId: claim.row['message_id']! as String,
        receiptId: claim.row['item_id']! as String,
        text: CapturedMessage(
          stableId: claim.text.stableId,
          direction: claim.text.direction,
          body: claim.text.body,
          sender: claim.text.sender,
          sentAt: claim.text.sentAt,
          axPath: claim.text.axPath,
          observationTurnKey: claim.text.observationTurnKey,
          captureEvidenceId: evidence.id,
        ),
        evidenceId: evidence.id,
        expectedSessionId: session,
      );
      _checkRun(epoch);
      if (parent == null) continue;
      replacements[entry.key] = parent;
      await _mediaAudit.confirmTextParent(
        evidence.customer,
        parentMessageId: parent,
        receiptId: claim.row['item_id']! as String,
        expectedSessionId: session,
      );
      _checkRun(epoch);
      await _evidenceStore.retireResolvedMedia(evidence.customer);
      _checkRun(epoch);
    }
    if (replacements.isNotEmpty) {
      _slaPreparedReplies.remove(evidence.customer);
      _scheduleDraftGeneration(evidence.customer, newEvidence: true);
    }
    return replacements;
  }

  CapturedConversation? _withClarifiedTextIds(
    CapturedConversation? capture,
    Map<String, String> replacements,
  ) {
    if (capture == null || replacements.isEmpty) return capture;
    return CapturedConversation(
      stableKey: capture.stableKey,
      customerName: capture.customerName,
      customerExternalId: capture.customerExternalId,
      capturedAt: capture.capturedAt,
      automationSessionId: capture.automationSessionId,
      messages: [
        for (final message in capture.messages)
          if (replacements[message.stableId] case final String parent)
            CapturedMessage(
              stableId: parent,
              direction: 'incoming',
              body: message.body,
              sender: message.sender,
              sentAt: message.sentAt,
              axPath: message.axPath,
              observationTurnKey: message.observationTurnKey,
              captureEvidenceId: message.captureEvidenceId,
            )
          else
            message,
      ],
    );
  }

  Future<Map?> _mediaConversationFrontier(String customer,
      {bool baselineOnly = false}) async {
    final document = await (await _database.history).read(customer);
    final baseline = await _evidenceStore.baselineEvidenceId(customer);
    final db = await _database.database;
    final attempts =
        (await db.rawQuery('''SELECT attempt_id FROM delivery_attempts
      WHERE user_id=? AND NOT EXISTS(SELECT 1 FROM automation_archived_attempts a
        WHERE a.attempt_id=delivery_attempts.attempt_id)''', [customer]))
            .map((row) => row['attempt_id'])
            .toSet();
    final messages =
        (document?['messages'] as List? ?? const []).whereType<Map>();
    final trusted = messages.where((message) =>
        (message['direction'] == 'incoming' &&
            (message['live_observed_session_ids'] as List? ?? const [])
                .contains(_automationSessionId)) ||
        (message['direction'] == 'outgoing' &&
            attempts.contains(message['delivery_attempt_id']) &&
            const {'sent', 'accepted'}.contains(message['delivery_status'])));
    Map anchored(Map frontier, Iterable<Map> context) => {
          ...frontier,
          'visibleTextAnchors': context
              .where((message) =>
                  (message['media'] as List? ?? const []).isEmpty &&
                  message['media_receipt_id'] == null &&
                  (message['body']?.toString().trim() ?? '').isNotEmpty)
              .toList()
              .reversed
              .take(6)
              .map((message) => {
                    for (final key in ['id', 'body', 'direction', 'sent_at'])
                      if (message.containsKey(key)) key: message[key],
                  })
              .toList(),
        };
    Map? newestMessage(Iterable<Map> values) {
      final items = values.toList(growable: false);
      if (items.isEmpty) return null;
      DateTime? clock(Map message) =>
          DateTime.tryParse(message['sent_at']?.toString() ?? '');
      // A not-yet-readable media header still needs its physical anchor.
      // Otherwise late OCR of an older page must not move the frontier back.
      if (clock(items.last) == null) return items.last;
      Map latest = items.last;
      for (final item in items) {
        final at = clock(item);
        if (at != null && at.isAfter(clock(latest)!)) latest = item;
      }
      return latest;
    }

    final received =
        trusted.where((message) => message['direction'] == 'incoming');
    if (!baselineOnly && received.isNotEmpty) {
      return anchored(newestMessage(received)!, trusted);
    }
    if (!baselineOnly && trusted.isNotEmpty) {
      return anchored(newestMessage(trusted)!, trusted);
    }
    final baselineRows = await db.query('automation_session_baselines',
        where: 'session_id=? AND user_id=?',
        whereArgs: [_automationSessionId, customer]);
    final known = baselineRows.isEmpty
        ? const <String>{}
        : (jsonDecode(baselineRows.single['known_ids_json']! as String) as List)
            .whereType<String>()
            .toSet();
    final baselineMessages = messages.where((message) =>
        baseline != null &&
        (message['capture_evidence_id'] == baseline ||
            known.contains(message['id']) ||
            (message['observed_ids'] as List? ?? const [])
                .any(known.contains)));
    final old = newestMessage(baselineMessages);
    return (old == null ? null : anchored(old, baselineMessages)) ??
        (baseline == null
            ? null
            : {
                'id': 'empty-frontier:$_automationSessionId:$customer',
                'empty': true
              });
  }

  Future<Set<String>> _authorizeTextObservation(ViewportEvidence evidence,
      OcrInspection inspection, CapturedConversation? capture, Map? frontier,
      {Map<OcrVisualRegion, String> knownMediaParents = const {},
      Map<OcrVisualRegion, String> dependencyReceipts = const {}}) async {
    final session = _automationSessionId;
    final epoch = _runEpoch;
    if (session == null ||
        capture == null ||
        evidence.metadata['automationSessionId'] != session ||
        inspection.activeCustomerId != evidence.customer) {
      return {};
    }
    // Observation history can merge an OCR variant into its existing parent,
    // but it must not stamp an unproved old bubble as a new live input.
    await _database.saveCapture(capture,
        activateReplies: false, isCurrentViewport: false);
    _checkRun(epoch);
    final customer = evidence.customer;
    final ledger = (await (await _database.database).query(
            'automation_session_messages',
            columns: ['message_id'],
            where: 'session_id=? AND user_id=?',
            whereArgs: [_automationSessionId, customer]))
        .map((row) => row['message_id'])
        .toSet();
    final document = await (await _database.history).read(customer);
    _checkRun(epoch);
    final existing = <String>{
      for (final message
          in (document?['messages'] as List? ?? const []).whereType<Map>())
        if (ledger.contains(message['id']) ||
            (message['observed_ids'] as List? ?? const [])
                .any(ledger.contains)) ...{
          message['id']! as String,
          ...(message['observed_ids'] as List? ?? const []).whereType<String>(),
        },
    };
    final admitted = LiveMediaArrival.textInputs(
        evidence: evidence,
        inspection: inspection,
        messages: capture.messages,
        existingIds: existing,
        knownMediaParents: knownMediaParents,
        frontier: frontier);
    final saved = await _evidenceStore.lookup(evidence.id);
    _checkRun(epoch);
    final present = capture.messages
        .where((m) =>
            m.direction == 'incoming' &&
            m.media.isEmpty &&
            m.mediaReceiptId == null)
        .map((m) => m.stableId)
        .toSet();
    admitted.addAll(
        (saved?.metadata['admittedTextInputIds'] as List? ?? const [])
            .whereType<String>()
            .where(present.contains));
    if (admitted.isEmpty) return admitted;
    final messages = capture.messages
        .where(
            (m) => m.direction == 'incoming' && admitted.contains(m.stableId))
        .toList();
    // Register only actual admitted media dependencies, before the text can be
    // claimed for generation. Unbound old screenshots are not business owners.
    final dependencies = MediaCaptionDependency.inferScope(
        inspection, customer, messages, dependencyReceipts);
    await _evidenceStore.rememberTextInputs(evidence, admitted);
    _checkRun(epoch);
    final inserted = await _database.saveCapture(
        CapturedConversation(
            stableKey: capture.stableKey,
            customerName: capture.customerName,
            customerExternalId: capture.customerExternalId,
            capturedAt: capture.capturedAt,
            automationSessionId: session,
            messages: messages),
        activateReplies: true,
        isCurrentViewport: evidence.metadata['historyCutoffMs'] == null,
        activeIncomingIds: admitted,
        mediaInputDependencies: dependencies,
        dependencyEvidenceId: evidence.id);
    _checkRun(epoch);
    if (inserted > 0) _slaPreparedReplies.remove(customer);
    if (_autoCaptureRunning && await _database.hasPendingUnanswered(customer)) {
      _scheduleDraftGeneration(customer, newEvidence: inserted > 0);
    }
    return admitted;
  }

  Future<CapturedConversation?> _captureWithVisibleMedia(
    OcrInspection inspection,
    OcrExtractionAttempt extraction, {
    bool allowUnlabeledLatestImage = false,
    bool allowRecoveryAfterHolding = false,
    bool allowVideoDetectionActivation = false,
    bool registerOnly = false,
    _RunVideoProcessingUnlocked? runVideoProcessingUnlocked,
    ViewportEvidence? evidence,
    Set<String>? manualCoverageExcludedIds,
    Set<String>? liveTextInputIds,
  }) async {
    final releaseDiagnosticWork = _diagnosticWork.acquire();
    try {
      final epoch = _runEpoch;
      _checkRun(epoch);
      final customer =
          extraction.customerId ?? extraction.capture?.customerName;
      if (customer == null || inspection.windowId == 0) {
        return extraction.capture;
      }
      _visualMediaCaptures[customer] =
          (_visualMediaCaptures[customer] ?? 0) + 1;
      try {
        var textCapture = extraction.capture;
        final latestVisible = textCapture?.messages.lastOrNull;
        final onlyOurHoldingIsBelow = allowRecoveryAfterHolding &&
            latestVisible?.direction == 'outgoing' &&
            _isOwnHoldingReply(latestVisible?.body);

        // Keep verified OCR text, then inspect any customer-owned visual region in
        // the same viewport. A missed sender label can leave an older seller reply
        // as the last OCR message even when a new video is visible below it.
        const candidateSelector = OcrImageCandidateSelector();
        var imageCandidates = candidateSelector.select(
          inspection,
          customer,
          allowUnlabeledLatestImage: allowUnlabeledLatestImage,
          // Text on a customer's video thumbnail is video content, not a chat
          // message. Inspect dense rectangles for the play overlay as well.
          includeTextDense: true,
          customerText: (textCapture?.messages ?? const <CapturedMessage>[])
              .where((m) => m.direction == 'incoming' && m.media.isEmpty)
              .map((m) => m.body),
          // A new text question must not rescan a historical image above it.
          // Images with captions in this newest block remain eligible.
          onlyLatestCustomerBlock: evidence == null &&
              extraction.latestIncomingHasText &&
              !onlyOurHoldingIsBelow,
        );
        final viewportFallbackRegions = <OcrVisualRegion>[];
        if (evidence != null) {
          final recovered = <OcrVisualRegion>{};
          imageCandidates = candidateSelector.recoverCustomerBlocks(
              inspection, customer,
              owned: imageCandidates,
              recovered: recovered,
              hasPinnedImage: evidence.pinnedMedia?['kind'] == 'image');
          viewportFallbackRegions.addAll(recovered);
        }
        if (imageCandidates.isEmpty &&
            allowUnlabeledLatestImage &&
            !extraction.latestIncomingHasText) {
          final fallback = candidateSelector.fallbackLatestCustomerBlock(
              inspection, customer);
          if (fallback != null) {
            imageCandidates = [fallback];
            viewportFallbackRegions.add(fallback);
          }
        }
        var unboundCandidates = evidence != null &&
                evidence.metadata['replyActivationAllowed'] == true &&
                evidence.metadata['historyCutoffMs'] == null
            ? candidateSelector.unboundCandidates(inspection, imageCandidates)
            : <OcrVisualRegion>[];
        final maskRegions = [
          ...imageCandidates,
          ...inspection.unboundMediaRegions,
        ];
        final unboundObservations = <OcrVisualRegion, String>{};
        final unboundParentReceipts = <OcrVisualRegion, String>{};
        for (final region in unboundCandidates) {
          unboundObservations[region] = await _mediaAudit
              .discoverUnbound(evidence!, region, inspection: inspection);
        }
        if (!registerOnly && evidence != null) {
          final unresolved = <OcrVisualRegion>[];
          for (final region in unboundCandidates) {
            final group = await _mediaAudit.groupUnbound(
                evidence, region, unboundObservations[region]!,
                inspection: inspection);
            if (group['mediaReceiptId'] case final String receipt) {
              unboundParentReceipts[region] = receipt;
            }
            if (group['state'] != 'baseline' &&
                group['resolvedMessageId'] == null) {
              unresolved.add(region);
            }
          }
          unboundCandidates = unresolved;
        }
        if (evidence == null &&
            ((latestVisible?.direction == 'outgoing' &&
                    !onlyOurHoldingIsBelow) ||
                extraction.latestIncomingHasText)) {
          imageCandidates = imageCandidates.where((region) {
            final bottom = region.y + region.height;
            final sellerActivityBelow = inspection.observations.any((item) {
              final text = item.text.trim();
              final sellerLabel = (text.contains('旗舰店') &&
                      (text.contains(':') || text.contains('：'))) ||
                  RegExp(r'格志打印机[\u3400-\u9fffA-Za-z0-9_-]{1,12}')
                      .hasMatch(text);
              return sellerLabel && item.y > bottom + .005;
            });
            return !sellerActivityBelow;
          }).toList(growable: false);
        }
        Set<String>? pendingBeforeEarlyCapture;
        Future<void> persistEarlyInputs(List<CapturedMessage> messages) async {
          final owner = evidence;
          if (owner == null || messages.isEmpty) return;
          _checkRun(epoch);
          final activates = owner.metadata['replyActivationAllowed'] == true;
          if (activates && pendingBeforeEarlyCapture == null) {
            pendingBeforeEarlyCapture = {
              for (final message
                  in await _database.processingMessages(customer))
                if (message['direction'] == 'incoming')
                  message['id']! as String,
            };
          }
          var capture = CapturedConversation(
              stableKey: textCapture?.stableKey ??
                  'customer:${sha256.convert(utf8.encode(customer))}',
              customerName: customer,
              customerExternalId: customer,
              capturedAt: inspection.capturedAt,
              automationSessionId: _automationSessionId,
              messages: messages);
          capture = _scopeAcquisitionCapture(owner, capture)!;
          if (capture.messages.isEmpty) return;
          final inserted = await _database.saveCapture(capture,
              isCurrentViewport: owner.metadata['historyCutoffMs'] == null,
              activateReplies: activates,
              activeIncomingIds: _activeIncomingIds(owner, capture));
          if (inserted > 0) _slaPreparedReplies.remove(customer);
          _checkRun(epoch);
          if (messages.any((message) =>
              message.mediaReceiptId != null || message.media.isNotEmpty)) {
            await _mediaInventory.persist(capture,
                verifiedAnchor: true, currentTaskOnly: true);
            _checkRun(epoch);
          }
          if (!activates) return;
          for (final message in await _database.processingMessages(customer)) {
            if (message['direction'] != 'incoming' ||
                pendingBeforeEarlyCapture!.contains(message['id'])) {
              continue;
            }
            manualCoverageExcludedIds?.addAll({
              message['id']! as String,
              ...(message['observed_ids'] as List? ?? const [])
                  .whereType<String>(),
            });
          }
          if (await _database.hasPendingUnanswered(customer)) {
            _scheduleDraftGeneration(customer, newEvidence: inserted > 0);
          }
        }

        // Clear customer prose outside possible media is already actionable.
        // Persist it before crop/cache/frame extraction; text printed inside an
        // unclassified thumbnail must never become an early customer question.
        List<CapturedMessage> earlyText = [];
        if (evidence != null && maskRegions.isNotEmpty) {
          final safeText = const OcrCaptureExtractor()
              .analyze(inspection, excludedMediaRegions: maskRegions)
              .capture;
          textCapture = safeText;
          earlyText = [
            for (final message
                in safeText?.messages ?? const <CapturedMessage>[])
              if (message.direction == 'incoming')
                CapturedMessage(
                    stableId: message.stableId,
                    direction: message.direction,
                    body: message.body,
                    sender: message.sender,
                    sentAt: message.sentAt,
                    axPath: message.axPath,
                    media: message.media,
                    deliveryConfirmed: message.deliveryConfirmed,
                    observationTurnKey: message.observationTurnKey,
                    mediaReceiptId: message.mediaReceiptId,
                    captureEvidenceId: evidence.id),
          ];
        }
        final textClarifications = evidence == null
            ? <String, String>{}
            : await _clarifyUnknownTextInputs(evidence, inspection, textCapture,
                excludedRegions: maskRegions);
        textCapture = _withClarifiedTextIds(textCapture, textClarifications);
        if (textClarifications.isNotEmpty) {
          earlyText = [
            for (final message
                in textCapture?.messages ?? const <CapturedMessage>[])
              if (message.direction == 'incoming' && message.media.isEmpty)
                message,
          ];
        }
        // A frame queued while Start's baseline OCR was failing has no boundary
        // yet. Once that reservation recovers, bootstrap only from that baseline;
        // a later live frame must never advance this older frame's own frontier.
        final admissionFrontier = evidence == null
            ? null
            : evidence.metadata.containsKey('admissionFrontier')
                ? evidence.metadata['admissionFrontier'] as Map? ??
                    await _mediaConversationFrontier(customer,
                        baselineOnly: true)
                : await _mediaConversationFrontier(customer);
        Future<ViewportEvidence?> authorizeText(
            [Map<OcrVisualRegion, String> knownMediaParents = const {},
            Map<OcrVisualRegion, String> dependencyReceipts = const {}]) async {
          final owner = evidence;
          if (owner == null || _automationSessionId == null) return owner;
          final textIds = await _authorizeTextObservation(
              owner, inspection, textCapture, admissionFrontier,
              knownMediaParents: knownMediaParents,
              dependencyReceipts: dependencyReceipts);
          liveTextInputIds?.addAll(textIds);
          return ViewportEvidence({
            ...owner.metadata,
            'liveTextInputIds': textIds.toList(),
          });
        }

        if (imageCandidates.isEmpty && unboundCandidates.isEmpty) {
          evidence = await authorizeText();
        }
        if (!extraction.latestVisibleSenderIsIncoming &&
            !onlyOurHoldingIsBelow &&
            !(allowUnlabeledLatestImage && textCapture == null) &&
            imageCandidates.isEmpty &&
            unboundCandidates.isEmpty &&
            evidence == null) {
          _visibleMediaTrace =
              'strict routing: newest visible sender is not the customer';
          return textCapture;
        }
        final capturedMedia = <CapturedMessage>[];
        // Only full detector rectangles may supply pixels for cache matching.
        // Sender-block proposals can register the obligation; without complete
        // card pixels, the acquisition worker revisits the sender timestamp.
        final receipts = <OcrVisualRegion, String>{};
        final parents = <OcrVisualRegion, MediaParent>{};
        final cardClocks = <OcrVisualRegion, OcrMediaClockEvidence>{
          for (final region in imageCandidates)
            region: const OcrCaptureExtractor()
                .mediaClockForRegion(inspection, region)
        };
        final cardSlots = <String, int>{};
        for (final region in imageCandidates) {
          final clockEvidence = cardClocks[region]!;
          final clock = clockEvidence.sentAt;
          RuntimeTrace.record('media.card_clock_bound', {
            'customer': customer,
            'evidenceId': evidence?.id,
            'senderAt': clock?.toUtc().toIso8601String(),
            'source': clockEvidence.source,
            'confidence': clockEvidence.confidence,
            'headerTop': clockEvidence.headerTop,
            'headerBottom': clockEvidence.headerBottom,
            'region': [region.x, region.y, region.width, region.height],
            'senderClockEstimated': true,
            'chatLatestClockUsed': false
          });
          final slotKey = clock?.toUtc().toIso8601String() ?? 'unclocked';
          final slot =
              cardSlots.update(slotKey, (n) => n + 1, ifAbsent: () => 0);
          if (evidence == null) {
            receipts[region] = await _mediaInventory.observe(
                customer: customer,
                evidenceId: 'live:${inspection.capturedAt.toIso8601String()}',
                observedAt: inspection.capturedAt,
                senderAt: clock,
                slot: slot,
                region: [region.x, region.y, region.width, region.height],
                current: true);
            final parent = await _mediaInventory.resolveParent(customer,
                receiptId: receipts[region]!, requireCurrentSession: true);
            if (parent != null) {
              parents[region] = parent;
              receipts[region] = parent.receiptId;
            }
          }
        }
        final unknownBodyRegions = <OcrVisualRegion>[];
        final registrationFrame = evidence;
        if (registrationFrame != null) {
          // Only message ownership is serialized. Cache access, video decoding,
          // audio analysis and reply generation remain outside this operation.
          Future<void> registerCards(List<OcrVisualRegion> cards,
              {Iterable<OcrVisualRegion> unknownBodies = const []}) async {
            final registered = await _mediaRegistrar.register(
                evidence: registrationFrame,
                inspection: inspection,
                cards: cards,
                unknownBodyRegions: unknownBodies,
                visibleText: textCapture?.messages ?? const [],
                frontier: admissionFrontier,
                registerOnly: registerOnly,
                checkCurrent: () => _checkRun(epoch));
            _checkRun(epoch);
            receipts.addAll(registered.receipts);
            parents.addAll(registered.parents);
            cardClocks.addAll(registered.clocks);
            await _evidenceStore
                .resumeAdmittedMediaEvidence(registered.originEvidenceIds);
            _checkRun(epoch);
            for (final admission in registered.createdAdmissions) {
              manualCoverageExcludedIds?.add(admission.messageId);
              await _evidenceStore.wakeMediaForProgress(customer,
                  progressKey: 'admission:${admission.messageId}',
                  ownerKeys: {admission.messageId, admission.receiptId});
            }
          }

          await registerCards(imageCandidates);
          final session = _automationSessionId;
          final startedAt = _automationSessionStartedAt;
          if (registerOnly && session != null && startedAt != null) {
            final missing = UnknownIncomingBlocks.locate(
                evidence: registrationFrame,
                inspection: inspection,
                messages: textCapture?.messages ?? const [],
                sessionId: session,
                sessionStartedAt: startedAt,
                mediaRegions: [...imageCandidates, ...unboundCandidates],
                knownMediaParents: {
                  for (final entry in parents.entries)
                    entry.key: entry.value.messageId,
                },
                frontier: admissionFrontier);
            unknownBodyRegions.addAll(missing.map((block) => block.region));
            if (unknownBodyRegions.isNotEmpty) {
              // Keep known physical frontier cards in the ownership proof, but
              // never send these untyped body regions to image/video capture.
              await registerCards([...imageCandidates, ...unknownBodyRegions],
                  unknownBodies: unknownBodyRegions);
            }
          }
        }
        final historicalRegions = <OcrVisualRegion>{};
        for (final region in imageCandidates) {
          if (await _database.isSessionBaselineMessage(
              customer, 'media-pending:${receipts[region]}')) {
            historicalRegions.add(region);
          }
        }
        imageCandidates = imageCandidates
            .where((region) => !historicalRegions.contains(region))
            .toList(growable: false);
        if (evidence?.metadata['acquisitionOnly'] == true) {
          final allowed = _acquisitionInputKeys(evidence!);
          final pendingClocks = {
            for (final item
                in await _mediaInventory.pendingMediaForTask(customer))
              if (item['senderAt'] is DateTime) item['senderAt']! as DateTime,
          };
          final scoped = <OcrVisualRegion>[];
          for (final region in imageCandidates) {
            final receipt = receipts[region]!;
            final canonical = await _mediaInventory.canonicalMessageId(receipt,
                customer: customer);
            // A sender clock may locate which frozen rectangle to inspect for
            // an already assigned acquisition. It never assigns that rectangle
            // a business parent; native pixels/explicit ancestry must do that.
            if (allowed.contains(receipt) ||
                allowed.contains(canonical) ||
                (!parents.containsKey(region) &&
                    pendingClocks.contains(cardClocks[region]?.sentAt))) {
              scoped.add(region);
            }
          }
          imageCandidates = scoped;
        }
        final claimedMediaOwners =
            (evidence?.metadata['mediaClaimOwners'] as List? ?? const [])
                .whereType<String>()
                .toSet();
        if (claimedMediaOwners.isNotEmpty) {
          final scoped = <OcrVisualRegion>[];
          for (final region in imageCandidates) {
            final owner = parents[region]?.messageId ??
                await _mediaInventory.canonicalMessageId(receipts[region]!,
                    customer: customer);
            if (claimedMediaOwners.contains(owner)) scoped.add(region);
          }
          imageCandidates = scoped;
        }
        imageCandidates = imageCandidates
            .take(evidence == null ? 1 : 24)
            .toList(growable: false);
        if (!registerOnly && evidence != null) {
          final needed = <OcrVisualRegion>[];
          for (final region in imageCandidates) {
            final parent = parents[region];
            if (parent != null) {
              await _mediaAudit.resolveStoredReceipt(
                  customer, parent.receiptId);
            }
            if (!await _mediaAudit.captureResolved(
                await _mediaAudit.discover(evidence, region))) {
              needed.add(region);
            }
          }
          imageCandidates = needed;
        }
        var unboundSlot = cardSlots['unclocked'] ?? 0;
        for (final region in unboundCandidates) {
          cardClocks[region] = const OcrMediaClockEvidence(
              source: 'sender_header_outside_viewport');
          receipts[region] = await _mediaInventory.observe(
              customer: customer,
              evidenceId: evidence!.id,
              observedAt: inspection.capturedAt,
              senderAt: null,
              slot: unboundSlot++,
              region: [region.x, region.y, region.width, region.height],
              current: false,
              parentReceiptId: unboundParentReceipts[region]);
          final parent = await _mediaInventory.resolveParent(customer,
              receiptId: receipts[region]!, requireCurrentSession: true);
          if (parent != null) {
            parents[region] = parent;
            receipts[region] = parent.receiptId;
            await _mediaAudit.bindParent(unboundObservations[region]!,
                receiptId: parent.receiptId, messageId: parent.messageId);
            if (!registerOnly) {
              await _mediaAudit.resolveStoredReceipt(
                  customer, parent.receiptId);
            }
          }
        }
        if (imageCandidates.isNotEmpty || unboundCandidates.isNotEmpty) {
          evidence = await authorizeText({
            for (final entry in parents.entries)
              entry.key: entry.value.messageId,
          }, {
            for (final entry in parents.entries)
              entry.key: entry.value.receiptId,
          });
        }
        if (evidence != null && earlyText.isNotEmpty) {
          // authorizeText already committed each proved text input and its exact
          // media dependencies. This merge remains idempotent during enrichment.
          await persistEarlyInputs(earlyText);
        }
        for (final region in imageCandidates) {
          if (evidence != null) {
            final observation = await _mediaAudit.discover(evidence, region);
            await _mediaAudit.finish(observation, 'discovered', {
              'mediaReceiptId': receipts[region],
              'senderClock':
                  cardClocks[region]?.sentAt?.toUtc().toIso8601String(),
            });
          }
        }
        if (!registerOnly) {
          final unresolved = <OcrVisualRegion>[];
          for (final region in unboundCandidates) {
            if (!await _mediaAudit
                .captureResolved(unboundObservations[region]!)) {
              unresolved.add(region);
            }
          }
          imageCandidates = [...imageCandidates, ...unresolved];
        }
        final retiredImageRegions = <OcrVisualRegion>{};
        for (final region in imageCandidates) {
          final parent = parents[region];
          if (parent != null &&
              !await _database.isIncompleteImageAcquisitionAllowed(
                  customer, parent.messageId)) {
            retiredImageRegions.add(region);
            // Keep its pixels masked as media without acquiring the old image
            // again or admitting text printed inside it as another message.
            if (!maskRegions.contains(region)) maskRegions.add(region);
          }
        }
        imageCandidates = imageCandidates
            .where((region) => !retiredImageRegions.contains(region))
            .toList();
        final pendingMediaRegions = <OcrVisualRegion>{
          for (final region in imageCandidates)
            if ((_automationSessionId == null || parents.containsKey(region)) &&
                !candidateSelector.isTextDense(region, inspection.observations))
              region,
        };
        CapturedMessage pendingMessage(OcrVisualRegion region) {
          final receipt = receipts[region]!;
          return CapturedMessage(
              stableId: parents[region]?.messageId ?? 'media-pending:$receipt',
              direction: 'incoming',
              body: '[Customer sent media; acquisition pending.]',
              sender: customer,
              sentAt: cardClocks[region]?.sentAt,
              axPath: 'media-receipt:$receipt',
              mediaReceiptId: receipt,
              captureEvidenceId: evidence?.id);
        }

        if (registerOnly && evidence != null) {
          _startExactTimedMatches(evidence, inspection, epoch,
              registeredCards: {
                for (final region in pendingMediaRegions)
                  if (parents[region]?.isCurrentSession == true &&
                      cardClocks[region]?.sentAt != null)
                    region: cardClocks[region]!.sentAt!,
              });
        }

        for (final region in pendingMediaRegions) {
          final parent = parents[region];
          final at = cardClocks[region]?.sentAt;
          if (parent == null || at == null) continue;
          final exactCard =
              inspection.physicalMediaRegions?.contains(region) == true;
          if (registerOnly || !exactCard) {
            await _requestImageOriginal(customer, parent.receiptId, at,
                initialFrame: evidence);
          }
        }

        if (registerOnly) {
          final messages = [
            ...?textCapture?.messages,
            for (final region in pendingMediaRegions) pendingMessage(region),
            for (final region in unknownBodyRegions)
              if (parents.containsKey(region)) pendingMessage(region),
          ];
          if (messages.isEmpty) return textCapture;
          return CapturedConversation(
              stableKey: textCapture?.stableKey ??
                  'customer:${sha256.convert(utf8.encode(customer))}',
              customerName: customer,
              customerExternalId: customer,
              capturedAt: inspection.capturedAt,
              messages: messages);
        }

        final relocalizationRegions = imageCandidates
            .where((region) =>
                region.confidence <= 0 ||
                viewportFallbackRegions
                    .any((item) => identical(item, region)) ||
                (inspection.physicalMediaRegions != null &&
                    (!inspection.physicalMediaRegions!.contains(region) ||
                        cardClocks[region]?.source !=
                            'ocr_media_sender_header')))
            .toSet();
        for (final region in relocalizationRegions) {
          // These coordinates identify a sender-owned message for registration
          // and OCR masking only. They are never a thumbnail crop or click box.
          final parent = parents[region];
          final at = cardClocks[region]?.sentAt;
          if (parent == null || at == null) continue;
          await persistEarlyInputs([pendingMessage(region)]);
          await _requestImageOriginal(customer, parent.receiptId, at);
        }
        imageCandidates = imageCandidates
            .where((region) => !relocalizationRegions.contains(region))
            .toList();

        Future<void> persistClassifiedReceipt(
            OcrVisualRegion region, VisibleImagePayload visible) async {
          if (_automationSessionId != null && !parents.containsKey(region)) {
            return;
          }
          if (visible.kind == 'video' ||
              (visible.kind == 'image' &&
                  candidateSelector.shouldSaveImage(
                      region, inspection.observations,
                      fromVerifiedCache:
                          visible.captureSource == 'jd-image-cache')) ||
              (visible.kind == 'unverified' &&
                  !candidateSelector.isTextDense(
                      region, inspection.observations))) {
            await persistEarlyInputs([pendingMessage(region)]);
            final at = cardClocks[region]?.sentAt;
            final receipt = receipts[region];
            if (visible.kind == 'image' &&
                visible.bytes?.isNotEmpty == true &&
                visible.captureSource != 'jd-image-cache' &&
                !visible.playbackOverlayDetected &&
                visible.video == null &&
                at != null &&
                receipt != null) {
              await _requestImageOriginal(customer, receipt, at,
                  initialFrame: evidence, confirmedImage: true);
            }
          }
        }

        // Classify the frozen card before a pinned image is admitted as an image
        // turn: JD often caches a video's cover before its verified original.
        final preclassified = <OcrVisualRegion, VisibleImagePayload>{};
        final currentFrame = evidence;
        if (currentFrame != null &&
            currentFrame.pinnedMedia == null &&
            imageCandidates.length == 1) {
          final receipt = receipts[imageCandidates.single];
          if (receipt != null) {
            final inherited = await _mediaAudit.inheritedImagePin(currentFrame,
                receiptId: receipt);
            _checkRun(epoch);
            if (inherited != null) {
              // A loading frame may own the cache copy before its pixels finish
              // rendering. Only a proved representation of that exact admitted
              // bubble can reuse its source. The image/video verdict below still
              // guards consumption of the pin.
              evidence = currentFrame.withPinnedMedia(inherited);
              await _evidenceStore.pin(evidence);
              _checkRun(epoch);
            }
          }
        }
        if (evidence != null &&
            evidence.pinnedMedia != null &&
            imageCandidates.length == 1 &&
            !unboundObservations.containsKey(imageCandidates.single)) {
          final region = imageCandidates.single;
          final classificationElapsed = Stopwatch()..start();
          try {
            var visible = await _matchOriginalFrame(
                evidence, region, cardClocks[region]?.sentAt);
            _checkRun(epoch);
            visible = await _verifyFrameMatchedVideoOwner(customer, visible);
            preclassified[region] = visible;
            RuntimeTrace.record('media.cover_classified', {
              'customer': customer,
              'evidenceId': evidence.id,
              'kind': visible.kind,
              'elapsedMs': classificationElapsed.elapsedMilliseconds,
              'verifiedOriginalVideo': visible.video != null
            });
            receipts[region] = await _classifyMediaCard(
                customer, receipts[region]!, visible, region,
                evidenceId: evidence.id);
            final observation = await _mediaAudit.discover(evidence, region);
            await _mediaAudit.finish(observation, 'discovered', {
              'mediaReceiptId': receipts[region],
              'senderClock':
                  cardClocks[region]?.sentAt?.toUtc().toIso8601String(),
            });
            await persistClassifiedReceipt(region, visible);
          } catch (error) {
            RuntimeTrace.record('media.cover_classification_failed', {
              'customer': customer,
              'evidenceId': evidence.id,
              'error': error.runtimeType.toString()
            });
          }
        }
        var failures = 0;
        var directMediaHandled = false;
        final inspectedMediaSources = <String>[];
        final confirmedMediaRegions = <OcrVisualRegion>[...maskRegions];
        if ((imageCandidates.isNotEmpty ||
                (claimedMediaOwners.isEmpty && retiredImageRegions.isEmpty)) &&
            unboundObservations.isEmpty &&
            inspection.physicalMediaRegions == null &&
            !(evidence?.pinnedMedia?['kind'] == 'image' &&
                imageCandidates.length == 1 &&
                preclassified[imageCandidates.single]?.kind != 'image') &&
            !preclassified.values
                .any((v) => v.kind == 'video' && v.video != null) &&
            (!preclassified.values.any((v) => v.kind == 'video') ||
                evidence?.pinnedMedia?['kind'] == 'video') &&
            (!extraction.latestIncomingHasText ||
                imageCandidates.isNotEmpty ||
                evidence?.pinnedMedia?['kind'] == 'video') &&
            (_unreadRecovery[customer] != null ||
                evidence?.pinnedMedia != null) &&
            imageCandidates.length <= 1) {
          final recovery = _unreadRecovery[customer];
          try {
            final cached = await _captureDirectCachedMedia(
              customer,
              recovery,
              allowImageCache: imageCandidates.isNotEmpty,
              runVideoProcessingUnlocked: runVideoProcessingUnlocked,
              pinnedMedia: evidence == null
                  ? null
                  : await _pinnedEvidenceMedia(evidence),
              allowLiveCache: evidence == null,
              messageAt: imageCandidates.isNotEmpty
                  ? cardClocks[imageCandidates.first]?.sentAt
                  : null,
              mediaReceiptId: imageCandidates.isNotEmpty
                  ? receipts[imageCandidates.first]
                  : null,
              observedAt: inspection.capturedAt,
            ).timeout(_captureOperationTimeout);
            if (cached != null) {
              directMediaHandled = cached.handled;
              if (cached.message == null && cached.handled) {
                for (final region in imageCandidates) {
                  if (receipts[region] case final receipt?) {
                    await _mediaAudit.resolveStoredReceipt(customer, receipt);
                  }
                }
              }
              if (cached.message != null) {
                final receipt = imageCandidates.isNotEmpty
                    ? receipts[imageCandidates.first]
                    : evidence == null
                        ? null
                        : await _mediaInventory.uniqueObservedReceipt(
                            customer: customer,
                            evidenceId: evidence.id,
                            senderAt: cached.message!.sentAt,
                            nativePinnedOwner: evidence.pinnedMedia != null);
                capturedMedia.add(cached.message!.withMediaReceipt(receipt));
              }
              inspectedMediaSources.add('direct-jd-cache');
              if (imageCandidates.isNotEmpty) {
                confirmedMediaRegions.add(imageCandidates.first);
              }
              RuntimeTrace.record('media.original_selected', {
                'customer': customer,
                'evidenceId': evidence?.id,
                'messageId': cached.message?.stableId,
                'kind': cached.kind,
                'alreadyStored': cached.message == null,
                'binding': 'unique_cache_customer_turn_and_owned_region'
              });
            }
          } on PlatformException {
            failures++;
          } on TimeoutException {
            failures++;
            RuntimeTrace.record('media.direct_cache_failed', {
              'customer': customer,
              'evidenceId': evidence?.id,
              'stage': 'pinned_original',
              'errorCode': 'timeout'
            });
          } catch (error) {
            failures++;
            RuntimeTrace.record('media.direct_cache_failed', {
              'customer': customer,
              'evidenceId': evidence?.id,
              'stage': 'pinned_original',
              'errorCode': error.runtimeType.toString()
            });
          }
        }
        final remainingRegions = !directMediaHandled && capturedMedia.isEmpty
            ? imageCandidates
            : const <OcrVisualRegion>[];
        final frozenFrame = evidence;
        // Start distinct pixel matches concurrently. Commit their results in
        // stable order so asynchronous matching cannot change message identity.
        final frameMatches = <OcrVisualRegion,
            Future<(VisibleImagePayload?, Object?, StackTrace?)>>{};
        if (frozenFrame != null) {
          for (final region in remainingRegions) {
            if (preclassified.containsKey(region)) continue;
            frameMatches[region] = (() async {
              try {
                return (
                  await _matchOriginalFrame(
                      frozenFrame, region, cardClocks[region]?.sentAt),
                  null,
                  null
                );
              } catch (error, stack) {
                return (null, error, stack);
              }
            })();
          }
        }
        Future<VisibleImagePayload> matched(OcrVisualRegion region) async {
          final (result, error, stack) = await frameMatches[region]!;
          if (error != null) Error.throwWithStackTrace(error, stack!);
          return result!;
        }

        for (final region in remainingRegions) {
          _checkRun(epoch);
          final unbound = unboundObservations.containsKey(region);
          final observationId = unboundObservations[region] ??
              (evidence == null
                  ? null
                  : await _mediaAudit.discover(evidence, region));
          final mediaElapsed = Stopwatch()..start();
          var auditState = 'unverified';
          final auditDetails = <String, Object?>{};
          try {
            final messageAt = cardClocks[region]?.sentAt;
            final expectedMediaAt = messageAt ?? inspection.capturedAt;
            var visible = preclassified[region] ??
                (evidence != null
                    ? await matched(region)
                    : await _adapter
                        .captureImageRegion(
                          expectedCustomer: customer,
                          windowId: inspection.windowId,
                          x: region.x,
                          y: region.y,
                          width: region.width,
                          height: region.height,
                          expectedMediaAt: expectedMediaAt,
                          allowActivationForVideoDetection:
                              allowVideoDetectionActivation,
                        )
                        .timeout(_unreadOperationTimeout));
            _checkRun(epoch);
            visible = await _verifyFrameMatchedVideoOwner(customer, visible);
            if (unbound &&
                (visible.video == null ||
                    visible.reason !=
                        'pixel_matched_same_chat_video_companion')) {
              auditState = 'unbound';
              auditDetails.addAll({
                'attributionPending': true,
                'reason': 'awaiting_pixel_matched_same_chat_video_companion',
              });
              pendingMediaRegions.remove(region);
              continue;
            }
            if (receipts[region] != null &&
                !preclassified.containsKey(region)) {
              receipts[region] = await _classifyMediaCard(
                  customer, receipts[region]!, visible, region,
                  evidenceId: evidence?.id);
            }
            if (receipts[region] case final String receipt) {
              final parent = await _mediaInventory.resolveParent(customer,
                  receiptId: receipt, requireCurrentSession: true);
              if (parent != null) {
                parents[region] = parent;
                receipts[region] = parent.receiptId;
                if (observationId != null) {
                  await _mediaAudit.bindParent(observationId,
                      receiptId: parent.receiptId, messageId: parent.messageId);
                }
              }
            }
            if (await _database.isSessionBaselineMessage(
                customer, 'media-pending:${receipts[region]}')) {
              auditState = 'reused';
              auditDetails['reason'] =
                  'start_baseline_media_preserved_as_history';
              pendingMediaRegions.remove(region);
              continue;
            }
            await persistClassifiedReceipt(region, visible);
            inspectedMediaSources.add(visible.captureSource ?? visible.kind);
            auditDetails.addAll({
              'mediaReceiptId': receipts[region],
              'kind': visible.kind,
              'source': visible.captureSource,
              'reason': visible.reason,
              'foregroundFraction': visible.foregroundFraction,
              'fingerprint': visible.visualFingerprint,
              'senderClock': messageAt?.toUtc().toIso8601String(),
              'senderClockSource': cardClocks[region]?.source,
              'playbackOverlayDetected': visible.playbackOverlayDetected,
              if (visible.video != null)
                'verifiedOriginalPath': visible.video!.path,
            });
            RuntimeTrace.record('media.classified', {
              'customer': customer,
              'kind': visible.kind,
              'source': visible.captureSource,
              'evidenceId': evidence?.id,
              'observationId': observationId,
              'reason': visible.reason,
              'foregroundFraction': visible.foregroundFraction,
            });
            if (visible.kind == 'unverified' &&
                !candidateSelector.isTextDense(
                    region, inspection.observations)) {
              confirmedMediaRegions.add(region);
              auditDetails['pendingVisualTask'] = true;
            }
            var turnAt = messageAt;
            // The sender label can sit above OCR's text band while the media
            // thumbnail is still clearly visible. Start the 20-second recovery
            // clock before a video cache copy or frame extraction can stall.
            if (!extraction.latestVisibleSenderIsIncoming &&
                evidence?.metadata['acquisitionOnly'] != true &&
                (visible.kind == 'video' ||
                    (visible.kind == 'image' &&
                        visible.bytes != null &&
                        !candidateSelector.isTextDense(
                            region, inspection.observations))) &&
                visible.visualFingerprint?.isNotEmpty == true &&
                !_unreadRecovery.containsKey(customer) &&
                !await (await _database.history).hasSimilarImageFingerprint(
                  customer,
                  visible.visualFingerprint!,
                  capturedAfter: turnAt,
                )) {
              await _beginUnreadRecovery(customer, 0,
                  detectedAt: inspection.capturedAt);
              // Recovery time starts the deadline, not the media sender clock.
            }
            if (visible.kind == 'video') {
              pendingMediaRegions.add(region);
              // Classification itself is enough to reject OCR text inside the
              // thumbnail, even if the cache copy must be retried later.
              confirmedMediaRegions.add(region);
              final saved = visible.video != null
                  ? await _processDownloadedVideo(
                      customer, visible.video!, visible.visualFingerprint ?? '',
                      cover: await _saveVideoCover(customer, visible),
                      sentAt: turnAt,
                      mediaReceiptId: receipts[region],
                      runVideoProcessingUnlocked: runVideoProcessingUnlocked)
                  : evidence != null
                      ? null
                      : await _saveVisibleVideo(
                          customer,
                          inspection.windowId,
                          region,
                          visible.visualFingerprint ?? '',
                          sentAt: turnAt,
                          mediaReceiptId: receipts[region],
                          runVideoProcessingUnlocked:
                              runVideoProcessingUnlocked,
                        );
              if (saved != null) {
                capturedMedia.add(saved.withMediaReceipt(receipts[region]));
                auditState = 'video_frames_saved';
                auditDetails['attributionPending'] = false;
                auditDetails['resolvedMessageId'] = saved.stableId;
                auditDetails['frameCount'] =
                    saved.media.where((m) => m.type == 'image').length;
              } else if (visible.bytes != null) {
                auditState = 'video_preview_only';
                // Keep the pixels while either acquisition or exact business
                // ownership remains unfinished. A saved original is not proof
                // that its full analysis or formal reply has completed.
                final preview = await _saveVisibleImage(customer, visible,
                    sentAt: turnAt,
                    videoPreview: true,
                    evidenceId: evidence?.id,
                    observationId: observationId,
                    mediaReceiptId: receipts[region]);
                if (preview != null) {
                  capturedMedia.add(preview.withMediaReceipt(receipts[region]));
                }
                RuntimeTrace.record('media.preview_saved', {
                  'customer': customer,
                  'saved': preview != null,
                  'reason': visible.video == null
                      ? 'video_unverified'
                      : 'verified_original_waiting_for_message_processing',
                  'evidenceId': evidence?.id,
                  'observationId': observationId,
                  'originalRetrieved': visible.video != null,
                  'framesExtracted': false,
                });
              }
            } else if (visible.kind == 'image' && visible.bytes != null) {
              // A rectangle around a long ordinary text bubble can look like an
              // image to Vision. A screenshot matched pixel-for-pixel to an
              // original in JD's image cache is already verified media, however,
              // and must not be discarded merely because the image itself contains
              // a lot of readable text.
              final cacheOriginal = visible.captureSource == 'jd-image-cache';
              final viewport = evidence?.metadata['chatRegion'] as Map?;
              final clipped = !cacheOriginal &&
                  EvidenceCoverage.mediaTouchesViewport(
                      top: region.y,
                      bottom: region.y + region.height,
                      viewportTop: (viewport?['top'] as num?)?.toDouble(),
                      viewportBottom:
                          (viewport?['bottom'] as num?)?.toDouble());
              auditDetails.addAll({
                'isPartial': !cacheOriginal,
                'touchesViewportEdge': clipped
              });
              if (candidateSelector.shouldSaveImage(
                region,
                inspection.observations,
                fromVerifiedCache: cacheOriginal,
              )) {
                confirmedMediaRegions.add(region);
                final saved = await _saveVisibleImage(
                  customer,
                  visible,
                  sentAt: turnAt,
                  evidenceId: evidence?.id,
                  observationId: observationId,
                  mediaReceiptId: receipts[region],
                  viewportFallback: viewportFallbackRegions
                      .any((item) => identical(item, region)),
                  cacheCopy: cacheOriginal,
                  captureQuality: {
                    'touchesViewportEdge': clipped,
                    'width': (region.width * inspection.imageWidth).round(),
                    'height': (region.height * inspection.imageHeight).round(),
                  },
                );
                if (saved != null) {
                  capturedMedia.add(saved.withMediaReceipt(receipts[region]));
                  auditState = cacheOriginal ? 'image_saved' : 'image_partial';
                  auditDetails['contentSha256'] =
                      sha256.convert(visible.bytes!).toString();
                } else {
                  final receipt = receipts[region];
                  final parent = receipt == null
                      ? null
                      : await _mediaInventory.resolveParent(customer,
                          receiptId: receipt, requireCurrentSession: true);
                  _checkRun(epoch);
                  if (_automationSessionId != null && parent == null) {
                    final passiveHistorical = evidence != null &&
                        evidence.metadata['replyActivationAllowed'] == false &&
                        evidence.metadata['acquisitionOnly'] != true;
                    final liveProof = passiveHistorical && observationId != null
                        ? await _mediaAudit.liveArrivalProofFor(observationId)
                        : null;
                    _checkRun(epoch);
                    final historicalOnly =
                        passiveHistorical && liveProof == null;
                    auditState = historicalOnly ? 'baseline' : 'unverified';
                    auditDetails['reason'] = historicalOnly
                        ? 'historical_observation_without_current_parent'
                        : 'media_parent_not_admitted';
                    auditDetails['pendingVisualTask'] = !historicalOnly;
                  } else {
                    auditState = clipped ? 'image_partial' : 'reused';
                    auditDetails['reason'] =
                        'matching_media_already_in_history';
                  }
                }
              } else {
                auditState = 'rejected_text';
                auditDetails['reason'] = 'text_dense_region';
              }
            } else {
              auditDetails['reason'] ??= 'unsupported_or_unverified_candidate';
            }
          } on PlatformException catch (error) {
            auditState = 'failed';
            auditDetails['errorCode'] = error.code;
            failures++;
            final recovery = _unreadRecovery[customer];
            if (const {
              'image_crop_precondition_failed',
              'image_crop_verification_failed',
              'image_crop_window_failed'
            }.contains(error.code)) {
              final scheduled = recovery?.requestMediaRecapture() ?? false;
              RuntimeTrace.record('media.capture_failed', {
                'customer': customer,
                'errorCode': error.code,
                'freshRecaptureScheduled': scheduled,
                'attempt': recovery?.mediaRecaptureAttempts,
              });
            }
            // One invalid visual rectangle must not discard other candidates or
            // text already extracted from the visible conversation.
          } on TimeoutException {
            auditState = 'failed';
            auditDetails['errorCode'] = 'media_operation_timeout';
            failures++;
            // A stalled native media operation cannot hold the JD UI queue past
            // the customer's fallback deadline.
          } catch (error) {
            auditState = 'failed';
            auditDetails['errorCode'] = error.runtimeType.toString();
            failures++;
          } finally {
            if (unbound &&
                auditState != 'video_frames_saved' &&
                auditState != 'reused') {
              auditState = 'unbound';
              pendingMediaRegions.remove(region);
            }
            if (auditState == 'rejected_text' && receipts[region] != null) {
              pendingMediaRegions.remove(region);
              await _mediaInventory.rejectCandidate(receipts[region]!);
            }
            if (observationId != null) {
              await _mediaAudit.finish(observationId, auditState, {
                ...auditDetails,
                'elapsedMs': mediaElapsed.elapsedMilliseconds
              });
            }
          }
        }
        RuntimeTrace.record('media.scan', {
          'customer': customer,
          'evidenceId': evidence?.id,
          'candidateCountSource': 'local_visual_regions_not_platform_messages',
          'candidates': imageCandidates.length,
          'captured': capturedMedia.length,
          'failures': failures,
          'latestIncomingHasText': extraction.latestIncomingHasText,
        });
        _visibleMediaTrace =
            'strict routing: image -> verified cache original or screenshot, video -> cache + 1fps frames; candidates='
            '${imageCandidates.length}, captured=${capturedMedia.length}, '
            'failures=$failures, sources=${inspectedMediaSources.join(',')}; '
            'JD image viewer was not opened';
        confirmedMediaRegions.addAll(pendingMediaRegions
            .where((region) => !confirmedMediaRegions.contains(region)));
        if (confirmedMediaRegions.isNotEmpty) {
          // Re-read text with the verified media rectangles masked. Otherwise OCR
          // of a play icon or text displayed *inside* a video can close unread
          // recovery and generate a reply to a fabricated customer sentence.
          textCapture = const OcrCaptureExtractor()
              .analyze(inspection, excludedMediaRegions: confirmedMediaRegions)
              .capture;
          textCapture = _withClarifiedTextIds(textCapture, textClarifications);
        }
        // A visible owned card is already a received customer input. Unknown
        // pixels, a failed cache lookup or missing original cannot make it vanish
        // from the unanswered queue. Its receipt upgrades this same input later.
        final fulfilledReceipts = capturedMedia
            .map((message) => message.mediaReceiptId)
            .whereType<String>()
            .toSet();
        for (final region in pendingMediaRegions) {
          if (_automationSessionId != null && !parents.containsKey(region)) {
            continue;
          }
          final receipt = receipts[region];
          if (receipt == null || fulfilledReceipts.contains(receipt)) continue;
          capturedMedia.add(pendingMessage(region));
        }
        if (capturedMedia.isEmpty &&
            directMediaHandled &&
            textCapture == null) {
          return CapturedConversation(
              stableKey: 'customer:${sha256.convert(utf8.encode(customer))}',
              customerName: customer,
              customerExternalId: customer,
              messages: const [],
              capturedAt: inspection.capturedAt);
        }
        if (capturedMedia.isEmpty) return textCapture;
        final uniqueMedia = <String, CapturedMessage>{
          for (final message in capturedMedia) message.stableId: message,
        }.values.toList(growable: false);
        return CapturedConversation(
          stableKey: textCapture?.stableKey ??
              'customer:${sha256.convert(utf8.encode(customer))}',
          customerName: customer,
          customerExternalId: customer,
          capturedAt: inspection.capturedAt,
          messages: [...?textCapture?.messages, ...uniqueMedia]..sort((a, b) =>
              (a.sentAt ?? inspection.capturedAt)
                  .compareTo(b.sentAt ?? inspection.capturedAt)),
        );
      } finally {
        if (epoch == _runEpoch) {
          final remaining = (_visualMediaCaptures[customer] ?? 1) - 1;
          if (remaining <= 0) {
            _visualMediaCaptures.remove(customer);
          } else {
            _visualMediaCaptures[customer] = remaining;
          }
        }
      }
    } finally {
      releaseDiagnosticWork();
    }
  }

  Future<({CapturedMessage? message, bool handled, String kind})?>
      _captureDirectCachedMedia(
    String customer,
    UnreadCaptureRecovery? recovery, {
    _RunVideoProcessingUnlocked? runVideoProcessingUnlocked,
    CachedMediaPayload? pinnedMedia,
    bool allowLiveCache = true,
    bool allowImageCache = false,
    DateTime? messageAt,
    DateTime? observedAt,
    String? mediaReceiptId,
  }) async {
    if (pinnedMedia == null && (!allowLiveCache || recovery == null)) {
      return null;
    }
    final store = await _database.history;
    final videoDestination = Directory(
      '${store.mediaDirectory.path}/${store.safeUserId(customer)}/videos',
    );
    await videoDestination.create(recursive: true);
    final cached = pinnedMedia ??
        await _adapter.captureRecentCachedMedia(
          expectedCustomer: customer,
          expectedMediaAt: recovery!.detectedAt,
          destinationDirectory: videoDestination.path,
        );
    if (cached == null) return null;
    if (cached.image != null && !allowImageCache) {
      // An image candidate without validated card pixels never supplies
      // original-image evidence.
      return null;
    }
    if (pinnedMedia == null &&
        !_claimDirectCachedMedia(customer, recovery!, cached)) {
      if (pinnedMedia == null) await _deleteRejectedCachedVideo(cached.video);
      return null;
    }
    if (cached.image case final image?) {
      RuntimeTrace.record('media.cached_verified', {
        'customer': customer,
        'kind': 'image',
        'cacheModifiedAt': cached.cacheModifiedAt.toUtc().toIso8601String(),
      });
      final message = await _saveVisibleImage(
        customer,
        image,
        sentAt: messageAt,
        cacheCopy: true,
        mediaReceiptId: mediaReceiptId,
      );
      return (message: message, handled: true, kind: 'image');
    }
    if (cached.video case final video?) {
      // An unanchored cache reread does not prove another sent card. A real
      // observed card always has its own receipt, including unclocked resends.
      if (mediaReceiptId == null &&
          cached.cacheKey.isNotEmpty &&
          await store.hasSimilarImageFingerprint(customer, cached.cacheKey,
              maximumDistance: 0,
              captureSources: const {'jd_video_cache'},
              capturedAfter: messageAt)) {
        final document = await store.read(customer);
        final retained = (document?['messages'] as List? ?? const [])
            .whereType<Map>()
            .any((m) => (m['media'] as List? ?? const [])
                .whereType<Map>()
                .any((a) => a['path'] == video.path));
        if (pinnedMedia == null && !retained) {
          await _deleteRejectedCachedVideo(video);
        }
        RuntimeTrace.record('media.unanchored_cache_reused', {
          'customer': customer,
          'cacheKey': cached.cacheKey,
          'newCardClaimed': false,
          'existingOriginalPreserved': true
        });
        return (message: null, handled: true, kind: 'video');
      }
      if (cached.cacheKey.isEmpty) {
        if (pinnedMedia == null) await _deleteRejectedCachedVideo(video);
        return (message: null, handled: true, kind: 'video');
      }
      final message = await _processDownloadedVideo(
        customer,
        video,
        cached.cacheKey,
        sentAt: messageAt,
        mediaReceiptId: mediaReceiptId,
        runVideoProcessingUnlocked: runVideoProcessingUnlocked,
      );
      return (message: message, handled: true, kind: 'video');
    }
    return null;
  }

  bool _claimDirectCachedMedia(
    String customer,
    UnreadCaptureRecovery recovery,
    CachedMediaPayload cached, {
    Map<String, UnreadCaptureRecovery> additionalRecoveries = const {},
  }) {
    bool reject(String reason) {
      RuntimeTrace.record('media.cache_claim_rejected', {
        'customer': customer,
        'reason': reason,
        'kind': cached.kind,
        'cacheKey': cached.cacheKey,
        'cacheModifiedAt': cached.cacheModifiedAt.toUtc().toIso8601String(),
        'detectedAt': recovery.detectedAt.toUtc().toIso8601String(),
        'originalOwnershipVerified': false,
        'existingOwner': _claimedJdCacheMediaOwners[cached.cacheKey],
        'candidateClockDeltasMs': {
          for (final entry in {
            ...additionalRecoveries,
            ..._mediaAcquisition,
            ..._unreadRecovery,
            customer: recovery
          }.entries)
            entry.key: cached.cacheModifiedAt
                .difference(entry.value.detectedAt)
                .inMilliseconds
                .abs(),
        },
      });
      return false;
    }

    if (cached.cacheKey.isEmpty ||
        cached.cacheModifiedAt.millisecondsSinceEpoch == 0) {
      return reject('cache_identity_missing');
    }
    if (!UnreadCaptureRecovery.cacheClockUniquelyMatches(
      modifiedAt: cached.cacheModifiedAt,
      targetCustomer: customer,
      recoveries: {
        ...additionalRecoveries,
        ..._mediaAcquisition,
        ..._unreadRecovery,
        customer: recovery
      },
    )) {
      return reject('customer_clock_ambiguous');
    }
    final existingOwner = _claimedJdCacheMediaOwners[cached.cacheKey];
    if (existingOwner != null && existingOwner != customer) {
      return reject('cache_owned_by_other_customer');
    }
    _claimedJdCacheMediaOwners[cached.cacheKey] = customer;
    return true;
  }

  Future<void> _deleteRejectedCachedVideo(DownloadedVideoPayload? video) async {
    if (video == null || video.path.isEmpty) return;
    final file = File(video.path);
    if (await file.exists()) await file.delete();
  }

  Future<CapturedMessage?> _saveVisibleVideo(
    String customer,
    int windowId,
    OcrVisualRegion region,
    String thumbnailFingerprint, {
    DateTime? sentAt,
    String? mediaReceiptId,
    _RunVideoProcessingUnlocked? runVideoProcessingUnlocked,
  }) async {
    final store = await _database.history;
    if (mediaReceiptId == null &&
        thumbnailFingerprint.isNotEmpty &&
        await store.hasSimilarImageFingerprint(
          customer,
          thumbnailFingerprint,
          captureSources: const {'jd_video_cache', 'jd_video_save_as'},
          capturedAfter: sentAt,
        )) {
      return null;
    }
    final destination = Directory(
      '${store.mediaDirectory.path}/${store.safeUserId(customer)}/videos',
    );
    await destination.create(recursive: true);
    final downloaded = await _adapter
        .downloadVideoAt(
          expectedCustomer: customer,
          windowId: windowId,
          x: region.x,
          y: region.y,
          width: region.width,
          height: region.height,
          destinationDirectory: destination.path,
        )
        .timeout(_unreadOperationTimeout);
    if (downloaded.path.isEmpty) return null;
    return _processDownloadedVideo(
      customer,
      downloaded,
      thumbnailFingerprint,
      sentAt: sentAt,
      mediaReceiptId: mediaReceiptId,
      runVideoProcessingUnlocked: runVideoProcessingUnlocked,
    );
  }

  final Set<String> _videoAudioJobs = {};
  final List<(String, CapturedMedia, String, String?)> _videoAudioQueue = [];
  final Map<String, Timer> _videoAudioRetryTimers = {};
  final Map<String, int> _videoAudioActiveCustomers = {};
  bool _videoAudioWorkerBusy = false;
  int? _videoAudioWorkerEpoch;

  Future<void> _drainVideoAudioQueue() async {
    final releaseDiagnosticWork = _diagnosticWork.acquire();
    try {
      if (_videoAudioWorkerBusy || !_autoCaptureRunning) return;
      _videoAudioWorkerBusy = true;
      final epoch = _runEpoch;
      _videoAudioWorkerEpoch = epoch;
      try {
        while (mounted &&
            _autoCaptureRunning &&
            epoch == _runEpoch &&
            _videoAudioQueue.isNotEmpty) {
          final next = _videoAudioQueue.indexWhere(
              (job) => !_videoAudioActiveCustomers.containsKey(job.$1));
          if (next < 0) break;
          final (customer, video, messageId, receiptId) =
              _videoAudioQueue.removeAt(next);
          _videoAudioActiveCustomers[customer] = epoch;
          unawaited(_enrichVideoAudio(customer, video,
                  messageId: messageId, receiptId: receiptId)
              .whenComplete(() {
            if (_videoAudioActiveCustomers[customer] == epoch) {
              _videoAudioActiveCustomers.remove(customer);
              if (mounted && _autoCaptureRunning && epoch == _runEpoch) {
                unawaited(_drainVideoAudioQueue());
              }
            }
          }));
        }
      } finally {
        if (_videoAudioWorkerEpoch == epoch) {
          _videoAudioWorkerBusy = false;
          _videoAudioWorkerEpoch = null;
        }
      }
    } finally {
      releaseDiagnosticWork();
    }
  }

  void _scheduleVideoAudioEnrichment(CapturedConversation? capture) {
    if (capture == null) return;
    final customer = capture.customerExternalId ?? capture.customerName;
    for (final message in capture.messages) {
      for (final video in message.media.where((m) => m.type == 'video')) {
        final key = '$customer:${message.mediaReceiptId ?? message.stableId}:'
            '${video.path}';
        if (!_videoAudioJobs.add(key)) continue;
        _videoAudioQueue
            .add((customer, video, message.stableId, message.mediaReceiptId));
      }
    }
    unawaited(_drainVideoAudioQueue());
  }

  Future<void> _enrichVideoAudio(String customer, CapturedMedia video,
          {required String messageId, String? receiptId}) =>
      ManagedMediaProcesses.shared.runCurrent(() => _enrichVideoAudioInRun(
          customer, video,
          messageId: messageId, receiptId: receiptId));

  Future<void> _enrichVideoAudioInRun(String customer, CapturedMedia video,
      {required String messageId, String? receiptId}) async {
    final releaseDiagnosticWork = _diagnosticWork.acquire();
    try {
      final epoch = _runEpoch;
      final elapsed = Stopwatch()..start();
      String? digest;
      var terminal = false;
      try {
        digest =
            (await sha256.bind(File(video.path).openRead()).first).toString();
        RuntimeTrace.record('media.audio_enrichment_started', {
          'customer': customer,
          'videoSha256': digest,
          'blocksVisualEvidence': false,
          'blocksDelivery': false,
        });
        final description =
            await _analyzeVideoAudio(customer, video.path, digest);
        terminal = CustomerMediaInventory.hasTerminalVideoAudio([
          {'type': 'video', 'description': description}
        ]);
        if (!_autoCaptureRunning || epoch != _runEpoch) return;
        final updated = await (await _database.history).updateMediaDescriptions(
            customer, {video.path: '${video.description ?? ''}\n$description'});
        if (!_autoCaptureRunning || epoch != _runEpoch) return;
        if (updated > 0 || terminal) {
          final synced = await _mediaInventory.updateProvenVideoDescription(
              customer, video.path, '${video.description ?? ''}\n$description',
              messageId: messageId, receiptId: receiptId);
          if (!_autoCaptureRunning || epoch != _runEpoch) return;
          if (synced > 0) {
            if (await _database.hasPendingUnanswered(customer)) {
              _scheduleDraftGeneration(customer, newEvidence: true);
            }
          }
        }
        RuntimeTrace.record('media.audio_enrichment_completed', {
          'customer': customer,
          'videoSha256': digest,
          'elapsedMs': elapsed.elapsedMilliseconds,
          'updatedMedia': updated,
          'audioTerminal': terminal,
        });
      } catch (error) {
        RuntimeTrace.record('media.audio_enrichment_failed', {
          'customer': customer,
          'videoSha256': digest,
          'elapsedMs': elapsed.elapsedMilliseconds,
          'errorCode': error.runtimeType.toString(),
        });
      } finally {
        if (!terminal && mounted && _autoCaptureRunning && epoch == _runEpoch) {
          final key = '$customer:${receiptId ?? messageId}:${video.path}';
          _videoAudioRetryTimers.putIfAbsent(
              key,
              () => Timer(const Duration(seconds: 30), () async {
                    _videoAudioRetryTimers.remove(key);
                    if (!mounted ||
                        !_autoCaptureRunning ||
                        epoch != _runEpoch ||
                        !await _database.isCurrentSessionMessage(
                            customer, messageId) ||
                        await _database.isMessageFormallyAnswered(
                            customer, messageId)) {
                      return;
                    }
                    _videoAudioQueue
                        .add((customer, video, messageId, receiptId));
                    unawaited(_drainVideoAudioQueue());
                  }));
        }
      }
    } finally {
      releaseDiagnosticWork();
    }
  }

  Future<String> _analyzeVideoAudio(
      String customer, String path, String digest) async {
    final run = ManagedMediaProcesses.shared.captureRun();
    run.throwIfCancelled();
    var audioEvidence = '[Video audio: analysis unavailable]';
    try {
      final audio = await const VideoAudioExtractor().extract(path);
      if (!audio.hasAudioStream) {
        audioEvidence = '[Video audio: no audio stream]';
      } else if (!audio.hasAudibleContent) {
        audioEvidence =
            '[Video audio: an audio stream exists, but no meaningful audible content was detected]';
      } else {
        run.throwIfCancelled();
        final speech = await _adapter
            .transcribeAudio(audio.audioPath!)
            .timeout(const Duration(seconds: 60));
        run.throwIfCancelled();
        final transcript =
            speech.transcript.replaceAll(RegExp(r'\s+'), ' ').trim();
        if (speech.speechDetected && transcript.isNotEmpty) {
          final bounded = transcript.length <= 8000
              ? transcript
              : '${transcript.substring(0, 8000)}…';
          audioEvidence =
              '[Video speech transcript (${speech.language}): $bounded]';
        } else {
          audioEvidence =
              '[Video audio: audible content exists, but no speech was recognized]';
        }
      }
    } on MediaProcessCancelled {
      rethrow;
    } catch (error) {
      RuntimeTrace.record('media.video_audio_failed', {
        'customer': customer,
        'videoSha256': digest,
        'errorCode': error.runtimeType.toString()
      });
      // Retain this exact input for retry. Unavailable recognition is not a
      // successful no-speech terminal and cannot authorize its formal answer.
    }
    return audioEvidence;
  }

  Future<CapturedMedia?> _saveVideoCover(
      String customer, VisibleImagePayload visible) async {
    final bytes = visible.cardPreviewBytes ?? visible.bytes;
    if (bytes == null ||
        bytes.isEmpty ||
        (visible.foregroundFraction ?? 1) <= .01) {
      return null;
    }
    final store = await _database.history;
    final digest = sha256.convert(bytes).toString();
    final png = bytes.length >= 4 && bytes[0] == 137 && bytes[1] == 80;
    final extension = png ? 'png' : 'jpg';
    final path = await store.saveMedia(
        userId: customer,
        bytes: bytes,
        filename: 'video-cover-${digest.substring(0, 20)}.$extension');
    return CapturedMedia(
        type: 'image',
        path: path,
        mimeType: png ? 'image/png' : 'image/jpeg',
        originalName: 'video-cover.$extension',
        captureSource: 'jd_video_cover',
        isPartial: true,
        description: 'Verified visible cover of this same customer video.');
  }

  Future<CapturedMessage?> _processDownloadedVideo(
    String customer,
    DownloadedVideoPayload downloaded,
    String thumbnailFingerprint, {
    CapturedMedia? cover,
    DateTime? sentAt,
    String? mediaReceiptId,
    _RunVideoProcessingUnlocked? runVideoProcessingUnlocked,
  }) =>
      ManagedMediaProcesses.shared.runCurrent(() =>
          _processDownloadedVideoInRun(
              customer, downloaded, thumbnailFingerprint,
              cover: cover,
              sentAt: sentAt,
              mediaReceiptId: mediaReceiptId,
              runVideoProcessingUnlocked: runVideoProcessingUnlocked));

  Future<CapturedMessage?> _processDownloadedVideoInRun(
    String customer,
    DownloadedVideoPayload downloaded,
    String thumbnailFingerprint, {
    CapturedMedia? cover,
    DateTime? sentAt,
    String? mediaReceiptId,
    _RunVideoProcessingUnlocked? runVideoProcessingUnlocked,
  }) async {
    final parent = mediaReceiptId == null
        ? null
        : await _mediaInventory.resolveParent(customer,
            receiptId: mediaReceiptId, requireCurrentSession: true);
    if (_automationSessionId != null && parent == null) return null;
    if (parent != null) mediaReceiptId = parent.receiptId;
    Future<CapturedMessage> processDownloadedVideo() async {
      final videoElapsed = Stopwatch()..start();
      final extracted =
          await const VideoFrameExtractor().extract(downloaded.path);
      RuntimeTrace.record('media.video_frames_extracted', {
        'customer': customer,
        'videoSha256': extracted.sha256Digest,
        'frameCount': extracted.framePaths.length,
        'elapsedMs': videoElapsed.elapsedMilliseconds,
        'analysisComplete': false,
        'visualReady': true,
        'audioPending': true,
      });
      const audioEvidence =
          '[Video audio: analysis pending; formal reply waits for the audio/speech terminal result]';
      final frameMedia = <CapturedMedia>[];
      for (var index = 0; index < extracted.framePaths.length; index++) {
        frameMedia.add(CapturedMedia(
          type: 'image',
          path: extracted.framePaths[index],
          mimeType: 'image/jpeg',
          originalName: index == 0
              ? 'video_frame_00s.jpg'
              : index == extracted.framePaths.length - 1
                  ? 'video_frame_tail.jpg'
                  : 'video_sample_${index.toString().padLeft(2, '0')}.jpg',
          captureSource: 'jd_video_frame_1fps',
          description: index == 0
              ? 'First decoded video frame (t=0); pending Codex visual analysis.'
              : index == extracted.framePaths.length - 1
                  ? 'Final decoded video frame (video end); pending Codex visual analysis.'
                  : 'Pending Codex visual analysis.',
        ));
      }
      return CapturedMessage(
        stableId: _visibleMediaStableId(
            'visible-video', extracted.sha256Digest, sentAt),
        direction: 'incoming',
        body:
            '[Customer sent a video; original copied from JD cache; up to 20 samples cover the full timeline including first and final decoded frames]\n$audioEvidence',
        sender: customer,
        sentAt: sentAt,
        axPath: 'ocr:jd-video-cache',
        media: [
          CapturedMedia(
            type: 'video',
            path: downloaded.path,
            mimeType: downloaded.mimeType,
            originalName: downloaded.originalName,
            captureSource: 'jd_video_cache',
            description:
                'Original customer video; visual evidence is stored in the sampled frame images.',
            visualFingerprint: thumbnailFingerprint,
          ),
          ...frameMedia,
        ],
      );
    }

    final recovery = _unreadRecovery[customer];
    if (recovery != null) recovery.videoProcessing = true;
    try {
      final digest = (await sha256.bind(File(downloaded.path).openRead()).first)
          .toString();
      final turnKey =
          _unreadRecovery[customer]?.detectedAt.toUtc().toIso8601String();
      final identity = parent != null
          ? MediaIdentity(parent.messageId, true)
          : await MediaIdentityResolver(await _database.history).resolve(
              customer: customer,
              kind: 'video',
              digest: digest,
              sentAt: sentAt,
              observedAt: DateTime.now(),
              turnKey: turnKey,
              mediaReceiptId: mediaReceiptId,
              anchoredMessageId: mediaReceiptId == null
                  ? null
                  : await _mediaInventory.canonicalMessageId(mediaReceiptId,
                      customer: customer));
      if (identity.clockRefined && sentAt != null) {
        await _mediaInventory.refineClock(customer, identity.id, sentAt);
      }
      _processedVideos ??= ProcessedVideoStore(
          Directory('${(await _database.storageRoot).path}/processed_videos'));
      Future<CapturedMessage?> obtain() async {
        final artifact = await _processedVideos!.getOrCreate(
            customer, digest, processDownloadedVideo,
            cacheContract: VideoFrameExtractor.samplingContract,
            onReuse: () => RuntimeTrace.record('media.video_processing_reused',
                {'customer': customer, 'videoSha256': digest}));
        CapturedMedia? ownedCover = cover;
        if (ownedCover == null) {
          final document = await (await _database.history).read(customer);
          final known = (document?['messages'] as List? ?? const [])
              .whereType<Map>()
              .where((message) =>
                  message['id'] == identity.id ||
                  (message['observed_ids'] as List? ?? const [])
                      .contains(identity.id) ||
                  (mediaReceiptId != null &&
                      message['media_receipt_id'] == mediaReceiptId))
              .expand((message) =>
                  (message['media'] as List? ?? const []).whereType<Map>())
              .where((media) =>
                  const {
                    'jd_video_cover',
                    'verified_media_preview',
                    'jd_video_preview'
                  }.contains(media['capture_source']) &&
                  media['is_loading_preview'] != true)
              .firstOrNull;
          if (known != null) ownedCover = CapturedMedia.fromMap(known);
        }
        if (ownedCover == null) {
          final first = artifact.media
              .where((media) =>
                  media.captureSource == 'jd_video_frame_1fps' &&
                  media.originalName == 'video_frame_00s.jpg')
              .firstOrNull;
          if (first != null) {
            ownedCover = CapturedMedia(
                type: 'image',
                path: first.path,
                mimeType: first.mimeType,
                captureSource: 'jd_video_cover',
                isPartial: true,
                description:
                    'Video preview reconstructed from its first decoded frame; no separate card cover was retained.');
          }
        }
        return CapturedMessage(
            stableId: identity.id,
            direction: 'incoming',
            body: artifact.body,
            sender: customer,
            sentAt: sentAt,
            axPath: artifact.axPath,
            media: [
              if (ownedCover != null) ownedCover,
              ...artifact.media,
            ],
            mediaReceiptId: mediaReceiptId,
            observationTurnKey: turnKey);
      }

      return runVideoProcessingUnlocked == null
          ? await obtain()
          : await runVideoProcessingUnlocked(obtain);
    } finally {
      if (recovery != null) recovery.videoProcessing = false;
    }
  }

  MediaVisualMatcher? _visualMatcher;

  Future<CapturedMessage?> _saveVisibleImage(
    String customer,
    VisibleImagePayload image, {
    DateTime? sentAt,
    bool viewportFallback = false,
    bool originalDownload = false,
    bool clipboardCopy = false,
    bool cacheCopy = false,
    bool videoPreview = false,
    String? evidenceId,
    String? observationId,
    String? mediaReceiptId,
    Map<String, Object?> captureQuality = const {},
  }) async {
    final parent = mediaReceiptId == null
        ? null
        : await _mediaInventory.resolveParent(customer,
            receiptId: mediaReceiptId, requireCurrentSession: true);
    if (_automationSessionId != null && parent == null) return null;
    if (parent != null) mediaReceiptId = parent.receiptId;
    final bytes = image.bytes!;
    final fingerprint = image.visualFingerprint ?? '';
    final digest = sha256.convert(bytes).toString();
    final recovery = _unreadRecovery[customer];
    final turnKey = recovery?.detectedAt.toUtc().toIso8601String();
    final identity = parent != null
        ? MediaIdentity(parent.messageId, true)
        : await MediaIdentityResolver(await _database.history).resolve(
            customer: customer,
            kind: 'image',
            digest: digest,
            sentAt: sentAt,
            observedAt: DateTime.now(),
            turnKey: turnKey,
            mediaReceiptId: mediaReceiptId,
            anchoredMessageId: mediaReceiptId == null
                ? null
                : await _mediaInventory.canonicalMessageId(mediaReceiptId,
                    customer: customer));
    if (identity.clockRefined && sentAt != null) {
      await _mediaInventory.refineClock(customer, identity.id, sentAt);
    }
    final completeOriginal = cacheCopy || clipboardCopy || originalDownload;
    final matcher =
        _visualMatcher ??= MediaVisualMatcher(await _database.history);
    final visualMatch = identity.reused || mediaReceiptId != null
        ? null
        : await matcher.find(
            customer: customer,
            bytes: bytes,
            sentAt: sentAt,
            observedAt: DateTime.now(),
            turnKey: recovery != null && recovery.unreadEvidence > 0
                ? turnKey
                : null,
            candidateOriginal: completeOriginal);
    final upgrading =
        visualMatch != null && visualMatch.partial && completeOriginal;
    final stableId = visualMatch?.messageId ?? identity.id;
    if (visualMatch != null) {
      RuntimeTrace.record('media.representation_linked', {
        'customer': customer,
        'messageId': stableId,
        'referencePath': visualMatch.path,
        'evidenceId': evidenceId,
        'observationId': observationId,
        'pixelError': visualMatch.score,
        'source': cacheCopy ? 'jd_image_cache' : 'window_crop',
        'upgradingToOriginal': upgrading,
      });
      if (!upgrading) {
        // Re-reading a previously answered image can start a synthetic visual
        // recovery. A proven representation is not a new unread badge.
        if (recovery != null &&
            recovery.unreadEvidence == 0 &&
            !await _database.hasPendingUnanswered(customer)) {
          _finishUnreadRecovery(customer);
          RuntimeTrace.record('media.synthetic_recovery_resolved', {
            'customer': customer,
            'messageId': stableId,
            'reason': 'existing_representation_without_new_unread_evidence',
          });
        }
        return null;
      }
    }
    final known = ((await (await _database.history).read(customer))?['messages']
                as List? ??
            const [])
        .whereType<Map>()
        .where((m) => m['id'] == stableId)
        .firstOrNull;
    final priorMedia =
        (known?['media'] as List? ?? const []).whereType<Map>().toList();
    final loadingPreview = videoPreview &&
        image.playbackOverlayDetected &&
        (image.foregroundFraction ?? 1) <= .01;
    final richerVideoCover = videoPreview &&
        !loadingPreview &&
        priorMedia.any((m) => m['is_loading_preview'] == true);
    final correctVideoCover = videoPreview &&
        priorMedia.isNotEmpty &&
        !priorMedia.any((m) =>
            m['type'] == 'video' ||
            m['capture_source'] == 'verified_media_preview');
    final upgradePartial =
        completeOriginal && priorMedia.any((m) => m['is_partial'] == true);
    final containsVideo = videoPreview ||
        priorMedia.any((m) =>
            m['type'] == 'video' ||
            const {
              'jd_video_frame_1fps',
              'verified_media_preview',
              'jd_video_preview',
              'jd_video_cover',
            }.contains(m['capture_source']));
    MediaPayloadUpgradeDecision? imageUpgrade;
    var quality = captureQuality;
    if (!containsVideo) {
      final answered =
          await _database.isMessageFormallyAnswered(customer, stableId);
      quality = {
        ...await computeImageCaptureQuality(bytes,
            touchesViewportEdge: captureQuality['touchesViewportEdge'] as bool?,
            foregroundFraction: image.foregroundFraction,
            width: captureQuality['width'] as int?,
            height: captureQuality['height'] as int?),
        ...captureQuality,
      };
      final previous = <MediaPayloadVersion>[];
      for (final media in priorMedia.where((m) => m['type'] == 'image')) {
        final path = media['path']?.toString() ?? '';
        final file = path.startsWith('file:')
            ? File.fromUri(Uri.parse(path))
            : File(path);
        final available = path.isNotEmpty && await file.exists();
        final oldBytes = available ? await file.readAsBytes() : null;
        var oldQuality = Map<String, Object?>.from(
            media['capture_quality'] as Map? ?? const {});
        if (oldQuality.isEmpty &&
            oldBytes != null &&
            media['is_partial'] == true) {
          oldQuality = await computeImageCaptureQuality(oldBytes);
        }
        previous.add(MediaPayloadVersion(
            sha256:
                oldBytes == null ? null : sha256.convert(oldBytes).toString(),
            available: available,
            isPartial: media['is_partial'] == true,
            isLoadingPreview: media['is_loading_preview'] == true,
            verifiedOriginal: const {
              'jd_image_cache',
              'jd_clipboard_copy',
              'jd_image_viewer_download'
            }.contains(media['capture_source']),
            captureSource: media['capture_source']?.toString(),
            captureQuality: oldQuality));
      }
      imageUpgrade = MediaPayloadUpgrade.decide(
          sameMessageVerified: parent != null || _automationSessionId == null,
          formallyAnswered: answered,
          candidate: MediaPayloadVersion(
              sha256: digest,
              isPartial: !completeOriginal,
              isLoadingPreview: loadingPreview,
              verifiedOriginal: completeOriginal,
              captureSource: cacheCopy
                  ? 'jd_image_cache'
                  : clipboardCopy
                      ? 'jd_clipboard_copy'
                      : originalDownload
                          ? 'jd_image_viewer_download'
                          : viewportFallback
                              ? 'verified_chat_viewport_fallback'
                              : 'verified_window_crop',
              captureQuality: quality),
          previous: previous);
      if (!imageUpgrade.shouldStore) {
        RuntimeTrace.record('media.representation_retained', {
          'customer': customer,
          'messageId': stableId,
          'reason': imageUpgrade.reason,
          'isDuplicatePayload':
              imageUpgrade.kind == MediaPayloadUpgradeKind.exactDuplicate,
        });
        return null;
      }
    }
    if (imageUpgrade == null &&
        identity.reused &&
        priorMedia.isNotEmpty &&
        !correctVideoCover &&
        !upgradePartial &&
        !richerVideoCover) {
      RuntimeTrace.record('media.exact_duplicate', {
        'customer': customer,
        'contentSha256': digest,
        'messageId': stableId,
        'messageIdSource': 'content_clock_and_observed_turn'
      });
      return null;
    }
    final extension = image.extension ?? 'png';
    final originalName = image.originalName ??
        'qianniu_${DateTime.now().millisecondsSinceEpoch}.$extension';
    final path = await (await _database.history).saveMedia(
      userId: customer,
      filename: originalName,
      bytes: bytes,
    );
    final saved = CapturedMessage(
      stableId: stableId,
      observationTurnKey: turnKey,
      mediaReceiptId: mediaReceiptId,
      direction: 'incoming',
      body: videoPreview
          ? '[Customer sent media; visible preview captured, video could not be verified]'
          : clipboardCopy
              ? '[Customer sent an image; copied from JD]'
              : cacheCopy
                  ? '[Customer sent an image; original copied from JD cache]'
                  : originalDownload
                      ? '[Customer sent an image; original downloaded]'
                      : '[Customer sent an image; visible portion captured]',
      sender: customer,
      sentAt: sentAt,
      axPath: clipboardCopy
          ? 'ocr:jd-clipboard-image'
          : cacheCopy
              ? 'ocr:jd-image-cache'
              : viewportFallback
                  ? 'ocr:visible-chat-viewport-fallback'
                  : 'ocr:visible-image-region',
      media: [
        CapturedMedia(
          type: 'image',
          path: path,
          mimeType: image.mimeType,
          originalName: originalName,
          captureSource: videoPreview
              ? 'verified_media_preview'
              : clipboardCopy
                  ? 'jd_clipboard_copy'
                  : cacheCopy
                      ? 'jd_image_cache'
                      : originalDownload
                          ? 'jd_image_viewer_download'
                          : viewportFallback
                              ? 'verified_chat_viewport_fallback'
                              : 'verified_window_crop',
          isPartial: !originalDownload && !clipboardCopy && !cacheCopy,
          isLoadingPreview: loadingPreview,
          description: 'Pending Codex visual analysis.',
          visualFingerprint: fingerprint,
          captureQuality: quality,
        ),
      ],
    );
    if (upgrading || imageUpgrade?.replaceExisting == true) {
      final promoted = await (await _database.history)
          .promoteMedia(customer, stableId, saved);
      RuntimeTrace.record('media.representation_upgraded', {
        'customer': customer,
        'messageId': stableId,
        'promoted': promoted,
        'path': path,
      });
      if (!promoted) return null;
      // Propagate an in-place image upgrade to the media revision ledger.
      // History already holds this ID, so saveCapture will not duplicate it.
      return saved;
    }
    return saved;
  }

  String _visibleMediaStableId(String prefix, String digest, DateTime? turnAt) {
    if (turnAt == null) return '$prefix:$digest';
    return '$prefix:$digest:${turnAt.toUtc().microsecondsSinceEpoch}';
  }

  Widget _unansweredCustomers() {
    if (_unansweredCountsFailed) {
      return const Padding(
          padding: EdgeInsets.all(14), child: Text('待回复数量暂时无法核对'));
    }
    final counts = _unansweredCounts;
    if (counts == null) {
      return const Padding(
          padding: EdgeInsets.all(14), child: Text('正在核对待回复问题…'));
    }
    if (counts.isEmpty && _admissionGapCounts.isEmpty) {
      return const Padding(
          padding: EdgeInsets.all(14), child: Text('当前没有待回复问题'));
    }
    final queueOrder = {
      for (var i = 0; i < _conversations.length; i++)
        _conversations[i].userId: i,
    };
    final customers = {...counts.keys, ..._admissionGapCounts.keys}.toList()
      ..sort((a, b) {
        final order = (queueOrder[a] ?? _conversations.length)
            .compareTo(queueOrder[b] ?? _conversations.length);
        return order == 0 ? a.compareTo(b) : order;
      });
    return ListView.builder(
        itemCount: customers.length,
        itemBuilder: (context, index) {
          final customer = customers[index];
          final conversation = _conversations
              .where((c) => c.userId == customer || c.customerName == customer)
              .firstOrNull;
          return ListTile(
              key: ValueKey('unanswered-customer:$customer'),
              selected: customer == _selectedMessageCustomer,
              selectedTileColor: Colors.orange.withValues(alpha: .08),
              leading: const Icon(Icons.person_outline),
              title: Text(customer, maxLines: 2),
              subtitle: Text((_admissionGapCounts[customer] ?? 0) == 0
                  ? '等待正式回复'
                  : '其中 ${_admissionGapCounts[customer]} 条消息正在恢复，尚未正式回复'),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                Text(
                    '${(counts[customer] ?? 0) + (_admissionGapCounts[customer] ?? 0)} 条',
                    key: ValueKey('unanswered-count:$customer'),
                    style: TextStyle(
                        color: Colors.red.shade800,
                        fontWeight: FontWeight.w700)),
                if (conversation != null)
                  IconButton(
                      tooltip: '查看对话记录',
                      icon: const Icon(Icons.open_in_new, size: 18),
                      onPressed: () => showDialog<void>(
                              context: context,
                              builder: (_) => _MessageDialog(
                                  conversation: conversation,
                                  database: _database,
                                  onReplyCompleted: _coordinator.refresh))
                          .then((_) => _refreshTickets())),
              ]),
              onTap: () => _selectMessageCustomer(customer));
        });
  }

  @override
  void dispose() {
    _imageOriginalTimer?.cancel();
    _homeDisposed = true;
    _workSummaryRefresh++;
    _messageRecordsRefresh++;
    _maintenanceTimer?.cancel();
    _mediaCacheProgressTimer?.cancel();
    _runEpoch++;
    HostedReplyService.cancelRun(_database, sessionId: _automationSessionId);
    unawaited(ManagedMediaProcesses.shared.cancelRun());
    _viewportCapturePump.stop();
    _diagnosticWork.cancelPending();
    unawaited(_adapter.setAutomationEpoch(_runEpoch, running: false));
    for (final c in _activeDraftCancellations.values) {
      c.cancel();
    }
    _autoCaptureTimer?.cancel();
    _unreadSignalTimer?.cancel();
    _redSignalTimer?.cancel();
    for (final timer in _slaPreparationTimers.values) {
      timer.cancel();
    }
    _slaPreparationTimers.clear();
    _activeChatSignalTimer?.cancel();
    _failedSendRetryTimer?.cancel();
    _deliveryRetryTimer?.cancel();
    for (final timer in _hostedCompletionTimers.values) {
      timer.cancel();
    }
    _hostedCompletionTimers.clear();
    for (final timer in _draftRetryTimers.values) {
      timer.cancel();
    }
    for (final timer in _batchCollectionTimers.values) {
      timer.cancel();
    }
    for (final timer in _slaFallbackTimers.values) {
      timer.cancel();
    }
    for (final timer in _unreadHoldingTimers.values) {
      timer.cancel();
    }
    for (final timer in _unreadResendTimers.values) {
      timer.cancel();
    }
    _updateSubscription?.cancel();
    _diagnosticSubscription?.cancel();
    _failedSendInspectionSubscription?.cancel();
    _adapter.close();
    _database.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!Platform.isMacOS) {
      return const Scaffold(
          body: Center(
              child:
                  Text('The capture adapter currently supports macOS only.')));
    }
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 68,
        titleSpacing: 20,
        title: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircleAvatar(
                radius: 18, child: Icon(Icons.support_agent_rounded, size: 21)),
            SizedBox(width: 12),
            Flexible(
                child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(AppRuntime.appName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style:
                        TextStyle(fontSize: 19, fontWeight: FontWeight.w700)),
                Text('v${AppRuntime.version}',
                    maxLines: 1,
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w400,
                        color: Colors.black54)),
              ],
            )),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Refresh connection status',
            onPressed: _refreshStatus,
            icon: const Icon(Icons.refresh_rounded),
          ),
          const SizedBox(width: 8),
          Tooltip(
            message: '开始前准备辅助功能、屏幕录制、语音识别、京麦缓存读取和本地保存权限',
            child: OutlinedButton.icon(
              onPressed: _preparingPermissions ||
                      _autoCaptureRunning ||
                      _autoCaptureStarting
                  ? null
                  : _prepareRunPermissions,
              icon: Icon(
                  _preparingPermissions
                      ? Icons.hourglass_top_rounded
                      : _runPermissionsReady
                          ? Icons.check_circle
                          : Icons.verified_user_outlined,
                  color: _runPermissionsReady ? Colors.green : null),
              label: Text(_preparingPermissions
                  ? '正在授权…'
                  : _runPermissionsReady
                      ? '权限已就绪'
                      : '授权所需权限'),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton.icon(
            onPressed: _autoCaptureStarting ||
                    _exportingReport ||
                    !_settingsLoaded ||
                    !_settingsValid ||
                    _preparingPermissions ||
                    (!_autoCaptureRunning &&
                        (!_runPermissionsReady || !_databaseReady))
                ? null
                : _start,
            icon: Icon(_autoCaptureRunning
                ? Icons.stop_circle_outlined
                : _autoCaptureStarting
                    ? Icons.hourglass_top_rounded
                    : Icons.play_circle_outline_rounded),
            label: Text(_autoCaptureRunning
                ? 'Stop automation'
                : _autoCaptureStarting
                    ? 'Opening JD…'
                    : 'Start automation'),
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            key: const ValueKey('export-stopped-report'),
            onPressed: _autoCaptureRunning ||
                    _autoCaptureStarting ||
                    _exportingReport ||
                    _reportRunStoppedAt == null
                ? null
                : _exportStoppedReport,
            icon: Icon(_exportingReport
                ? Icons.hourglass_top
                : Icons.download_outlined),
            label: Text(_exportingReport ? '正在导出…' : '导出报告'),
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: Align(
        alignment: Alignment.topCenter,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Card(
                      child: Padding(
                    padding: const EdgeInsets.all(18),
                    child: Row(children: [
                      Icon(
                          _status['trusted'] == true
                              ? Icons.check_circle_outline
                              : Icons.verified_user_outlined,
                          color:
                              _status['trusted'] == true ? Colors.green : null),
                      const SizedBox(width: 12),
                      Expanded(
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                            Text(_autoCaptureRunning ? '自动回复运行中' : '自动回复已停止',
                                style: const TextStyle(
                                    fontSize: 18, fontWeight: FontWeight.w600)),
                            const SizedBox(height: 5),
                            Text(_status['trusted'] == true
                                ? '京麦连接已就绪'
                                : '请先完成所需权限授权'),
                          ])),
                    ]),
                  )),
                  const SizedBox(height: 20),
                  AutomationControls(
                    settings: _automationSettings,
                    locked: !_settingsLoaded ||
                        _autoCaptureRunning ||
                        _autoCaptureStarting ||
                        _exportingReport,
                    onChanged: _changeAutomationSettings,
                    onValidityChanged: (valid) =>
                        setState(() => _settingsValid = valid),
                  ),
                  const SizedBox(height: 12),
                  const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 12),
                      child: Text('参数会自动保存，下次打开沿用。测试结束后停止自动回复，再导出报告查看处理详情。',
                          style: TextStyle(color: Colors.black54))),
                ]),
          ),
        ),
      ),
    );
  }
}

class _MessageDialog extends StatefulWidget {
  const _MessageDialog({
    required this.conversation,
    required this.database,
    required this.onReplyCompleted,
  });

  final ConversationSummary conversation;
  final CaptureDatabase database;
  final Future<void> Function() onReplyCompleted;

  @override
  State<_MessageDialog> createState() => _MessageDialogState();
}

class _MessageDialogState extends State<_MessageDialog> {
  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.conversation.customerName),
        content: SizedBox(
          width: 620,
          height: 560,
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const Text('Captured and sent messages',
                style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Expanded(
              child: ListView(
                children: widget.conversation.messages
                    .map((message) => ListTile(
                          dense: true,
                          leading: Icon(message.direction == 'incoming'
                              ? Icons.call_received
                              : message.direction == 'outgoing'
                                  ? Icons.call_made
                                  : Icons.help_outline),
                          title: Text(message.body),
                          subtitle: Text(message.stableId),
                        ))
                    .toList(),
              ),
            ),
            const Card(
              child: Padding(
                padding: EdgeInsets.all(10),
                child: Text(
                    'Replies are generated and sent automatically. Unsent drafts are not shown or written to conversation JSON.'),
              ),
            ),
          ]),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'))
        ],
      );
}

class _AutomationStopped implements Exception {
  const _AutomationStopped();
}
