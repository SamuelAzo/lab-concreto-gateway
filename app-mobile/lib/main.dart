// Lab Concreto — App do corpo de prova (CP)
// Le o codigo (camera ou digitado) e ENVIA ao gateway ESP32 via BLE.
// Recebe de volta (BLE notify) a carga ao vivo e a ruptura, e mantem a lista
// de CPs rompidos com status de envio (nuvem x so no app). Funciona offline.
//
// Contrato BLE (igual ao firmware):
//   Service  a1b2c3d4-0001-...
//   Write CP a1b2c3d4-0003-...   (app -> ESP32)
//   Notify   a1b2c3d4-0004-...   (ESP32 -> app): "evento|kN|MPa|CP|synced"

import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

const String kServiceUuid = 'a1b2c3d4-0001-1000-8000-00805f9b34fb';
const String kCpUuid = 'a1b2c3d4-0003-1000-8000-00805f9b34fb';
const String kResultUuid = 'a1b2c3d4-0004-1000-8000-00805f9b34fb';

const Color kAccent = Color(0xFF38BDF8);

void main() => runApp(const App());

class App extends StatelessWidget {
  const App({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Lab Concreto — CP',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(colorSchemeSeed: kAccent, brightness: Brightness.dark, useMaterial3: true),
        home: const HomePage(),
      );
}

class Ruptura {
  final String cp, kN, mpa, hora;
  bool synced;
  Ruptura({required this.cp, required this.kN, required this.mpa, required this.hora, required this.synced});
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  BluetoothCharacteristic? _cpChar;
  bool _conectado = false;
  String _status = 'Procurando gateway…';
  String _cpAtual = '';          // CP carregado, aguardando ruptura
  String _cargaAtual = '—';      // kN ao vivo
  final List<Ruptura> _rompidos = [];

  @override
  void initState() {
    super.initState();
    _procurarEConectar();
  }

  // ---------------- BLE ----------------
  Future<void> _procurarEConectar() async {
    setState(() => _status = 'Procurando gateway (BLE)…');
    try {
      await FlutterBluePlus.adapterState.where((s) => s == BluetoothAdapterState.on).first;
      await FlutterBluePlus.startScan(withServices: [Guid(kServiceUuid)], timeout: const Duration(seconds: 15));
      FlutterBluePlus.scanResults.listen((results) async {
        if (results.isEmpty || _conectado) return;
        await FlutterBluePlus.stopScan();
        await _conectar(results.first.device);
      });
    } catch (e) {
      setState(() => _status = 'Erro Bluetooth: $e');
    }
  }

  Future<void> _conectar(BluetoothDevice d) async {
    setState(() => _status = 'Conectando…');
    try {
      await d.connect(timeout: const Duration(seconds: 10));
      try { await d.requestMtu(200); } catch (_) {}
      for (final s in await d.discoverServices()) {
        if (s.uuid != Guid(kServiceUuid)) continue;
        for (final c in s.characteristics) {
          if (c.uuid == Guid(kCpUuid)) _cpChar = c;
          if (c.uuid == Guid(kResultUuid)) {
            await c.setNotifyValue(true);
            c.onValueReceived.listen(_onResult);
          }
        }
      }
      d.connectionState.listen((st) {
        final on = st == BluetoothConnectionState.connected;
        if (mounted) setState(() {
          _conectado = on;
          if (!on) { _status = 'Desconectado — reconectando…'; _procurarEConectar(); }
        });
      });
      setState(() { _conectado = true; _status = 'Conectado ao gateway'; });
    } catch (e) {
      setState(() => _status = 'Falha ao conectar: $e');
    }
  }

  void _onResult(List<int> data) {
    final p = utf8.decode(data, allowMalformed: true).split('|');
    if (p.length < 3) return;
    final evento = p[0];
    final kN = p[1];
    final mpa = p[2];
    final cp = p.length > 3 ? p[3] : '';
    final synced = p.length > 4 && p[4] == '1';
    setState(() {
      _cargaAtual = kN;
      if (evento == 'ruptura') {
        _rompidos.insert(0, Ruptura(cp: cp.isEmpty ? '(sem CP)' : cp, kN: kN, mpa: mpa, hora: _hora(), synced: synced));
        _cpAtual = '';        // libera para o proximo (firmware tambem limpou)
        _cargaAtual = '—';
      }
    });
  }

  String _hora() {
    final n = DateTime.now();
    String z(int v) => v.toString().padLeft(2, '0');
    return '${z(n.hour)}:${z(n.minute)}:${z(n.second)}';
  }

  // ---------------- CP atual ----------------
  Future<void> _definirCp(String code) async {
    code = code.trim();
    if (code.isEmpty || _cpChar == null) return;
    try {
      await _cpChar!.write(utf8.encode(code), withoutResponse: true);
      setState(() => _cpAtual = code);
    } catch (e) {
      setState(() => _status = 'Erro ao enviar CP: $e');
    }
  }

  Future<void> _escanear() async {
    final code = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const ScannerPage()),
    );
    if (code != null) await _definirCp(code);
  }

  Future<void> _digitar() async {
    final ctrl = TextEditingController(text: _cpAtual);
    final code = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Digitar nº do CP'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          textInputAction: TextInputAction.done,
          decoration: const InputDecoration(hintText: 'ex.: CP-2026-001', border: OutlineInputBorder()),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text), child: const Text('OK')),
        ],
      ),
    );
    if (code != null) await _definirCp(code);
  }

  // ---------------- UI ----------------
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('🧱 Lab Concreto · v7'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Row(children: [
              Icon(_conectado ? Icons.bluetooth_connected : Icons.bluetooth_searching,
                  size: 20, color: _conectado ? Colors.greenAccent : Colors.orangeAccent),
              const SizedBox(width: 4),
              Text(_conectado ? 'online' : 'off', style: t.labelSmall),
            ]),
          ),
        ],
      ),
      body: Column(
        children: [
          if (!_conectado)
            Material(
              color: Colors.orange.withOpacity(.15),
              child: ListTile(
                dense: true,
                leading: const Icon(Icons.info_outline, color: Colors.orangeAccent),
                title: Text(_status, style: t.bodySmall),
                trailing: TextButton(onPressed: _procurarEConectar, child: const Text('Procurar')),
              ),
            ),

          // ---- CP atual + carga ----
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('CORPO DE PROVA ATUAL', style: t.labelSmall?.copyWith(letterSpacing: 1)),
                  const SizedBox(height: 4),
                  Text(_cpAtual.isEmpty ? 'aguardando…' : _cpAtual,
                      style: t.headlineSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: _cpAtual.isEmpty ? Colors.grey : Colors.white)),
                  const Divider(height: 24),
                  Row(children: [
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('Carga atual', style: t.labelSmall),
                      Text('$_cargaAtual kN', style: t.headlineMedium?.copyWith(color: kAccent, fontWeight: FontWeight.bold)),
                    ])),
                    Expanded(child: Column(children: [
                      OutlinedButton.icon(
                        onPressed: _conectado ? _escanear : null,
                        icon: const Icon(Icons.qr_code_scanner),
                        label: const Text('Escanear'),
                        style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(42)),
                      ),
                      const SizedBox(height: 6),
                      OutlinedButton.icon(
                        onPressed: _conectado ? _digitar : null,
                        icon: const Icon(Icons.keyboard),
                        label: const Text('Digitar'),
                        style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(42)),
                      ),
                    ])),
                  ]),
                ]),
              ),
            ),
          ),

          // ---- Lista de rompidos ----
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
            child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              Text('ROMPIDOS', style: t.labelMedium?.copyWith(letterSpacing: 1)),
              Text('${_rompidos.length}', style: t.labelMedium),
            ]),
          ),
          Expanded(
            child: _rompidos.isEmpty
                ? Center(child: Text('Nenhum CP rompido ainda.', style: t.bodySmall?.copyWith(color: Colors.grey)))
                : ListView.separated(
                    itemCount: _rompidos.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final r = _rompidos[i];
                      return ListTile(
                        leading: Tooltip(
                          message: r.synced ? 'Enviado à nuvem' : 'Só no app (offline)',
                          child: Icon(r.synced ? Icons.cloud_done : Icons.phone_android,
                              color: r.synced ? Colors.greenAccent : Colors.orangeAccent),
                        ),
                        title: Text(r.cp, style: const TextStyle(fontWeight: FontWeight.bold)),
                        subtitle: Text('${r.hora}  •  ${r.synced ? "nuvem" : "local"}'),
                        trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
                          Text('${r.kN} kN', style: const TextStyle(fontWeight: FontWeight.bold)),
                          Text('${r.mpa} MPa', style: TextStyle(color: Colors.green.shade300, fontSize: 12)),
                        ]),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

// ---- Tela da camera (funciona em debug no Samsung) ----
class ScannerPage extends StatefulWidget {
  const ScannerPage({super.key});
  @override
  State<ScannerPage> createState() => _ScannerPageState();
}

class _ScannerPageState extends State<ScannerPage> {
  final MobileScannerController controller = MobileScannerController();
  bool _done = false;

  @override
  void dispose() { controller.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Aponte para o código')),
      body: MobileScanner(
        controller: controller,
        fit: BoxFit.cover,
        errorBuilder: (context, error) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text('Erro da câmera: ${error.errorCode.name}\n${error.errorDetails?.message ?? ''}',
                textAlign: TextAlign.center),
          ),
        ),
        onDetect: (capture) {
          if (_done) return;
          final code = capture.barcodes.isNotEmpty ? capture.barcodes.first.rawValue : null;
          if (code != null && code.isNotEmpty) { _done = true; Navigator.of(context).pop(code); }
        },
      ),
    );
  }
}
