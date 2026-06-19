# App do corpo de prova (Flutter) — câmera + BLE → ESP32

App híbrido (iPhone + Android) que **lê o código de barras do corpo de prova pela câmera** e **envia ao gateway ESP32 via BLE**. Substitui o leitor Bluetooth dedicado.

> Pré-requisito no firmware: gravar o `gateway-esp32` com **`BARCODE_BLE 1`** (e `BARCODE_BT 0`).

## Contrato BLE (igual ao firmware)
| | UUID |
|---|---|
| Service | `a1b2c3d4-0001-1000-8000-00805f9b34fb` |
| Característica (WRITE) | `a1b2c3d4-0003-1000-8000-00805f9b34fb` |

O app conecta no ESP32 (que anuncia esse serviço) e **escreve a string do código** na característica. O firmware trata como o "CP atual" e amarra na próxima ruptura.

## Como buildar

### 1. Instalar o Flutter
https://docs.flutter.dev/get-started/install (precisa do Flutter SDK; para iOS, Xcode; para Android, Android Studio/SDK).

### 2. Gerar as pastas de plataforma (mantém `lib/` e `pubspec.yaml`)
```bash
cd app-mobile
flutter create . --org com.topcon --project-name lab_concreto_cp
flutter pub get
```

### 3. Permissões (editar os arquivos gerados)

**iOS** — em `ios/Runner/Info.plist`, dentro do `<dict>`:
```xml
<key>NSCameraUsageDescription</key>
<string>Para ler o código de barras do corpo de prova.</string>
<key>NSBluetoothAlwaysUsageDescription</key>
<string>Para enviar o código ao gateway por Bluetooth.</string>
```

**Android** — em `android/app/src/main/AndroidManifest.xml`, antes de `<application>`:
```xml
<uses-permission android:name="android.permission.CAMERA"/>
<uses-permission android:name="android.permission.BLUETOOTH_SCAN" android:usesPermissionFlags="neverForLocation"/>
<uses-permission android:name="android.permission.BLUETOOTH_CONNECT"/>
<!-- Android < 12 -->
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION"/>
```
E garanta `minSdkVersion 21` (ou maior) em `android/app/build.gradle`.

### 4. Rodar / gerar
- **Android (fácil, sem conta paga):**
  ```bash
  flutter run                 # com o celular conectado por USB (depuração USB ligada)
  # ou gerar o instalável:
  flutter build apk --release # -> build/app/outputs/flutter-apk/app-release.apk
  ```
- **iOS (precisa conta Apple Developer):**
  ```bash
  open ios/Runner.xcworkspace # no Xcode: Signing & Capabilities -> seu Team
  flutter run                 # com o iPhone conectado e confiado
  ```
  Sem conta paga dá pra rodar via Xcode com provisionamento de **7 dias** (expira e precisa reinstalar). Para distribuir, use **TestFlight** (conta Apple Developer US$99/ano).

## Uso
1. Ligue o ESP32 (modo `BARCODE_BLE`). Ele anuncia o serviço BLE.
2. Abra o app → ele acha e conecta no gateway (status "Conectado ✅").
3. Toque **"Escanear corpo de prova"** → aponte a câmera no código → ele envia ao gateway.
4. Faça a ruptura → o ensaio sobe pra nuvem **com o código do CP** amarrado.

## Notas
- Um celular por vez conecta no gateway (BLE). 
- Se o app não achar o gateway: confira que o firmware está em `BARCODE_BLE 1`, o ESP32 ligado, e o Bluetooth do celular ativo.
- Fase 2 (futuro): receber a ruptura por BLE *notify* e mostrar o resultado no próprio app (100% offline, sem o painel web).
