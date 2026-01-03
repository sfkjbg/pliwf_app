// /lib/ble_slot_page.dart
//
// PILWF / Hive Dashboard
// - BLE scan/connect (flutter_blue_plus)
// - Per-slot config persistence (SharedPreferences)
// - Per-slot EMA smoothing (stable UI & baseline/loss computations)
// - Bottle baseline + loss display & controls
//
// IMPORTANT CONTRACT with firmware:
// Packet bytes (12):
// 0:0xCA 1:0xFE 2:slotId 3:flags
// 4-5: deltaMg (i16) 6-7: weightX10 (u16) 8-9: baseX10 (u16)
// 10:eventType 11:seq
//
// Flag bits expected by UI:
// bit0 TAKEN, bit1 REMOVED, bit2 UNEXPECTED, bit3 STABLE
//
// We show command feedback from eventType:
// 10 ZERO_PENDING, 11 TARE_PENDING, 2 ZERO_DONE, 1 TARE_DONE, 99 FAILED, 3 CAL_SET

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ===================== BLE UUIDs =====================
final Guid svcUuid = Guid("7d2a0a5d-7c7a-4e8b-8cb4-2f2cf6b5b201");
final Guid chUuid = Guid("7d2a0a5d-7c7a-4e8b-8cb4-2f2cf6b5b202");
final Guid ctrlUuid = Guid("7d2a0a5d-7c7a-4e8b-8cb4-2f2cf6b5b203");
final Guid cfgUuid = Guid("7d2a0a5d-7c7a-4e8b-8cb4-2f2cf6b5b204");

// ===================== Helpers =====================
int _i16le(Uint8List b, int o) => (b[o] | (b[o + 1] << 8)) << 16 >> 16;
int _u16le(Uint8List b, int o) => (b[o] | (b[o + 1] << 8));

void _snack(BuildContext context, String msg) {
  ScaffoldMessenger.of(context).clearSnackBars();
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
}

// ===================== Data Models =====================

class Medication {
  final String id;
  String name;
  double mgPerPill;
  String notes;

  Medication({
    required this.id,
    required this.name,
    required this.mgPerPill,
    this.notes = '',
  });
}

class SlotConfig {
  int slotId;
  String slotName;
  String? medicationId;

  double targetDoseMg;
  int targetPillCount;

  double? bottleBaselineG;

  double? avgPillWeightG;
  final List<double> pillSamplesG;

  SlotConfig({
    required this.slotId,
    required this.slotName,
    this.medicationId,
    this.targetDoseMg = 0,
    this.targetPillCount = 0,
    this.bottleBaselineG,
    this.avgPillWeightG,
    List<double>? pillSamplesG,
  }) : pillSamplesG = pillSamplesG ?? <double>[];

  void recomputeAvg() {
    if (pillSamplesG.isEmpty) {
      avgPillWeightG = null;
      return;
    }
    final sum = pillSamplesG.fold<double>(0, (a, b) => a + b);
    avgPillWeightG = sum / pillSamplesG.length;
  }

  Map<String, dynamic> toJson() => {
        'slotId': slotId,
        'slotName': slotName,
        'medicationId': medicationId,
        'targetDoseMg': targetDoseMg,
        'targetPillCount': targetPillCount,
        'bottleBaselineG': bottleBaselineG,
        'avgPillWeightG': avgPillWeightG,
        'pillSamplesG': pillSamplesG,
      };

  static SlotConfig fromJson(Map<String, dynamic> j) {
    final cfg = SlotConfig(
      slotId: (j['slotId'] ?? 0) as int,
      slotName: (j['slotName'] ?? 'Slot') as String,
      medicationId: j['medicationId'] as String?,
      targetDoseMg: ((j['targetDoseMg'] ?? 0) as num).toDouble(),
      targetPillCount: (j['targetPillCount'] ?? 0) as int,
      bottleBaselineG: (j['bottleBaselineG'] == null)
          ? null
          : ((j['bottleBaselineG'] as num).toDouble()),
      avgPillWeightG: (j['avgPillWeightG'] == null)
          ? null
          : ((j['avgPillWeightG'] as num).toDouble()),
      pillSamplesG: (j['pillSamplesG'] as List?)
              ?.map((e) => (e as num).toDouble())
              .toList() ??
          <double>[],
    );
    cfg.recomputeAvg();
    return cfg;
  }
}

class SlotPacket {
  final int slotId;
  final int flags;
  final int deltaMg;
  final double weightG;
  final double baseG;
  final int eventType;
  final int seq;

  SlotPacket(
    this.slotId,
    this.flags,
    this.deltaMg,
    this.weightG,
    this.baseG,
    this.eventType,
    this.seq,
  );

  static SlotPacket? parse(Uint8List b) {
    if (b.length < 12) return null;
    if (b[0] != 0xCA || b[1] != 0xFE) return null;

    final slotId = b[2];
    final flags = b[3];
    final deltaMg = _i16le(b, 4);
    final weightX10 = _u16le(b, 6);
    final baseX10 = _u16le(b, 8);
    final eventType = b[10];
    final seq = b[11];

    return SlotPacket(
      slotId,
      flags,
      deltaMg,
      weightX10 / 10.0,
      baseX10 / 10.0,
      eventType,
      seq,
    );
  }
}

class SlotView {
  final int slotId;
  final String name;
  final String med;
  final String dose;
  final double weightG;
  final double baselineG;
  final double deltaG;
  final int flags;
  final DateTime lastUpdate;

  const SlotView({
    required this.slotId,
    required this.name,
    required this.med,
    required this.dose,
    required this.weightG,
    required this.baselineG,
    required this.deltaG,
    required this.flags,
    required this.lastUpdate,
  });

  bool get taken => (flags & (1 << 0)) != 0;
  bool get removed => (flags & (1 << 1)) != 0;
  bool get unexpected => (flags & (1 << 2)) != 0;
  bool get stable => (flags & (1 << 3)) != 0;

  String get statusText {
    if (removed) return 'Bottle removed';
    if (taken) return 'Dose taken';
    if (unexpected) return 'Settling / changing';
    if (stable) return 'Stable';
    return 'Unknown';
  }

  IconData get statusIcon {
    if (removed) return Icons.warning_amber_rounded;
    if (taken) return Icons.check_circle;
    if (unexpected) return Icons.report_problem;
    if (stable) return Icons.scale;
    return Icons.help_outline;
  }
}

class EventView {
  final DateTime ts;
  final int slotId;
  final String title;
  final String detail;

  const EventView({
    required this.ts,
    required this.slotId,
    required this.title,
    required this.detail,
  });
}

class WeightPoint {
  final DateTime ts;
  final double g;
  final bool stable;
  const WeightPoint({required this.ts, required this.g, required this.stable});
}

// ===================== Main Page =====================

class BleSlotPage extends StatefulWidget {
  const BleSlotPage({super.key});
  @override
  State<BleSlotPage> createState() => _BleSlotPageState();
}

class _BleSlotPageState extends State<BleSlotPage> {
  // ----------------- UI state -----------------
  bool demoMode = true;
  bool scanning = false;
  String _statusText = '';

  // ----------------- BLE state -----------------
  BluetoothDevice? device;
  BluetoothCharacteristic? notifyChar;
  BluetoothCharacteristic? ctrlChar;
  BluetoothCharacteristic? cfgChar;

  final List<ScanResult> _scanResults = [];
  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<BluetoothConnectionState>? _connSub;
  StreamSubscription<List<int>>? _notifySub;
  BluetoothConnectionState _connState = BluetoothConnectionState.disconnected;

  // ----------------- Persistence: MAC/Slot/Label -----------------
  final Map<int, String> _slotToMac = {};
  final Map<String, int> _macToSlot = {};
  final Map<String, String> _macLabel = {};

  String _kSlotMac(int slotId) => 'slot_mac_$slotId';
  String _kMacLabel(String mac) => 'mac_label_$mac';

  // ----------------- Slot configuration persistence -----------------
  String _kSlotCfg(int slotId) => 'slot_cfg_$slotId';

  // Medication DB (in-memory)
  final List<Medication> _medDb = [];

  // Per-slot configs (persisted)
  final Map<int, SlotConfig> _slotCfg = {};

  // Live notifiers per slot
  final Map<int, ValueNotifier<double?>> _liveWeight = {};
  final Map<int, ValueNotifier<bool>> _liveStable = {};
  final Map<int, ValueNotifier<List<WeightPoint>>> _liveHistory = {};

  // ----------------- Smoothing -----------------
  final Map<int, double> _emaBySlot = {};
  static const double _emaAlpha = 0.20;

  double _smoothWeight(int slotId, double rawG) {
    final prev = _emaBySlot[slotId];
    final smoothed =
        (prev == null) ? rawG : (_emaAlpha * rawG + (1.0 - _emaAlpha) * prev);
    _emaBySlot[slotId] = smoothed;
    return smoothed;
  }

  // ----------------- Demo -----------------
  final _rng = Random();
  Timer? _demoTimer;

  // slotId -> SlotView
  final Map<int, SlotView> _slots = {};
  final List<EventView> _events = [];

  // History retention
  static const int _historyMaxPoints = 3000;
  static const Duration _historyMaxAge = Duration(minutes: 30);

  @override
  void initState() {
    super.initState();
    _initMedDb();
    _initDemoData();
    _ensureSlotConfigsForExistingSlots();
    _startDemo();
    _loadAssignments();
    _loadSlotConfigs();
  }

  @override
  void dispose() {
    _demoTimer?.cancel();
    _scanSub?.cancel();
    _connSub?.cancel();
    _notifySub?.cancel();

    for (final n in _liveWeight.values) n.dispose();
    for (final n in _liveStable.values) n.dispose();
    for (final n in _liveHistory.values) n.dispose();

    _emaBySlot.clear();
    try {
      device?.disconnect();
    } catch (_) {}
    super.dispose();
  }

  // ===================== Persistence =====================

  Future<void> _loadAssignments() async {
    final prefs = await SharedPreferences.getInstance();

    _slotToMac.clear();
    _macToSlot.clear();
    _macLabel.clear();

    for (final k in prefs.getKeys()) {
      if (k.startsWith('slot_mac_')) {
        final idStr = k.replaceFirst('slot_mac_', '');
        final id = int.tryParse(idStr);
        final mac = prefs.getString(k);
        if (id != null && mac != null && mac.isNotEmpty) {
          _slotToMac[id] = mac;
          _macToSlot[mac] = id;
          _slotCfg.putIfAbsent(id, () => SlotConfig(slotId: id, slotName: 'Slot $id'));
          _ensureLiveNotifiers(id);
        }
      }
      if (k.startsWith('mac_label_')) {
        final mac = k.replaceFirst('mac_label_', '');
        final label = prefs.getString(k);
        if (label != null && label.isNotEmpty) {
          _macLabel[mac] = label;
        }
      }
    }

    if (mounted) setState(() {});
  }

  Future<void> _saveAssignment({required int slotId, required String mac}) async {
    final prefs = await SharedPreferences.getInstance();

    final oldSlot = _macToSlot[mac];
    if (oldSlot != null && oldSlot != slotId) {
      _slotToMac.remove(oldSlot);
      await prefs.remove(_kSlotMac(oldSlot));
    }

    final oldMac = _slotToMac[slotId];
    if (oldMac != null && oldMac != mac) {
      _macToSlot.remove(oldMac);
    }

    _slotToMac[slotId] = mac;
    _macToSlot[mac] = slotId;

    await prefs.setString(_kSlotMac(slotId), mac);

    _slotCfg.putIfAbsent(slotId, () => SlotConfig(slotId: slotId, slotName: 'Slot $slotId'));
    _ensureLiveNotifiers(slotId);
  }

  Future<void> _saveMacLabel({required String mac, required String label}) async {
    final prefs = await SharedPreferences.getInstance();
    _macLabel[mac] = label;
    await prefs.setString(_kMacLabel(mac), label);
  }

  Future<void> _clearAssignmentForSlot(int slotId) async {
    final prefs = await SharedPreferences.getInstance();
    final mac = _slotToMac.remove(slotId);
    if (mac != null) _macToSlot.remove(mac);
    await prefs.remove(_kSlotMac(slotId));
    if (mounted) setState(() {});
  }

  // ===================== Slot Config persistence =====================

  Future<void> _loadSlotConfigs() async {
    final prefs = await SharedPreferences.getInstance();

    for (final k in prefs.getKeys()) {
      if (!k.startsWith('slot_cfg_')) continue;
      final idStr = k.replaceFirst('slot_cfg_', '');
      final id = int.tryParse(idStr);
      if (id == null) continue;

      final s = prefs.getString(k);
      if (s == null || s.isEmpty) continue;

      try {
        final j = jsonDecode(s) as Map<String, dynamic>;
        _slotCfg[id] = SlotConfig.fromJson(j);
        _ensureLiveNotifiers(id);
      } catch (_) {}
    }

    if (mounted) setState(() {});
  }

  Future<void> _saveSlotCfg(int slotId) async {
    final prefs = await SharedPreferences.getInstance();
    final cfg = _slotCfg[slotId];
    if (cfg == null) return;
    await prefs.setString(_kSlotCfg(slotId), jsonEncode(cfg.toJson()));
  }

  // ===================== Live Notifiers & History =====================

  void _ensureLiveNotifiers(int slotId) {
    _liveWeight.putIfAbsent(slotId, () => ValueNotifier<double?>(null));
    _liveStable.putIfAbsent(slotId, () => ValueNotifier<bool>(false));
    _liveHistory.putIfAbsent(slotId, () => ValueNotifier<List<WeightPoint>>(<WeightPoint>[]));
  }

  void _pushHistory(int slotId, double g, bool stable) {
    _ensureLiveNotifiers(slotId);
    final histN = _liveHistory[slotId]!;
    final now = DateTime.now();
    final list = List<WeightPoint>.from(histN.value);

    list.add(WeightPoint(ts: now, g: g, stable: stable));

    final cutoff = now.subtract(_historyMaxAge);
    while (list.isNotEmpty && list.first.ts.isBefore(cutoff)) {
      list.removeAt(0);
    }
    if (list.length > _historyMaxPoints) {
      list.removeRange(0, list.length - _historyMaxPoints);
    }

    histN.value = list;
  }

  // ===================== Demo =====================

  void _initDemoData() {
    final now = DateTime.now();

    _slots.clear();
    _events.clear();

    _slots[1] = SlotView(
      slotId: 1,
      name: 'Slot 1',
      med: 'Vitamin D3',
      dose: '1 / day',
      weightG: 134.200,
      baselineG: 134.200,
      deltaG: 0.000,
      flags: (1 << 3),
      lastUpdate: now,
    );

    _slots[2] = SlotView(
      slotId: 2,
      name: 'Slot 2',
      med: 'Metformin 500mg',
      dose: '2 / day',
      weightG: 212.700,
      baselineG: 213.000,
      deltaG: -0.300,
      flags: (1 << 3),
      lastUpdate: now,
    );

    _slots[3] = SlotView(
      slotId: 3,
      name: 'Slot 3',
      med: 'Blood Pressure',
      dose: '1 / day',
      weightG: 178.100,
      baselineG: 178.100,
      deltaG: 0.000,
      flags: (1 << 3),
      lastUpdate: now,
    );

    _slots[4] = SlotView(
      slotId: 4,
      name: 'Slot 4',
      med: 'Allergy',
      dose: 'As needed',
      weightG: 98.400,
      baselineG: 108.400,
      deltaG: -10.000,
      flags: (1 << 2),
      lastUpdate: now,
    );

    _slots[5] = SlotView(
      slotId: 5,
      name: 'Slot 5',
      med: 'Omega-3',
      dose: '1 / day',
      weightG: 156.000,
      baselineG: 156.500,
      deltaG: -0.500,
      flags: (1 << 2) | (1 << 3),
      lastUpdate: now,
    );

    _events.addAll([
      EventView(
        ts: now.subtract(const Duration(minutes: 12)),
        slotId: 2,
        title: 'Settling / changing',
        detail: 'Metformin 500mg (Δ -0.300g)',
      ),
      EventView(
        ts: now.subtract(const Duration(minutes: 34)),
        slotId: 4,
        title: 'Settling / changing',
        detail: 'Allergy bottle shifting',
      ),
      EventView(
        ts: now.subtract(const Duration(hours: 2, minutes: 5)),
        slotId: 5,
        title: 'Settling / changing',
        detail: 'Omega-3 (Δ -0.500g)',
      ),
    ]);
  }

  void _initMedDb() {
    if (_medDb.isNotEmpty) return;
    _medDb.addAll([
      Medication(id: 'vitd3', name: 'Vitamin D3', mgPerPill: 0, notes: 'mg per pill varies by brand'),
      Medication(id: 'metformin500', name: 'Metformin', mgPerPill: 500, notes: 'Example'),
      Medication(id: 'bp', name: 'Blood Pressure Med', mgPerPill: 0, notes: ''),
    ]);
  }

  void _ensureSlotConfigsForExistingSlots() {
    for (final s in _slots.values) {
      _slotCfg.putIfAbsent(s.slotId, () => SlotConfig(slotId: s.slotId, slotName: 'Slot ${s.slotId}'));
      _ensureLiveNotifiers(s.slotId);
    }
  }

  void _startDemo() {
    _demoTimer?.cancel();
    if (!demoMode) return;

    _demoTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final now = DateTime.now();
      final ids = _slots.keys.toList();
      if (ids.isEmpty) return;

      final id = ids[_rng.nextInt(ids.length)];
      final s = _slots[id]!;

      final noise = (_rng.nextDouble() - 0.5) * 0.08; // +/- 0.04g
      final newWeight = s.weightG + noise;
      final stableNow = true;

      final smoothed = _smoothWeight(id, newWeight);

      _liveWeight[id]!.value = smoothed;
      _liveStable[id]!.value = stableNow;
      _pushHistory(id, smoothed, stableNow);

      final updated = SlotView(
        slotId: s.slotId,
        name: s.name,
        med: s.med,
        dose: s.dose,
        weightG: smoothed,
        baselineG: s.baselineG,
        deltaG: smoothed - s.baselineG,
        flags: (1 << 3),
        lastUpdate: now,
      );

      if (mounted) setState(() => _slots[id] = updated);
    });
  }

  // ===================== Permissions =====================

  Future<bool> _ensureBlePermissions() async {
    if (defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.iOS) {
      return true;
    }

    final statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
    ].request();

    final scanOk = statuses[Permission.bluetoothScan]?.isGranted ?? false;
    final connectOk = statuses[Permission.bluetoothConnect]?.isGranted ?? false;

    final loc = await Permission.locationWhenInUse.request();
    final locOk = loc.isGranted || loc.isLimited;

    return scanOk && connectOk && locOk;
  }

  // ===================== BLE =====================

  Future<void> _startBle() async {
    final ok = await _ensureBlePermissions();
    if (!ok) {
      if (!mounted) return;
      setState(() => _statusText = 'Bluetooth permissions denied');
      return;
    }

    await FlutterBluePlus.turnOn();
    await _startScan();
  }

  Future<void> _startScan() async {
    final ok = await _ensureBlePermissions();
    if (!ok) {
      if (!mounted) return;
      setState(() => _statusText = 'Bluetooth permissions denied');
      return;
    }

    _scanResults.clear();
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {}

    setState(() {
      scanning = true;
      _statusText = 'Scanning…';
    });

    _scanSub?.cancel();
    _scanSub = FlutterBluePlus.scanResults.listen((results) {
      for (final r in results) {
        final advName = r.advertisementData.advName;
        final platformName = r.device.platformName;
        final name = advName.isNotEmpty ? advName : platformName;

        if (!name.startsWith('Hive')) continue;

        final exists = _scanResults.any((e) => e.device.remoteId == r.device.remoteId);
        if (!exists) {
          if (!mounted) return;
          setState(() => _scanResults.add(r));
        }
      }
    });

    await FlutterBluePlus.startScan(timeout: const Duration(seconds: 8));

    await Future.delayed(const Duration(seconds: 8));
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {}

    if (!mounted) return;

    await _scanSub?.cancel();
    _scanSub = null;

    setState(() {
      scanning = false;
      _statusText = _scanResults.isEmpty
          ? 'No devices found. Tap Scan again.'
          : 'Scan complete. Tap a device to connect.';
    });
  }

  Future<void> _disconnect() async {
    _connSub?.cancel();
    _notifySub?.cancel();
    _connSub = null;
    _notifySub = null;
    try {
      await device?.disconnect();
    } catch (_) {}
    setState(() {
      device = null;
      notifyChar = null;
      ctrlChar = null;
      cfgChar = null;
      _connState = BluetoothConnectionState.disconnected;
      _statusText = 'Disconnected.';
    });
  }

  Future<void> _connectTo(ScanResult r) async {
    final d = r.device;

    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {}

    setState(() {
      scanning = false;
      device = d;
      notifyChar = null;
      ctrlChar = null;
      cfgChar = null;
      _connState = BluetoothConnectionState.connecting;
      _statusText = 'Connecting…';
    });

    try {
      await d.disconnect();
    } catch (_) {}

    await d.connect(timeout: const Duration(seconds: 12), autoConnect: false);

    _connSub?.cancel();
    _connSub = d.connectionState.listen((state) {
      if (!mounted) return;
      setState(() => _connState = state);
    });

    setState(() => _statusText = 'Connected. Discovering services…');

    final services = await d.discoverServices();

    BluetoothCharacteristic? foundCtrl;
    BluetoothCharacteristic? foundCfg;

    for (final s in services) {
      for (final c in s.characteristics) {
        if (c.uuid == ctrlUuid) foundCtrl = c;
        if (c.uuid == cfgUuid) foundCfg = c;
      }
    }

    setState(() {
      ctrlChar = foundCtrl;
      cfgChar = foundCfg;
    });

    final hasSvc = services.any((s) => s.uuid == svcUuid);
    if (!hasSvc) {
      setState(() => _statusText = 'Connected, but Hive service not found on this device.');
      return;
    }

    await _subscribe(d, services: services);
  }

  String _deviceMac() => device?.remoteId.toString() ?? '';

  Future<void> _subscribe(BluetoothDevice d, {List<BluetoothService>? services}) async {
    final svcs = services ?? await d.discoverServices();
    final svc = svcs.firstWhere((s) => s.uuid == svcUuid);
    notifyChar = svc.characteristics.firstWhere((c) => c.uuid == chUuid);

    await notifyChar!.setNotifyValue(true);
    setState(() => _statusText = 'Listening… (assign device to slot)');

    _notifySub?.cancel();
    _notifySub = notifyChar!.onValueReceived.listen((value) {
      final pkt = SlotPacket.parse(Uint8List.fromList(value));
      if (pkt == null) return;

      final now = DateTime.now();

      final mac = _deviceMac();
      final mappedSlot = (mac.isEmpty) ? null : _macToSlot[mac];
      final effectiveSlotId = mappedSlot ?? pkt.slotId;

      _ensureLiveNotifiers(effectiveSlotId);
      _slotCfg.putIfAbsent(
        effectiveSlotId,
        () => SlotConfig(slotId: effectiveSlotId, slotName: 'Slot $effectiveSlotId'),
      );

      final prev = _slots[effectiveSlotId];
      final name = prev?.name ?? 'Slot $effectiveSlotId';
      final med = prev?.med ?? 'Unknown med';
      final dose = prev?.dose ?? '—';

      final rawWeight = pkt.weightG;
      final base = pkt.baseG;
      final stable = (pkt.flags & (1 << 3)) != 0;

      final weight = _smoothWeight(effectiveSlotId, rawWeight);
      final delta = weight - base;

      _liveWeight[effectiveSlotId]!.value = weight;
      _liveStable[effectiveSlotId]!.value = stable;
      _pushHistory(effectiveSlotId, weight, stable);

      final updated = SlotView(
        slotId: effectiveSlotId,
        name: name,
        med: med,
        dose: dose,
        weightG: weight,
        baselineG: base,
        deltaG: delta,
        flags: pkt.flags,
        lastUpdate: now,
      );

      if (mounted) {
        setState(() {
          _slots[effectiveSlotId] = updated;
        });
      }

      // EventType feedback (from firmware)
      if (!demoMode && mounted) {
        switch (pkt.eventType) {
          case 10:
            _snack(context, "ZERO: collecting for 2.5s… don’t touch.");
            break;
          case 11:
            _snack(context, "TARE: collecting for 2.5s… don’t touch.");
            break;
          case 2:
            _snack(context, "✅ ZERO complete");
            break;
          case 1:
            _snack(context, "✅ TARE complete (baseline set)");
            break;
          case 99:
            _snack(context, "⚠️ Command failed (not enough stable samples)");
            break;
          case 3:
            _snack(context, "✅ Calibration set");
            break;
          default:
            break;
        }
      }

      // Events list based on flags
      if ((pkt.flags & (1 << 0)) != 0) {
        _events.insert(
          0,
          EventView(
            ts: now,
            slotId: effectiveSlotId,
            title: 'Dose taken',
            detail: '$med (Δ ${(pkt.deltaMg / 1000.0).toStringAsFixed(3)}g)',
          ),
        );
      } else if ((pkt.flags & (1 << 1)) != 0) {
        _events.insert(
          0,
          EventView(ts: now, slotId: effectiveSlotId, title: 'Bottle removed', detail: '$med bottle removed'),
        );
      } else if ((pkt.flags & (1 << 2)) != 0) {
        _events.insert(
          0,
          EventView(
            ts: now,
            slotId: effectiveSlotId,
            title: 'Settling / changing',
            detail: '$med (Δ ${(pkt.deltaMg / 1000.0).toStringAsFixed(3)}g)',
          ),
        );
      }

      if (_events.length > 30) _events.removeRange(30, _events.length);
    });

    if (mounted) setState(() {});
  }

  Future<void> _sendCtrlCommand(String cmd) async {
    final c = ctrlChar;
    if (c == null) {
      if (!mounted) return;
      _snack(context, 'Control characteristic not found on device');
      return;
    }
    try {
      await c.write(Uint8List.fromList(cmd.codeUnits), withoutResponse: false);
    } catch (e) {
      if (!mounted) return;
      _snack(context, 'Failed to send command: $e');
    }
  }

  Future<void> _tareScale() => _sendCtrlCommand('TARE');
  Future<void> _zeroScale() => _sendCtrlCommand('ZERO');

  // ===================== Assign Device to Slot =====================

  Future<void> _showAssignDialog() async {
    final d = device;
    if (d == null) return;

    final mac = d.remoteId.toString();
    if (mac.isEmpty) return;

    final defaultLabel = _macLabel[mac] ?? 'pillLoadCell';
    final slotCtrl = TextEditingController(text: (_macToSlot[mac] ?? 1).toString());
    final labelCtrl = TextEditingController(text: defaultLabel);

    final res = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('Assign device to slot'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('MAC: $mac', style: const TextStyle(fontSize: 12, color: Colors.black54)),
                const SizedBox(height: 10),
                TextField(
                  controller: slotCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Slot number', hintText: '1'),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: labelCtrl,
                  decoration: const InputDecoration(labelText: 'Device name', hintText: 'pillLoadCell'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
            ElevatedButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Save')),
          ],
        );
      },
    );

    if (res != true) {
      slotCtrl.dispose();
      labelCtrl.dispose();
      return;
    }

    final slotId = int.tryParse(slotCtrl.text.trim());
    final label = labelCtrl.text.trim().isEmpty ? 'pillLoadCell' : labelCtrl.text.trim();

    slotCtrl.dispose();
    labelCtrl.dispose();

    if (slotId == null || slotId <= 0) return;

    await _saveAssignment(slotId: slotId, mac: mac);
    await _saveMacLabel(mac: mac, label: label);

    setState(() {
      _slots.putIfAbsent(
        slotId,
        () => SlotView(
          slotId: slotId,
          name: 'Slot $slotId',
          med: '—',
          dose: '—',
          weightG: _liveWeight[slotId]?.value ?? 0,
          baselineG: 0,
          deltaG: 0,
          flags: 0,
          lastUpdate: DateTime.now(),
        ),
      );

      _slotCfg.putIfAbsent(slotId, () => SlotConfig(slotId: slotId, slotName: 'Slot $slotId'));
      _statusText = 'Assigned $label to Slot $slotId';
    });
  }

  // ===================== UI Helpers =====================

  String _flagsText(int f) {
    final parts = <String>[];
    if ((f & (1 << 0)) != 0) parts.add('TAKEN');
    if ((f & (1 << 1)) != 0) parts.add('REMOVED');
    if ((f & (1 << 2)) != 0) parts.add('UNEXPECTED');
    if ((f & (1 << 3)) != 0) parts.add('STABLE');
    return parts.isEmpty ? '-' : parts.join(', ');
  }

  String _timeAgo(DateTime dt) {
    final d = DateTime.now().difference(dt);
    if (d.inSeconds < 60) return '${d.inSeconds}s ago';
    if (d.inMinutes < 60) return '${d.inMinutes}m ago';
    return '${d.inHours}h ago';
  }

  Color _statusColor(SlotView s) {
    if (s.removed) return Colors.orange;
    if (s.unexpected) return Colors.amber;
    if (s.taken) return Colors.green;
    if (s.stable) return Colors.blueGrey;
    return Colors.grey;
  }

  // ===================== Build =====================

  @override
  Widget build(BuildContext context) {
    final slotsSorted = demoMode
        ? (_slots.values.toList()..sort((a, b) => a.slotId.compareTo(b.slotId)))
        : ((_slotToMac.isEmpty ? _slots.values.toList() : _slots.values.where((s) => _slotToMac.containsKey(s.slotId)).toList())
          ..sort((a, b) => a.slotId.compareTo(b.slotId)));

    _ensureSlotConfigsForExistingSlots();

    return Scaffold(
      appBar: AppBar(
        title: const Text('PILWF — Hive Dashboard'),
        actions: [
          Row(
            children: [
              const Text('Demo', style: TextStyle(fontSize: 13)),
              Switch(
                value: demoMode,
                onChanged: (v) async {
                  setState(() => demoMode = v);

                  if (v) {
                    try { await FlutterBluePlus.stopScan(); } catch (_) {}
                    try { await device?.disconnect(); } catch (_) {}

                    device = null;
                    notifyChar = null;
                    scanning = false;
                    _statusText = '';

                    _emaBySlot.clear();
                    _initDemoData();
                    _ensureSlotConfigsForExistingSlots();
                    _startDemo();
                    if (mounted) setState(() {});
                  } else {
                    _demoTimer?.cancel();
                    await _loadAssignments();
                    await _loadSlotConfigs();

                    setState(() {
                      _slots.clear();
                      _events.clear();
                      _statusText = 'BLE mode: connect & assign device to slot';
                    });

                    await _startBle();
                  }
                },
              ),
              const SizedBox(width: 8),
            ],
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _summaryCard(slotsSorted),
          const SizedBox(height: 12),
          Text('Slots', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          if (!demoMode && _slotToMac.isEmpty)
            const Card(
              child: Padding(
                padding: EdgeInsets.all(14),
                child: Text('No paired slots yet. Connect a device and assign it to a slot.'),
              ),
            )
          else
            ...slotsSorted.map(_slotCard),
          const SizedBox(height: 16),
          Text('Recent events', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          _eventsCard(),
          const SizedBox(height: 24),
          Text('BLE debug', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          _bleDebugCard(),
        ],
      ),
    );
  }

  Widget _summaryCard(List<SlotView> slots) {
    final taken = slots.where((s) => s.taken).length;
    final removed = slots.where((s) => s.removed).length;
    final unexpected = slots.where((s) => s.unexpected).length;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Hive status', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                _pillChip(Icons.grid_view_rounded, '${slots.length} slots', Colors.blueGrey),
                _pillChip(Icons.check_circle, '$taken taken', Colors.green),
                _pillChip(Icons.warning_amber_rounded, '$removed removed', Colors.orange),
                _pillChip(Icons.report_problem, '$unexpected alerts', Colors.amber),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              demoMode
                  ? 'Demo mode is ON (no electronics needed).'
                  : (scanning ? 'Scanning for devices…' : (_statusText.isEmpty ? 'Ready.' : _statusText)),
              style: const TextStyle(color: Colors.black54),
            ),
          ],
        ),
      ),
    );
  }

  Widget _pillChip(IconData icon, String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withOpacity(0.25)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Text(label, style: TextStyle(color: color, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  Widget _slotCard(SlotView s) {
    final color = _statusColor(s);

    final mac = _slotToMac[s.slotId];
    final label = mac == null ? null : (_macLabel[mac] ?? 'pillLoadCell');

    final cfg = _slotCfg[s.slotId];
    final baselineBottle = cfg?.bottleBaselineG;
    final lossG = (baselineBottle == null) ? null : (baselineBottle - s.weightG);

    return Card(
      child: ListTile(
        onTap: () {
          final cfgForSlot = _slotCfg.putIfAbsent(
            s.slotId,
            () => SlotConfig(slotId: s.slotId, slotName: 'Slot ${s.slotId}'),
          );

          _ensureLiveNotifiers(s.slotId);

          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => SlotDetailPage(
                slotId: s.slotId,
                cfg: cfgForSlot,
                medDb: _medDb,
                weightListenable: _liveWeight[s.slotId]!,
                assignedMac: mac,
                deviceLabel: label ?? 'pillLoadCell',
                onCfgChanged: (updatedCfg) async {
                  setState(() => _slotCfg[s.slotId] = updatedCfg);
                  await _saveSlotCfg(s.slotId);
                },
                onAddMedication: (m) => setState(() => _medDb.add(m)),
                onTare: _tareScale,
                onZero: _zeroScale,
                onResetMac: () async => _clearAssignmentForSlot(s.slotId),
              ),
            ),
          );
        },
        leading: Icon(s.statusIcon, color: color),
        title: Text('${_slotCfg[s.slotId]?.slotName ?? s.name} — ${s.med}'),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 4),
            Text('${s.statusText} • ${_timeAgo(s.lastUpdate)}'),
            if (!demoMode && mac != null) ...[
              const SizedBox(height: 4),
              Text('Device: ${label ?? 'pillLoadCell'} • $mac',
                  style: const TextStyle(fontSize: 12, color: Colors.black54)),
            ],
            const SizedBox(height: 6),
            Wrap(
              spacing: 10,
              runSpacing: 6,
              children: [
                _kv('Dose', s.dose),
                _kv('Weight', '${s.weightG.toStringAsFixed(3)} g'),
                _kv('Dev base', '${s.baselineG.toStringAsFixed(3)} g'),
                _kv('Δ', '${s.deltaG.toStringAsFixed(3)} g'),
                if (lossG != null) _kv('Loss', '${lossG.toStringAsFixed(3)} g'),
                _kv('Flags', _flagsText(s.flags)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _kv(String k, String v) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.04),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text('$k: $v', style: const TextStyle(fontSize: 12)),
    );
  }

  Widget _eventsCard() {
    if (_events.isEmpty) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(14),
          child: Text('No events yet.'),
        ),
      );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          children: _events.take(3).map((e) {
            return ListTile(
              dense: true,
              leading: CircleAvatar(radius: 16, child: Text(e.slotId.toString())),
              title: Text(e.title),
              subtitle: Text('${e.detail}\n${_timeAgo(e.ts)}'),
              isThreeLine: true,
            );
          }).toList(),
        ),
      ),
    );
  }

  Widget _bleDebugCard() {
    final connected = _connState == BluetoothConnectionState.connected;
    final connecting = _connState == BluetoothConnectionState.connecting;

    final mac = device?.remoteId.toString();
    final label = (mac == null) ? null : (_macLabel[mac] ?? 'pillLoadCell');
    final mappedSlot = (mac == null) ? null : _macToSlot[mac];

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Mode: ${demoMode ? 'Demo (no BLE)' : 'BLE'}'),
            const SizedBox(height: 6),
            Text('Connection: ${_connState.name}'),
            const SizedBox(height: 6),
            Text('Status: ${_statusText.isEmpty ? '(none)' : _statusText}'),
            const SizedBox(height: 6),
            Text('Device: ${device?.platformName ?? '(none)'}'),
            const SizedBox(height: 6),
            Text('MAC: ${mac ?? '(none)'}'),
            if (mac != null) ...[
              const SizedBox(height: 6),
              Text('Label: $label'),
              const SizedBox(height: 6),
              Text('Mapped slot: ${mappedSlot?.toString() ?? '(not assigned)'}'),
            ],
            const SizedBox(height: 10),

            if (demoMode)
              const Text('Flip Demo OFF when your ESP32 is ready.')
            else ...[
              Row(
                children: [
                  ElevatedButton(
                    onPressed: scanning ? null : _startScan,
                    child: Text(scanning ? 'Scanning…' : 'Scan'),
                  ),
                  const SizedBox(width: 10),
                  if (connected || connecting) ...[
                    OutlinedButton(onPressed: _disconnect, child: const Text('Disconnect')),
                    const SizedBox(width: 10),
                    OutlinedButton(
                      onPressed: device == null ? null : _showAssignDialog,
                      child: const Text('Assign to slot'),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 10),
              const Text('Discovered devices:'),
              const SizedBox(height: 6),
              if (_scanResults.isEmpty)
                const Text('— none yet (tap Scan)')
              else
                Column(
                  children: _scanResults.take(10).map((r) {
                    final advName = r.advertisementData.advName;
                    final name = advName.isNotEmpty ? advName : r.device.platformName;
                    final title = name.isNotEmpty ? name : '(unnamed)';

                    return ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text(title),
                      subtitle: Text(r.device.remoteId.toString()),
                      trailing: ElevatedButton(
                        onPressed: () => _connectTo(r),
                        child: const Text('Connect'),
                      ),
                    );
                  }).toList(),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

// ===================== Slot Detail Page =====================

class SlotDetailPage extends StatefulWidget {
  final int slotId;
  final SlotConfig cfg;
  final List<Medication> medDb;

  final ValueListenable<double?> weightListenable;

  final String? assignedMac;
  final String deviceLabel;

  final Future<void> Function(SlotConfig updatedCfg) onCfgChanged;
  final void Function(Medication newMed) onAddMedication;
  final Future<void> Function() onTare;
  final Future<void> Function() onZero;
  final VoidCallback onResetMac;

  const SlotDetailPage({
    super.key,
    required this.slotId,
    required this.cfg,
    required this.medDb,
    required this.weightListenable,
    required this.assignedMac,
    required this.deviceLabel,
    required this.onCfgChanged,
    required this.onAddMedication,
    required this.onTare,
    required this.onZero,
    required this.onResetMac,
  });

  @override
  State<SlotDetailPage> createState() => _SlotDetailPageState();
}

class _SlotDetailPageState extends State<SlotDetailPage> {
  late SlotConfig _cfg;

  late final TextEditingController _slotNameCtrl;
  late final TextEditingController _doseMgCtrl;
  late final TextEditingController _pillCountCtrl;

  String? _selectedMedId;

  @override
  void initState() {
    super.initState();
    _cfg = SlotConfig(
      slotId: widget.cfg.slotId,
      slotName: widget.cfg.slotName,
      medicationId: widget.cfg.medicationId,
      targetDoseMg: widget.cfg.targetDoseMg,
      targetPillCount: widget.cfg.targetPillCount,
      bottleBaselineG: widget.cfg.bottleBaselineG,
      avgPillWeightG: widget.cfg.avgPillWeightG,
      pillSamplesG: List<double>.from(widget.cfg.pillSamplesG),
    );

    _selectedMedId = _cfg.medicationId;

    _slotNameCtrl = TextEditingController(text: _cfg.slotName);
    _doseMgCtrl = TextEditingController(
      text: _cfg.targetDoseMg == 0 ? '' : _cfg.targetDoseMg.toStringAsFixed(0),
    );
    _pillCountCtrl = TextEditingController(
      text: _cfg.targetPillCount == 0 ? '' : _cfg.targetPillCount.toString(),
    );
  }

  @override
  void dispose() {
    _slotNameCtrl.dispose();
    _doseMgCtrl.dispose();
    _pillCountCtrl.dispose();
    super.dispose();
  }

  Medication? _findMed(String? id) {
    if (id == null) return null;
    try {
      return widget.medDb.firstWhere((m) => m.id == id);
    } catch (_) {
      return null;
    }
  }

  Future<void> _saveAndPop() async {
    _cfg.slotName = _slotNameCtrl.text.trim().isEmpty ? 'Slot ${widget.slotId}' : _slotNameCtrl.text.trim();
    _cfg.medicationId = _selectedMedId;

    final doseMg = double.tryParse(_doseMgCtrl.text.trim());
    _cfg.targetDoseMg = (doseMg ?? 0).clamp(0, 999999);

    final pills = int.tryParse(_pillCountCtrl.text.trim());
    _cfg.targetPillCount = (pills ?? 0).clamp(0, 9999);

    await widget.onCfgChanged(_cfg);
    if (mounted) Navigator.of(context).pop();
  }

  void _captureSample() {
    final w = widget.weightListenable.value;
    if (w == null) return;
    setState(() {
      _cfg.pillSamplesG.add(w);
      _cfg.recomputeAvg();
    });
    widget.onCfgChanged(_cfg);
  }

  void _clearSamples() {
    setState(() {
      _cfg.pillSamplesG.clear();
      _cfg.recomputeAvg();
    });
    widget.onCfgChanged(_cfg);
  }

  void _setBottleBaselineFromCurrent() {
    final w = widget.weightListenable.value;
    if (w == null) return;
    setState(() {
      _cfg.bottleBaselineG = w;
    });
    widget.onCfgChanged(_cfg);
  }

  void _clearBottleBaseline() {
    setState(() {
      _cfg.bottleBaselineG = null;
    });
    widget.onCfgChanged(_cfg);
  }

  Future<void> _addMedicationDialog() async {
    final nameCtrl = TextEditingController();
    final mgCtrl = TextEditingController();
    final notesCtrl = TextEditingController();

    final res = await showDialog<Medication?>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('Add medication'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'Name')),
                const SizedBox(height: 10),
                TextField(
                  controller: mgCtrl,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                  decoration: const InputDecoration(labelText: 'mg per pill (optional)'),
                ),
                const SizedBox(height: 10),
                TextField(controller: notesCtrl, decoration: const InputDecoration(labelText: 'Notes (optional)')),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(null), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () {
                final name = nameCtrl.text.trim();
                if (name.isEmpty) {
                  Navigator.of(ctx).pop(null);
                  return;
                }
                final mg = double.tryParse(mgCtrl.text.trim()) ?? 0;
                final id = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_');
                Navigator.of(ctx).pop(Medication(id: id, name: name, mgPerPill: mg, notes: notesCtrl.text.trim()));
              },
              child: const Text('Add'),
            ),
          ],
        );
      },
    );

    nameCtrl.dispose();
    mgCtrl.dispose();
    notesCtrl.dispose();

    if (res != null) {
      widget.onAddMedication(res);
      setState(() => _selectedMedId = res.id);
      widget.onCfgChanged(_cfg..medicationId = res.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final med = _findMed(_selectedMedId);

    final mgPerPill = med?.mgPerPill ?? 0;
    final targetDoseMg = double.tryParse(_doseMgCtrl.text.trim()) ?? _cfg.targetDoseMg;
    final targetPills = int.tryParse(_pillCountCtrl.text.trim()) ?? _cfg.targetPillCount;

    int? pillsFromDose;
    if (mgPerPill > 0 && targetDoseMg > 0) {
      pillsFromDose = (targetDoseMg / mgPerPill).round();
    }

    double? doseWeightG;
    if (_cfg.avgPillWeightG != null && targetPills > 0) {
      doseWeightG = _cfg.avgPillWeightG! * targetPills;
    }

    final currentW = widget.weightListenable.value;
    final baselineBottle = _cfg.bottleBaselineG;
    final lossG = (baselineBottle == null || currentW == null) ? null : (baselineBottle - currentW);

    return Scaffold(
      appBar: AppBar(
        title: Text('Slot ${widget.slotId}'),
        actions: [
          IconButton(onPressed: _saveAndPop, icon: const Icon(Icons.save), tooltip: 'Save'),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Assignment', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  Text('MAC: ${widget.assignedMac ?? '(not assigned)'}', style: const TextStyle(color: Colors.black54)),
                  const SizedBox(height: 6),
                  Text('Device name: ${widget.deviceLabel}', style: const TextStyle(color: Colors.black54)),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton(
                      onPressed: widget.onResetMac,
                      child: const Text('Reset MAC assignment'),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),

          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Slot details', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 10),
                  TextField(controller: _slotNameCtrl, decoration: const InputDecoration(labelText: 'Slot name')),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          value: _selectedMedId ?? '__none__',
                          isExpanded: true,
                          decoration: const InputDecoration(labelText: 'Medication'),
                          items: [
                            const DropdownMenuItem<String>(value: '__none__', child: Text('(none)')),
                            ...widget.medDb.map((m) => DropdownMenuItem<String>(value: m.id, child: Text(m.name))),
                          ],
                          onChanged: (v) => setState(() => _selectedMedId = (v == '__none__' ? null : v)),
                        ),
                      ),
                      const SizedBox(width: 10),
                      ElevatedButton(onPressed: _addMedicationDialog, child: const Text('Add')),
                    ],
                  ),
                  if (med != null) ...[
                    const SizedBox(height: 8),
                    Text('mg per pill: ${med.mgPerPill == 0 ? '(unknown)' : med.mgPerPill.toStringAsFixed(0)}',
                        style: const TextStyle(color: Colors.black54)),
                    if (med.notes.trim().isNotEmpty)
                      Text('Notes: ${med.notes}', style: const TextStyle(color: Colors.black54)),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),

          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Scale controls', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  ValueListenableBuilder<double?>(
                    valueListenable: widget.weightListenable,
                    builder: (context, w, _) {
                      return Text(
                        'Current weight (smoothed): ${w == null ? '(no data yet)' : w.toStringAsFixed(3)} g',
                        style: const TextStyle(color: Colors.black54),
                      );
                    },
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      ElevatedButton(onPressed: widget.onTare, child: const Text('Tare')),
                      ElevatedButton(onPressed: widget.onZero, child: const Text('Zero')),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),

          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Bottle baseline & loss', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  Text(
                    'Baseline: ${baselineBottle == null ? '(not set)' : baselineBottle.toStringAsFixed(3)} g',
                    style: const TextStyle(color: Colors.black54),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Current (smoothed): ${currentW == null ? '(no data yet)' : currentW.toStringAsFixed(3)} g',
                    style: const TextStyle(color: Colors.black54),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Loss: ${lossG == null ? '(set baseline first)' : lossG.toStringAsFixed(3)} g',
                    style: const TextStyle(color: Colors.black54),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      ElevatedButton(
                        onPressed: currentW == null ? null : _setBottleBaselineFromCurrent,
                        child: const Text('Set baseline (current)'),
                      ),
                      OutlinedButton(
                        onPressed: baselineBottle == null ? null : _clearBottleBaseline,
                        child: const Text('Clear baseline'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Tip: Set baseline right after placing the full bottle. Loss increases as pills are removed.',
                    style: TextStyle(color: Colors.black54),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),

          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Pill calibration', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 10),
                  const Text(
                    'Workflow: Empty scale → Zero → Place 1 pill → Capture sample (repeat 5-6 times) → Average pill weight',
                    style: TextStyle(color: Colors.black54),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      ElevatedButton(
                        onPressed: widget.weightListenable.value == null ? null : _captureSample,
                        child: const Text('Capture sample'),
                      ),
                      const SizedBox(width: 10),
                      OutlinedButton(
                        onPressed: _cfg.pillSamplesG.isEmpty ? null : _clearSamples,
                        child: const Text('Clear samples'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text('Samples: ${_cfg.pillSamplesG.length}', style: const TextStyle(color: Colors.black54)),
                  const SizedBox(height: 6),
                  if (_cfg.pillSamplesG.isNotEmpty)
                    Wrap(
                      spacing: 8,
                      children: _cfg.pillSamplesG
                          .take(12)
                          .map((s) => Chip(label: Text('${s.toStringAsFixed(3)} g')))
                          .toList(),
                    ),
                  const SizedBox(height: 10),
                  Text(
                    'Average pill weight: ${_cfg.avgPillWeightG == null ? '(not set)' : _cfg.avgPillWeightG!.toStringAsFixed(3)} g',
                    style: const TextStyle(color: Colors.black54),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),

          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Dose settings', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _doseMgCtrl,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                    decoration: const InputDecoration(labelText: 'Target dose (mg) — optional'),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _pillCountCtrl,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: const InputDecoration(labelText: 'Target pills (count) — optional'),
                  ),
                  const SizedBox(height: 10),
                  if (pillsFromDose != null)
                    Text(
                      'Estimated pills from dose: ~$pillsFromDose (based on ${mgPerPill.toStringAsFixed(0)} mg/pill)',
                      style: const TextStyle(color: Colors.black54),
                    ),
                  if (doseWeightG != null)
                    Text(
                      'Estimated dose weight: ${doseWeightG.toStringAsFixed(3)} g (based on avg pill weight)',
                      style: const TextStyle(color: Colors.black54),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),

          ElevatedButton.icon(
            onPressed: _saveAndPop,
            icon: const Icon(Icons.save),
            label: const Text('Save changes'),
          ),
        ],
      ),
    );
  }
}