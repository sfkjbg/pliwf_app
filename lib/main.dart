import 'package:flutter/material.dart';
import 'ble_slot_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const HiveApp());
}

class HiveApp extends StatelessWidget {
  const HiveApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'HIVE',
      home: BleSlotPage(),
    );
  }
}
