import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';


// BLE UUIDs (keep for when electronics are ready)
final Guid svcUuid = Guid("7d2a0a5d-7c7a-4e8b-8cb4-2f2cf6b5b201");
final Guid chUuid  = Guid("7d2a0a5d-7c7a-4e8b-8cb4-2f2cf6b5b202");

int _i16le(Uint8List b, int o) => (b[o] | (b[o + 1] << 8)) << 16 >> 16;
int _u16le(Uint8List b, int o) => (b[o] | (b[o + 1] << 8));

/// Parsed payload from the ESP32 notification.
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

/// App-level view model per slot.
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
    if (unexpected) return 'Unexpected change';
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

/// Demo event record for the UI.
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

class BleSlotPage extends StatefulWidget {
  const BleSlotPage({super.key});
  @override
  State<BleSlotPage> createState() => _BleSlotPageState();
}

class _BleSlotPageState extends State<BleSlotPage> {
  // ----------------- UI state -----------------
  bool demoMode = true; // default ON since you don't have electronics connected
  bool scanning = false;

  // ----------------- BLE state (kept for later) -----------------
  BluetoothDevice? device;
  BluetoothCharacteristic? notifyChar;

  // Scan + connection state
  final List<ScanResult> _scanResults = [];
  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<BluetoothConnectionState>? _connSub;
  BluetoothConnectionState _connState = BluetoothConnectionState.disconnected;

  // ----------------- Demo data -----------------
  final _rng = Random();
  Timer? _demoTimer;

  // A small hive: 5 slots demo
  final Map<int, SlotView> _slots = {};
  final List<EventView> _events = [];

  @override
  void initState() {
    super.initState();
    _initDemoData();
    _startDemo();
  }

  @override
  void dispose() {
    _demoTimer?.cancel();
    _scanSub?.cancel();
    _connSub?.cancel();
    try {
      device?.disconnect();
    } catch (_) {}
    super.dispose();
  }

  void _initDemoData() {
    final now = DateTime.now();

    // flags bitfield: bit0 TAKEN, bit1 REMOVED, bit2 UNEXPECTED, bit3 STABLE
    _slots.clear();
    _events.clear();

    _slots[1] = SlotView(
      slotId: 1,
      name: 'Slot 1',
      med: 'Vitamin D3',
      dose: '1 / day',
      weightG: 134.2,
      baselineG: 134.2,
      deltaG: 0.0,
      flags: (1 << 3),
      lastUpdate: now,
    );

    _slots[2] = SlotView(
      slotId: 2,
      name: 'Slot 2',
      med: 'Metformin 500mg',
      dose: '2 / day',
      weightG: 212.7,
      baselineG: 213.0,
      deltaG: -0.3,
      flags: (1 << 0) | (1 << 3),
      lastUpdate: now,
    );

    _slots[3] = SlotView(
      slotId: 3,
      name: 'Slot 3',
      med: 'Blood Pressure',
      dose: '1 / day',
      weightG: 178.1,
      baselineG: 178.1,
      deltaG: 0.0,
      flags: (1 << 3),
      lastUpdate: now,
    );

    _slots[4] = SlotView(
      slotId: 4,
      name: 'Slot 4',
      med: 'Allergy',
      dose: 'As needed',
      weightG: 98.4,
      baselineG: 108.4,
      deltaG: -10.0,
      flags: (1 << 1),
      lastUpdate: now,
    );

    _slots[5] = SlotView(
      slotId: 5,
      name: 'Slot 5',
      med: 'Omega-3',
      dose: '1 / day',
      weightG: 156.0,
      baselineG: 156.5,
      deltaG: -0.5,
      flags: (1 << 2) | (1 << 3),
      lastUpdate: now,
    );

    _events.addAll([
      EventView(
        ts: now.subtract(const Duration(minutes: 12)),
        slotId: 2,
        title: 'Dose taken',
        detail: 'Metformin 500mg (Δ -0.300g)',
      ),
      EventView(
        ts: now.subtract(const Duration(minutes: 34)),
        slotId: 4,
        title: 'Bottle removed',
        detail: 'Allergy bottle missing',
      ),
      EventView(
        ts: now.subtract(const Duration(hours: 2, minutes: 5)),
        slotId: 5,
        title: 'Unexpected change',
        detail: 'Omega-3 (Δ -0.500g)',
      ),
    ]);
  }

  void _startDemo() {
    _demoTimer?.cancel();
    if (!demoMode) return;

    // Update demo data every ~3 seconds so the UI feels alive.
    _demoTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      final now = DateTime.now();

      // randomly pick a slot to wiggle
      final ids = _slots.keys.toList();
      if (ids.isEmpty) return;
      final id = ids[_rng.nextInt(ids.length)];
      final s = _slots[id]!;

      // small random noise
      final noise = (_rng.nextDouble() - 0.5) * 0.04; // +/- 0.02g
      double newWeight = (s.weightG + noise);
      double newBase = s.baselineG;
      int newFlags = (1 << 3); // stable

      // 10% chance: simulate taken
      if (_rng.nextDouble() < 0.10) {
        newWeight = s.weightG - 0.300;
        newBase = newWeight;
        newFlags = (1 << 0) | (1 << 3);
        _events.insert(
          0,
          EventView(
            ts: now,
            slotId: s.slotId,
            title: 'Dose taken',
            detail: '${s.med} (Δ -0.300g)',
          ),
        );
      }

      // 5% chance: simulate removed
      if (_rng.nextDouble() < 0.05) {
        newWeight = max(0, s.weightG - 15.0);
        newFlags = (1 << 1);
        _events.insert(
          0,
          EventView(
            ts: now,
            slotId: s.slotId,
            title: 'Bottle removed',
            detail: '${s.med} bottle removed',
          ),
        );
      }

      // cap events list
      if (_events.length > 30) {
        _events.removeRange(30, _events.length);
      }

      final updated = SlotView(
        slotId: s.slotId,
        name: s.name,
        med: s.med,
        dose: s.dose,
        weightG: newWeight,
        baselineG: newBase,
        deltaG: newWeight - newBase,
        flags: newFlags,
        lastUpdate: now,
      );

      setState(() {
        _slots[id] = updated;
      });
    });
  }

  // ----------------- BLE methods -----------------
Future<bool> _ensureBlePermissions() async {
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

Future<void> _startBle() async {
  final ok = await _ensureBlePermissions();
  if (!ok) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Bluetooth permissions denied')),
    );
    return;
  }

  await FlutterBluePlus.turnOn();
  await _startScan();
}

Future<void> _startScan() async {
  final ok = await _ensureBlePermissions();
  if (!ok) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Bluetooth permissions denied')),
    );
    return;
  }

  _scanResults.clear();
  await FlutterBluePlus.stopScan();

    setState(() => scanning = true);

    _scanSub?.cancel();
    _scanSub = FlutterBluePlus.scanResults.listen((results) {
      // De-dupe by device id
      for (final r in results) {
        final exists = _scanResults.any((e) => e.device.remoteId == r.device.remoteId);
        if (!exists) {
          setState(() => _scanResults.add(r));
        }
      }
    });

    // Scan WITHOUT filters (many ESP32 sketches do NOT advertise service UUIDs).
    await FlutterBluePlus.startScan(timeout: const Duration(seconds: 6));

    await Future.delayed(const Duration(seconds: 6));
    await FlutterBluePlus.stopScan();
    if (mounted) setState(() => scanning = false);
  }

  Future<void> _disconnect() async {
    _connSub?.cancel();
    _connSub = null;
    try {
      await device?.disconnect();
    } catch (_) {}
    setState(() {
      device = null;
      notifyChar = null;
      _connState = BluetoothConnectionState.disconnected;
    });
  }

  Future<void> _connectTo(ScanResult r) async {
    final d = r.device;

    // Stop scanning while we connect
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {}

    setState(() {
      scanning = false;
      device = d;
      notifyChar = null;
      _connState = BluetoothConnectionState.connecting;
    });

    // Always reset old connection if any
    try {
      await d.disconnect();
    } catch (_) {}

    await d.connect(timeout: const Duration(seconds: 12), autoConnect: false);

    _connSub?.cancel();
    _connSub = d.connectionState.listen((state) {
      if (!mounted) return;
      setState(() => _connState = state);
    });

    // Discover services and only subscribe if our UUIDs exist
    final services = await d.discoverServices();
    final hasSvc = services.any((s) => s.uuid == svcUuid);

    if (!hasSvc) {
      // Connected, but not our firmware/service.
      setState(() {
        notifyChar = null;
      });
      return;
    }

    await _connectAndSubscribe(d, services: services);
  }

  Future<void> _connectAndSubscribe(
    BluetoothDevice d, {
    List<BluetoothService>? services,
  }) async {
    final svcs = services ?? await d.discoverServices();

    final svc = svcs.firstWhere((s) => s.uuid == svcUuid);
    notifyChar = svc.characteristics.firstWhere((c) => c.uuid == chUuid);

    await notifyChar!.setNotifyValue(true);

    notifyChar!.onValueReceived.listen((value) {
      final pkt = SlotPacket.parse(Uint8List.fromList(value));
      if (pkt == null) return;

      final now = DateTime.now();

      // Translate packet into a slot card. Since you don’t have a real model yet,
      // we’ll map slotId -> default labels if not present.
      final prev = _slots[pkt.slotId];
      final name = prev?.name ?? 'Slot ${pkt.slotId}';
      final med = prev?.med ?? 'Unknown med';
      final dose = prev?.dose ?? '—';

      final weight = pkt.weightG;
      final base = pkt.baseG;
      final delta = weight - base;

      final updated = SlotView(
        slotId: pkt.slotId,
        name: name,
        med: med,
        dose: dose,
        weightG: weight,
        baselineG: base,
        deltaG: delta,
        flags: pkt.flags,
        lastUpdate: now,
      );

      setState(() {
        _slots[pkt.slotId] = updated;
      });

      // Create an event record for the feed when an event flag is set.
      if ((pkt.flags & (1 << 0)) != 0) {
        _events.insert(
          0,
          EventView(
            ts: now,
            slotId: pkt.slotId,
            title: 'Dose taken',
            detail: '$med (Δ ${(pkt.deltaMg / 1000.0).toStringAsFixed(3)}g)',
          ),
        );
      } else if ((pkt.flags & (1 << 1)) != 0) {
        _events.insert(
          0,
          EventView(
            ts: now,
            slotId: pkt.slotId,
            title: 'Bottle removed',
            detail: '$med bottle removed',
          ),
        );
      } else if ((pkt.flags & (1 << 2)) != 0) {
        _events.insert(
          0,
          EventView(
            ts: now,
            slotId: pkt.slotId,
            title: 'Unexpected change',
            detail: '$med (Δ ${(pkt.deltaMg / 1000.0).toStringAsFixed(3)}g)',
          ),
        );
      }

      if (_events.length > 30) {
        setState(() => _events.removeRange(30, _events.length));
      }
    });

    setState(() {});
  }

  // ----------------- UI helpers -----------------
  String _flagsText(int f) {
    final parts = <String>[];
    if ((f & (1 << 0)) != 0) parts.add("TAKEN");
    if ((f & (1 << 1)) != 0) parts.add("REMOVED");
    if ((f & (1 << 2)) != 0) parts.add("UNEXPECTED");
    if ((f & (1 << 3)) != 0) parts.add("STABLE");
    return parts.isEmpty ? "-" : parts.join(", ");
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

  @override
  Widget build(BuildContext context) {
    final slotsSorted = _slots.values.toList()..sort((a, b) => a.slotId.compareTo(b.slotId));

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
                    // stop BLE when entering demo
                    try {
                      await FlutterBluePlus.stopScan();
                    } catch (_) {}
                    try {
                      await device?.disconnect();
                    } catch (_) {}
                    device = null;
                    notifyChar = null;
                    scanning = false;
                    _initDemoData();
                    _startDemo();
                  } else {
                    _demoTimer?.cancel();
                    setState(() {
                      _scanResults.clear();
                      _connState = BluetoothConnectionState.disconnected;
                    });
                    await _startBle();
                  }
                },
              ),
              const SizedBox(width: 8),
            ],
          )
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _summaryCard(slotsSorted),
          const SizedBox(height: 12),
          Text(
            'Slots',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          ...slotsSorted.map(_slotCard),
          const SizedBox(height: 16),
          Text(
            'Recent events',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          _eventsCard(),
          const SizedBox(height: 24),
          Text(
            'BLE debug',
            style: Theme.of(context).textTheme.titleLarge,
          ),
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
            Text(
              'Hive status',
              style: Theme.of(context).textTheme.titleMedium,
            ),
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
                  : (scanning ? 'Scanning for devices…' : 'Listening for notifications…'),
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
    return Card(
      child: ListTile(
        leading: Icon(s.statusIcon, color: color),
        title: Text('${s.name} — ${s.med}'),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 4),
            Text('${s.statusText} • ${_timeAgo(s.lastUpdate)}'),
            const SizedBox(height: 6),
            Wrap(
              spacing: 10,
              runSpacing: 6,
              children: [
                _kv('Dose', s.dose),
                _kv('Weight', '${s.weightG.toStringAsFixed(1)} g'),
                _kv('Baseline', '${s.baselineG.toStringAsFixed(1)} g'),
                _kv('Δ', '${s.deltaG.toStringAsFixed(3)} g'),
                _kv('Flags', _flagsText(s.flags)),
              ],
            )
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
          children: _events.take(12).map((e) {
            return ListTile(
              dense: true,
              leading: CircleAvatar(
                radius: 16,
                child: Text(e.slotId.toString()),
              ),
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

    String deviceName = device?.platformName ?? '';
    if (deviceName.isEmpty) deviceName = '(unknown)';

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('BLE mode: ${demoMode ? 'Demo (no BLE)' : 'BLE'}'),
            const SizedBox(height: 6),
            Text('Connection: ${_connState.name}'),
            const SizedBox(height: 6),
            Text('Device: ${device == null ? '(none)' : deviceName}'),
            const SizedBox(height: 10),

            if (demoMode)
              const Text('Flip the Demo switch OFF when your ESP32 is ready.')
            else ...[
              Row(
                children: [
                  ElevatedButton(
                    onPressed: scanning ? null : _startScan,
                    child: Text(scanning ? 'Scanning…' : 'Scan'),
                  ),
                  const SizedBox(width: 10),
                  if (connected || connecting)
                    OutlinedButton(
                      onPressed: _disconnect,
                      child: const Text('Disconnect'),
                    ),
                ],
              ),
              const SizedBox(height: 10),

              if (connected && notifyChar != null)
                const Text('Subscribed: YES (receiving notifications)')
              else if (connected && notifyChar == null)
                const Text('Connected, but PILWF service not found on this device.')
              else
                const SizedBox.shrink(),

              const SizedBox(height: 10),
              const Text('Discovered devices:'),
              const SizedBox(height: 6),

              if (_scanResults.isEmpty)
                const Text('— none yet (tap Scan)')
              else
                Column(
                  children: _scanResults.take(8).map((r) {
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