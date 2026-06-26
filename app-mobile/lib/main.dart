// Lab Concreto — App do corpo de prova (CP)  · v8
// Le o codigo (camera ou digitado) e ENVIA ao gateway ESP32 via BLE.
// Recebe de volta (BLE notify) a carga ao vivo e a ruptura, mostra o PICO,
// vibra/destaca na ruptura, calcula o MPa pela geometria escolhida e SALVA a
// lista de rompidos no celular (sobrevive a fechar o app). Funciona offline.
//
// Contrato BLE (igual ao firmware):
//   Service  a1b2c3d4-0001-...
//   Write CP a1b2c3d4-0003-...   (app -> ESP32)
//   Notify   a1b2c3d4-0004-...   (ESP32 -> app): "evento|kN|MPa|CP|synced"

import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';            // HapticFeedback (vibrar)
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:http/http.dart' as http;           // POST das rupturas pra cloud-api
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String kServiceUuid = 'a1b2c3d4-0001-1000-8000-00805f9b34fb';
const String kCpUuid = 'a1b2c3d4-0003-1000-8000-00805f9b34fb';
const String kResultUuid = 'a1b2c3d4-0004-1000-8000-00805f9b34fb';

const Color kAccent = Color(0xFF38BDF8);
const String kPrefsKey = 'rompidos_v8';
const String kPrefsDiam = 'diametro_mm';
const String kPrefsUrl = 'cloud_url';   // base da cloud-api (ex.: https://meu-host)

// geometrias comuns de CP (diametro em mm)
const Map<int, String> kGeometrias = {
  100: '10×20 (Ø100)',
  150: '15×30 (Ø150)',
  50: '5×10 (Ø50)',
};

double mpaDe(double kN, int diamMm) {
  final area = math.pi * (diamMm / 2.0) * (diamMm / 2.0); // mm²
  return area > 0 ? (kN * 1000.0) / area : 0;
}

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
  final String cp;
  final double kN;
  final int diamMm;
  final String hora;
  bool synced;
  Ruptura({required this.cp, required this.kN, required this.diamMm, required this.hora, required this.synced});

  double get mpa => mpaDe(kN, diamMm);

  Map<String, dynamic> toJson() => {'cp': cp, 'kN': kN, 'd': diamMm, 'h': hora, 's': synced};
  factory Ruptura.fromJson(Map<String, dynamic> j) => Ruptura(
        cp: j['cp'] ?? '',
        kN: (j['kN'] as num?)?.toDouble() ?? 0,
        diamMm: (j['d'] as num?)?.toInt() ?? 100,
        hora: j['h'] ?? '',
        synced: j['s'] ?? false,
      );
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
  double _cargaKN = 0;           // kN ao vivo
  double _picoKN = 0;            // maior kN do ensaio atual
  int _diametroMm = 100;         // geometria do CP (persistida)
  String _cloudUrl = '';         // base da cloud-api (vazio = sync desligado)
  bool _sincronizando = false;
  final List<Ruptura> _rompidos = [];

  int get _pendentesSync =>
      _rompidos.where((r) => !r.synced && !r.cp.startsWith('(')).length;

  @override
  void initState() {
    super.initState();
    _carregar();
    _procurarEConectar();
  }

  // ---------------- Persistência ----------------
  Future<void> _carregar() async {
    final sp = await SharedPreferences.getInstance();
    _diametroMm = sp.getInt(kPrefsDiam) ?? 100;
    _cloudUrl = sp.getString(kPrefsUrl) ?? '';
    final raw = sp.getString(kPrefsKey);
    if (raw != null) {
      try {
        final list = (jsonDecode(raw) as List).map((e) => Ruptura.fromJson(e)).toList();
        _rompidos
          ..clear()
          ..addAll(list);
      } catch (_) {}
    }
    if (mounted) setState(() {});
  }

  Future<void> _salvar() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(kPrefsKey, jsonEncode(_rompidos.map((r) => r.toJson()).toList()));
    await sp.setInt(kPrefsDiam, _diametroMm);
    await sp.setString(kPrefsUrl, _cloudUrl);
  }

  // ---------------- Sincronizar com o Topcon (via cloud-api) ----------------
  Future<void> _configurarUrl() async {
    final ctrl = TextEditingController(text: _cloudUrl);
    final url = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('URL da cloud-api'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(hintText: 'https://seu-host  (sem barra no fim)', border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: const Text('Salvar')),
        ],
      ),
    );
    if (url != null) { setState(() => _cloudUrl = url.replaceAll(RegExp(r'/+$'), '')); await _salvar(); }
  }

  Future<void> _sincronizar() async {
    if (_cloudUrl.isEmpty) { _snack('Configure a URL da cloud-api (⚙️) antes de sincronizar.'); return _configurarUrl(); }
    final pend = _rompidos.where((r) => !r.synced && !r.cp.startsWith('(')).toList();
    if (pend.isEmpty) { _snack('Nada a sincronizar.'); return; }

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Lançar no Topcon?'),
        content: Text('Enviar ${pend.length} CP(s) rompido(s) para gravar no banco.\n'
            'Só grava CP pendente — não sobrescreve valores já lançados.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Enviar')),
        ],
      ),
    );
    if (ok != true) return;

    setState(() => _sincronizando = true);
    int gravados = 0; final falhas = <String>[];
    for (final r in pend) {
      try {
        final resp = await http
            .post(Uri.parse('$_cloudUrl/api/ruptura'),
                headers: {'Content-Type': 'application/json'},
                body: jsonEncode({'cp': r.cp, 'kN': double.parse(r.kN.toStringAsFixed(1))}))
            .timeout(const Duration(seconds: 12));
        final body = jsonDecode(resp.body);
        if (resp.statusCode == 200 && body['ok'] == true) {
          r.synced = true; gravados++;
        } else {
          falhas.add('${r.cp}: ${body['motivo'] ?? body['erro'] ?? resp.statusCode}');
        }
      } catch (e) {
        falhas.add('${r.cp}: $e');
      }
    }
    await _salvar();
    if (mounted) setState(() => _sincronizando = false);
    _snack('Gravados: $gravados • Falhas: ${falhas.length}'
        '${falhas.isEmpty ? '' : '\n${falhas.take(3).join('\n')}'}');
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)..clearSnackBars()..showSnackBar(SnackBar(content: Text(msg)));
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
    final kN = double.tryParse(p[1]) ?? 0;
    final cp = p.length > 3 ? p[3] : '';
    final synced = p.length > 4 && p[4] == '1';
    setState(() {
      _cargaKN = kN;
      if (kN > _picoKN) _picoKN = kN;
      if (evento == 'ruptura') {
        final r = Ruptura(
          cp: cp.isEmpty ? '(sem CP)' : cp,
          kN: kN,                      // o firmware ja manda o PICO no evento ruptura
          diamMm: _diametroMm,
          hora: _hora(),
          synced: synced,
        );
        _rompidos.insert(0, r);
        _cpAtual = '';
        _cargaKN = 0;
        _picoKN = 0;
        HapticFeedback.heavyImpact();   // vibra ao romper
        _avisarRuptura(r);
        _salvar();
      }
    });
  }

  void _avisarRuptura(Ruptura r) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
        backgroundColor: Colors.green.shade700,
        duration: const Duration(seconds: 4),
        content: Text('💥 Rompido: ${r.cp}  •  ${r.kN.toStringAsFixed(1)} kN  •  ${r.mpa.toStringAsFixed(1)} MPa',
            style: const TextStyle(fontWeight: FontWeight.bold)),
      ));
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
      setState(() { _cpAtual = code; _picoKN = 0; });
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
          decoration: const InputDecoration(hintText: 'ex.: 12345', border: OutlineInputBorder()),
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

  Future<void> _apagarRuptura(int i) async {
    setState(() => _rompidos.removeAt(i));
    await _salvar();
  }

  // ---------------- UI ----------------
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('🧱 Lab Concreto · v9'),
        actions: [
          // sincronizar com o Topcon (grava rupturas no MySQL via cloud-api)
          Stack(alignment: Alignment.center, children: [
            IconButton(
              tooltip: 'Sincronizar com o Topcon',
              icon: _sincronizando
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.cloud_upload),
              onPressed: _sincronizando ? null : _sincronizar,
            ),
            if (_pendentesSync > 0 && !_sincronizando)
              Positioned(
                right: 6, top: 6,
                child: Container(
                  padding: const EdgeInsets.all(3),
                  decoration: const BoxDecoration(color: Colors.orange, shape: BoxShape.circle),
                  constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
                  child: Text('$_pendentesSync', textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
                ),
              ),
          ]),
          IconButton(tooltip: 'URL da cloud-api', icon: const Icon(Icons.settings), onPressed: _configurarUrl),
          // seletor de geometria (Ø do CP)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: DropdownButton<int>(
              value: _diametroMm,
              underline: const SizedBox.shrink(),
              dropdownColor: const Color(0xFF1e293b),
              icon: const Icon(Icons.straighten, size: 18),
              items: kGeometrias.entries
                  .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value, style: t.labelMedium)))
                  .toList(),
              onChanged: (v) { if (v != null) { setState(() => _diametroMm = v); _salvar(); } },
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Row(children: [
              Icon(_conectado ? Icons.bluetooth_connected : Icons.bluetooth_searching,
                  size: 20, color: _conectado ? Colors.greenAccent : Colors.orangeAccent),
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

          // ---- CP atual + carga ao vivo + pico ----
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                    Text('CORPO DE PROVA ATUAL', style: t.labelSmall?.copyWith(letterSpacing: 1)),
                    Text(kGeometrias[_diametroMm] ?? '', style: t.labelSmall?.copyWith(color: kAccent)),
                  ]),
                  const SizedBox(height: 4),
                  Text(_cpAtual.isEmpty ? 'aguardando…' : _cpAtual,
                      style: t.headlineSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: _cpAtual.isEmpty ? Colors.grey : Colors.white)),
                  const Divider(height: 24),
                  Row(children: [
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('Carga atual', style: t.labelSmall),
                      Text('${_cargaKN.toStringAsFixed(1)} kN',
                          style: t.headlineMedium?.copyWith(color: kAccent, fontWeight: FontWeight.bold)),
                      Text('${mpaDe(_cargaKN, _diametroMm).toStringAsFixed(1)} MPa', style: t.bodySmall),
                    ])),
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('Pico', style: t.labelSmall),
                      Text('${_picoKN.toStringAsFixed(1)} kN',
                          style: t.headlineMedium?.copyWith(color: Colors.amber, fontWeight: FontWeight.bold)),
                      Text('${mpaDe(_picoKN, _diametroMm).toStringAsFixed(1)} MPa', style: t.bodySmall),
                    ])),
                  ]),
                  const SizedBox(height: 12),
                  Row(children: [
                    Expanded(child: OutlinedButton.icon(
                      onPressed: _conectado ? _escanear : null,
                      icon: const Icon(Icons.qr_code_scanner),
                      label: const Text('Escanear'),
                      style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(44)),
                    )),
                    const SizedBox(width: 8),
                    Expanded(child: OutlinedButton.icon(
                      onPressed: _conectado ? _digitar : null,
                      icon: const Icon(Icons.keyboard),
                      label: const Text('Digitar'),
                      style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(44)),
                    )),
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
                      return Dismissible(
                        key: ValueKey('${r.cp}-${r.hora}-$i'),
                        direction: DismissDirection.endToStart,
                        background: Container(
                          color: Colors.red.shade900,
                          alignment: Alignment.centerRight,
                          padding: const EdgeInsets.only(right: 20),
                          child: const Icon(Icons.delete),
                        ),
                        onDismissed: (_) => _apagarRuptura(i),
                        child: ListTile(
                          leading: Tooltip(
                            message: r.synced ? 'Enviado à nuvem' : 'Só no app (offline)',
                            child: Icon(r.synced ? Icons.cloud_done : Icons.phone_android,
                                color: r.synced ? Colors.greenAccent : Colors.orangeAccent),
                          ),
                          title: Text(r.cp, style: const TextStyle(fontWeight: FontWeight.bold)),
                          subtitle: Text('${r.hora}  •  ${kGeometrias[r.diamMm] ?? "Ø${r.diamMm}"}'),
                          trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
                            Text('${r.kN.toStringAsFixed(1)} kN', style: const TextStyle(fontWeight: FontWeight.bold)),
                            Text('${r.mpa.toStringAsFixed(1)} MPa', style: TextStyle(color: Colors.green.shade300, fontSize: 12)),
                          ]),
                        ),
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
