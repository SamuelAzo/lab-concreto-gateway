// Lab Concreto — App do corpo de prova (CP)
// Le o codigo de barras pela camera e ENVIA ao gateway ESP32 via BLE.
// Funciona em iPhone e Android (Flutter). O ESP32 deve estar com BARCODE_BLE=1.
//
// Contrato BLE (igual ao firmware gateway-esp32):
//   Service        a1b2c3d4-0001-1000-8000-00805f9b34fb
//   Characteristic a1b2c3d4-0003-1000-8000-00805f9b34fb  (WRITE) <- escrevemos o codigo aqui

import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

const String kServiceUuid = 'a1b2c3d4-0001-1000-8000-00805f9b34fb';
const String kCharUuid = 'a1b2c3d4-0003-1000-8000-00805f9b34fb';

void main() => runApp(const App());

class App extends StatelessWidget {
  const App({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Lab Concreto — CP',
        theme: ThemeData(colorSchemeSeed: const Color(0xFF38BDF8), brightness: Brightness.dark, useMaterial3: true),
        home: const HomePage(),
      );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  BluetoothDevice? _device;
  BluetoothCharacteristic? _cpChar;
  String _status = 'Procurando gateway...';
  String _ultimoCp = '—';
  bool _conectado = false;

  @override
  void initState() {
    super.initState();
    _procurarEConectar();
  }

  Future<void> _procurarEConectar() async {
    setState(() => _status = 'Procurando gateway (BLE)...');
    try {
      await FlutterBluePlus.adapterState.where((s) => s == BluetoothAdapterState.on).first;
      // escaneia filtrando pelo nosso servico
      await FlutterBluePlus.startScan(
        withServices: [Guid(kServiceUuid)],
        timeout: const Duration(seconds: 15),
      );
      FlutterBluePlus.scanResults.listen((results) async {
        if (results.isEmpty || _conectado) return;
        final r = results.first;
        await FlutterBluePlus.stopScan();
        await _conectar(r.device);
      });
    } catch (e) {
      setState(() => _status = 'Erro Bluetooth: $e');
    }
  }

  Future<void> _conectar(BluetoothDevice d) async {
    setState(() => _status = 'Conectando ao ${d.platformName}...');
    try {
      await d.connect(timeout: const Duration(seconds: 10));
      final services = await d.discoverServices();
      for (final s in services) {
        if (s.uuid == Guid(kServiceUuid)) {
          for (final c in s.characteristics) {
            if (c.uuid == Guid(kCharUuid)) _cpChar = c;
          }
        }
      }
      d.connectionState.listen((st) {
        final on = st == BluetoothConnectionState.connected;
        if (mounted) setState(() { _conectado = on; if (!on) { _status = 'Desconectado — reconectando...'; _procurarEConectar(); } });
      });
      setState(() { _device = d; _conectado = true; _status = 'Conectado ao gateway ✅'; });
    } catch (e) {
      setState(() => _status = 'Falha ao conectar: $e');
    }
  }

  Future<void> _escanear() async {
    final code = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const ScannerPage()),
    );
    if (code == null || code.isEmpty) return;
    await _enviarCp(code);
  }

  Future<void> _enviarCp(String code) async {
    if (_cpChar == null) {
      setState(() => _status = 'Gateway não conectado — não enviei.');
      return;
    }
    try {
      await _cpChar!.write(utf8.encode(code), withoutResponse: true);
      setState(() { _ultimoCp = code; _status = 'CP enviado ao gateway ✅'; });
    } catch (e) {
      setState(() => _status = 'Erro ao enviar: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('🧱 Lab Concreto — CP')),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
              child: ListTile(
                leading: Icon(_conectado ? Icons.bluetooth_connected : Icons.bluetooth_searching,
                    color: _conectado ? Colors.green : Colors.orange),
                title: Text(_conectado ? 'Gateway conectado' : 'Sem gateway'),
                subtitle: Text(_status),
              ),
            ),
            const SizedBox(height: 24),
            Text('Último CP enviado', style: Theme.of(context).textTheme.labelMedium),
            Text(_ultimoCp, style: Theme.of(context).textTheme.headlineSmall),
            const Spacer(),
            FilledButton.icon(
              onPressed: _conectado ? _escanear : null,
              icon: const Icon(Icons.qr_code_scanner, size: 28),
              label: const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Text('Escanear corpo de prova', style: TextStyle(fontSize: 18)),
              ),
            ),
            const SizedBox(height: 8),
            if (!_conectado)
              TextButton(onPressed: _procurarEConectar, child: const Text('Procurar gateway de novo')),
          ],
        ),
      ),
    );
  }
}

// Tela de camera: retorna o primeiro codigo lido.
class ScannerPage extends StatefulWidget {
  const ScannerPage({super.key});
  @override
  State<ScannerPage> createState() => _ScannerPageState();
}

class _ScannerPageState extends State<ScannerPage> {
  bool _done = false;
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Aponte para o código')),
      body: MobileScanner(
        onDetect: (capture) {
          if (_done) return;
          final code = capture.barcodes.isNotEmpty ? capture.barcodes.first.rawValue : null;
          if (code != null && code.isNotEmpty) {
            _done = true;
            Navigator.of(context).pop(code);
          }
        },
      ),
    );
  }
}
