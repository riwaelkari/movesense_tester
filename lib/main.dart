// main.dart
// Minimal Flutter Movesense tester (raw GSP over BLE)
//
// Add to pubspec.yaml:
// dependencies:
//   flutter:
//     sdk: flutter
//   flutter_blue_plus: ^2.2.1
//
// Android notes:
// - minSdkVersion should be >= 21
// - add Bluetooth permissions for Android 12+ and location permission for older Androids
// - test on a real Android phone, not an emulator
// 2) Connect
// 3) Discover the official Movesense GSP service
// 4) Subscribe to notify characteristic
// 5) Send HELLO command
// 6) Optionally send GET /Info, GET /Meas/ECG/Info, SUBSCRIBE /Meas/HR, SUBSCRIBE /Meas/ECG/125/mV
//
// Important honesty note:
// - HELLO is parsed here.
// - Command responses are partially parsed.
// - Streaming DATA packets are displayed as hex + ASCII preview.
// - Full decoding of ECG/HR payloads requires SBEM parsing / schema-aware decoding,
//   which should be added next after we capture real packets from your device.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MovesenseTesterApp());
}

class MovesenseTesterApp extends StatelessWidget {
  const MovesenseTesterApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Movesense Tester',
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.teal),
      home: const MovesenseHomePage(),
    );
  }
}

class MovesenseHomePage extends StatefulWidget {
  const MovesenseHomePage({super.key});

  @override
  State<MovesenseHomePage> createState() => _MovesenseHomePageState();
}

class _MovesenseHomePageState extends State<MovesenseHomePage> {
  static final Guid gspServiceUuid = Guid(
    '34802252-7185-4d5d-b431-630e7050e8f0',
  );
  static final Guid gspWriteUuid = Guid('34800001-7185-4d5d-b431-630e7050e8f0');
  static final Guid gspNotifyUuid = Guid(
    '34800002-7185-4d5d-b431-630e7050e8f0',
  );

  final Map<String, ScanResult> _scanResults = {};
  final List<String> _logs = [];

  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<BluetoothConnectionState>? _connStateSub;
  StreamSubscription<List<int>>? _notifySub;

  BluetoothDevice? _device;
  BluetoothCharacteristic? _writeChar;
  BluetoothCharacteristic? _notifyChar;
  BluetoothCharacteristic? _hrChar;

  bool _isScanning = false;
  bool _isConnected = false;
  int _nextRef = 1;

  @override
  void initState() {
    super.initState();
    _log('App started');
  }

  @override
  void dispose() {
    _scanSub?.cancel();
    _connStateSub?.cancel();
    _notifySub?.cancel();
    super.dispose();
  }

  void _log(String message) {
    final stamp = DateTime.now().toIso8601String().substring(11, 19);
    setState(() {
      _logs.insert(0, '[$stamp] $message');
    });
  }

  Future<void> _startScan() async {
    if (_isScanning) return;

    final adapterState = await FlutterBluePlus.adapterState.first;
    _log('Adapter state before scan: $adapterState');

    if (adapterState != BluetoothAdapterState.on) {
      _log('Bluetooth is not ON, scan aborted');
      return;
    }

    _log('Starting BLE scan...');
    _scanResults.clear();
    setState(() => _isScanning = true);

    await _scanSub?.cancel();
    await FlutterBluePlus.stopScan();

    _scanSub = FlutterBluePlus.scanResults.listen(
      (results) {
        for (final r in results) {
          final name = r.device.platformName.trim();
          if (name.toLowerCase().contains('movesense')) {
            _scanResults[r.device.remoteId.str] = r;
            _log(
              'FOUND name="${r.device.platformName}" '
              'id=${r.device.remoteId.str} rssi=${r.rssi}',
            );
          }
        }
        if (mounted) setState(() {});
      },
      onError: (e) {
        _log('scanResults stream error: $e');
      },
    );

    try {
      await FlutterBluePlus.startScan(
        timeout: const Duration(seconds: 8),
        androidUsesFineLocation: true,
      );
      _log('startScan call succeeded');
    } catch (e) {
      _log('startScan failed: $e');
      setState(() => _isScanning = false);
      return;
    }

    Future.delayed(const Duration(seconds: 8), () {
      if (!mounted) return;
      setState(() => _isScanning = false);
      _log('Scan finished. Found ${_scanResults.length} device(s).');
    });
  }

  Future<void> _stopScan() async {
    await FlutterBluePlus.stopScan();
    await _scanSub?.cancel();
    setState(() => _isScanning = false);
    _log('Scan stopped');
  }

  Future<void> _connect(BluetoothDevice device) async {
    try {
      await _stopScan();
      _log('Connecting to ${device.platformName} (${device.remoteId.str})');

      _device = device;
      _writeChar = null;
      _notifyChar = null;
      _hrChar = null;

      _connStateSub?.cancel();
      _connStateSub = device.connectionState.listen((state) {
        final connected = state == BluetoothConnectionState.connected;
        setState(() => _isConnected = connected);
        _log('Connection state: $state');
      });

      await device.connect(
        license: License.free,
        timeout: const Duration(seconds: 12),
      );

      final services = await device.discoverServices();
      _log('Discovered ${services.length} service(s)');

      for (final service in services) {
        _log('SERVICE ${service.uuid}');
        for (final c in service.characteristics) {
          _log(
            '  CHAR ${c.uuid} '
            'read=${c.properties.read} '
            'write=${c.properties.write} '
            'writeNoResp=${c.properties.writeWithoutResponse} '
            'notify=${c.properties.notify}',
          );
        }
      }

      for (final service in services) {
        final serviceUuid = service.uuid.toString().toLowerCase();

        if (serviceUuid == '0000180d-0000-1000-8000-00805f9b34fb' ||
            serviceUuid == '180d') {
          for (final c in service.characteristics) {
            final charUuid = c.uuid.toString().toLowerCase();

            if (charUuid == '00002a37-0000-1000-8000-00805f9b34fb' ||
                charUuid == '2a37') {
              _hrChar = c;
            }
          }
        }
      }

      if (_hrChar == null) {
        _log(
          'ERROR: Could not find Heart Rate Measurement characteristic (2A37)',
        );
        return;
      }

      await _notifySub?.cancel();
      await _hrChar!.setNotifyValue(true);
      _notifySub = _hrChar!.lastValueStream.listen((data) {
        if (data.isNotEmpty) {
          _handleNotification(data);
        }
      });

      _log('Connected and HR notification ready');
    } catch (e) {
      _log('Connect error: $e');
    }
  }

  Future<void> _disconnect() async {
    try {
      await _notifySub?.cancel();
      _notifySub = null;
      if (_device != null) {
        await _device!.disconnect();
      }
      _writeChar = null;
      _notifyChar = null;
      setState(() => _isConnected = false);
      _log('Disconnected');
    } catch (e) {
      _log('Disconnect error: $e');
    }
  }

  int _ref() {
    final value = _nextRef & 0xFF;
    _nextRef = (_nextRef + 1) & 0xFF;
    if (_nextRef == 0) _nextRef = 1;
    return value;
  }

  Uint8List _helloPacket(int ref) {
    // HELLO command id = 0, ref = chosen byte
    return Uint8List.fromList([0x00, ref]);
  }

  Uint8List _subscribePacket(int ref, String path) {
    final pathBytes = utf8.encode(path);
    return Uint8List.fromList([0x01, ref, ...pathBytes]);
  }

  Uint8List _unsubscribePacket(int ref) {
    return Uint8List.fromList([0x02, ref]);
  }

  Uint8List _getPacket(int ref, String path) {
    final pathBytes = utf8.encode(path);
    return Uint8List.fromList([0x04, ref, ...pathBytes]);
  }

  Future<void> _write(Uint8List bytes) async {
    if (_writeChar == null) {
      _log('ERROR: write characteristic is null');
      return;
    }
    await _writeChar!.write(bytes, withoutResponse: false);
    _log('TX ${_hex(bytes)}');
  }

  Future<void> _sendHello() async {
    final ref = _ref();
    await _write(_helloPacket(ref));
  }

  Future<void> _sendGetInfo() async {
    final ref = _ref();
    await _write(_getPacket(ref, '/Info'));
  }

  Future<void> _sendGetEcgInfo() async {
    final ref = _ref();
    await _write(_getPacket(ref, '/Meas/ECG/Info'));
  }

  Future<void> _sendGetHrInfo() async {
    final ref = _ref();
    await _write(_getPacket(ref, '/Meas/HR/Info'));
  }

  Future<void> _subscribeHr() async {
    final ref = _ref();
    await _write(_subscribePacket(ref, '/Meas/HR'));
    _log('Requested SUBSCRIBE /Meas/HR with ref=$ref');
  }

  Future<void> _subscribeEcgMv125() async {
    final ref = _ref();
    await _write(_subscribePacket(ref, '/Meas/ECG/125/mV'));
    _log('Requested SUBSCRIBE /Meas/ECG/125/mV with ref=$ref');
  }

  Future<void> _subscribeAcc13() async {
    final ref = _ref();
    await _write(_subscribePacket(ref, '/Meas/Acc/13'));
    _log('Requested SUBSCRIBE /Meas/Acc/13 with ref=$ref');
  }

  void _handleNotification(List<int> data) {
    if (data.isEmpty) return;

    // Standard BLE Heart Rate Measurement parsing
    // Byte 0 = flags
    // If bit0 == 0 => HR is uint8 at byte 1
    // If bit0 == 1 => HR is uint16 at bytes 1-2
    if (_hrChar != null) {
      try {
        final flags = data[0];
        final isUint16 = (flags & 0x01) != 0;

        int hr;
        if (isUint16) {
          if (data.length < 3) {
            _log('HR packet too short: ${_hex(data)}');
            return;
          }
          hr = data[1] | (data[2] << 8);
        } else {
          if (data.length < 2) {
            _log('HR packet too short: ${_hex(data)}');
            return;
          }
          hr = data[1];
        }

        _log('HR = $hr bpm   raw=${_hex(data)}');
        return;
      } catch (e) {
        _log('HR parse error: $e   raw=${_hex(data)}');
        return;
      }
    }

    _log('RX UNKNOWN ${_hex(data)}');
  }

  void _parseCommandResponse(List<int> data) {
    if (data.length < 4) {
      _log('RX malformed response: ${_hex(data)}');
      return;
    }

    final ref = data[1];
    final status = data[2] | (data[3] << 8);
    final payload = data.sublist(4);

    // HELLO response payload contains null-terminated strings after protocol version.
    if (payload.isNotEmpty && payload[0] == 0x01) {
      final strings = _decodeNullTerminatedStrings(payload.sublist(1));
      _log('RX HELLO ref=$ref status=$status protocol=1 fields=$strings');
      return;
    }

    _log(
      'RX RESPONSE ref=$ref status=$status payloadHex=${_hex(payload)} ascii=${_asciiPreview(payload)}',
    );
  }

  List<String> _decodeNullTerminatedStrings(List<int> bytes) {
    final out = <String>[];
    final current = <int>[];
    for (final b in bytes) {
      if (b == 0) {
        out.add(utf8.decode(current, allowMalformed: true));
        current.clear();
      } else {
        current.add(b);
      }
    }
    if (current.isNotEmpty) {
      out.add(utf8.decode(current, allowMalformed: true));
    }
    return out;
  }

  String _hex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');

  String _asciiPreview(List<int> bytes) {
    return bytes
        .map((b) => (b >= 32 && b <= 126) ? String.fromCharCode(b) : '.')
        .join();
  }

  @override
  Widget build(BuildContext context) {
    final devices = _scanResults.values.toList()
      ..sort((a, b) => (b.rssi).compareTo(a.rssi));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Movesense Tester'),
        actions: [
          IconButton(
            onPressed: _isScanning ? _stopScan : _startScan,
            icon: Icon(_isScanning ? Icons.stop : Icons.search),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: _isScanning ? null : _startScan,
                  icon: const Icon(Icons.search),
                  label: const Text('Scan'),
                ),
                OutlinedButton(
                  onPressed: _isConnected ? _sendHello : null,
                  child: const Text('HELLO'),
                ),
                OutlinedButton(
                  onPressed: _isConnected ? _sendGetInfo : null,
                  child: const Text('GET /Info'),
                ),
                OutlinedButton(
                  onPressed: _isConnected ? _sendGetEcgInfo : null,
                  child: const Text('GET ECG Info'),
                ),
                OutlinedButton(
                  onPressed: _isConnected ? _sendGetHrInfo : null,
                  child: const Text('GET HR Info'),
                ),
                OutlinedButton(
                  onPressed: _isConnected ? _subscribeHr : null,
                  child: const Text('SUB /Meas/HR'),
                ),
                OutlinedButton(
                  onPressed: _isConnected ? _subscribeEcgMv125 : null,
                  child: const Text('SUB ECG 125 mV'),
                ),
                OutlinedButton(
                  onPressed: _isConnected ? _subscribeAcc13 : null,
                  child: const Text('SUB Acc 13'),
                ),
                OutlinedButton(
                  onPressed: _isConnected ? _disconnect : null,
                  child: const Text('Disconnect'),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: Row(
              children: [
                Expanded(
                  flex: 1,
                  child: Column(
                    children: [
                      const ListTile(title: Text('Discovered devices')),
                      Expanded(
                        child: ListView.builder(
                          itemCount: devices.length,
                          itemBuilder: (context, index) {
                            final result = devices[index];
                            return ListTile(
                              leading: const Icon(Icons.bluetooth),
                              title: Text(
                                result.device.platformName.isEmpty
                                    ? 'Unnamed device'
                                    : result.device.platformName,
                              ),
                              subtitle: Text(
                                '${result.device.remoteId.str}\nRSSI ${result.rssi}',
                              ),
                              isThreeLine: true,
                              trailing: ElevatedButton(
                                onPressed: () => _connect(result.device),
                                child: const Text('Connect'),
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
                const VerticalDivider(width: 1),
                Expanded(
                  flex: 1,
                  child: Column(
                    children: [
                      const ListTile(title: Text('Logs')),
                      Expanded(
                        child: Container(
                          color: Colors.black,
                          child: ListView.builder(
                            reverse: true,
                            itemCount: _logs.length,
                            itemBuilder: (context, index) {
                              return Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 4,
                                ),
                                child: SelectableText(
                                  _logs[index],
                                  style: const TextStyle(
                                    color: Colors.greenAccent,
                                    fontFamily: 'monospace',
                                    fontSize: 12,
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
