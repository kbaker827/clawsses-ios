# Clawsses iOS


> **🔵 Connectivity Update — May 2025**
> The glasses connection has been migrated from **raw TCP sockets / debug Wi-Fi mode** to
> **Bluetooth via the Rokid AI glasses SDK** (`pod 'RokidSDK' ~> 1.10.2`).
> No Wi-Fi port forwarding is needed. See **SDK Setup** below.

iOS companion app for [Clawsses](https://github.com/dweddepohl/clawsses) — a wearable AI interface for Rokid glasses powered by OpenClaw.

This is a faithful iOS port of the Android phone-side app. The glasses-side app still runs on the Rokid glasses hardware (which runs Android); only the phone companion app has been converted.

## Features

- **OpenClaw Gateway** — connects to your self-hosted OpenClaw server via WebSocket with Ed25519 device authentication
- **Chat streaming** — real-time AI responses with streaming deltas
- **Session management** — switch between OpenClaw sessions from your phone
- **Voice input** — OpenAI Realtime API (primary) with iOS SFSpeechRecognizer fallback
- **TTS output** — ElevenLabs text-to-speech with configurable voice
- **Glasses bridge** — forwards all messages to/from Rokid glasses over Bluetooth via RokidSDK
- **Device discovery** — lists paired Rokid glasses via `RokidMobileSDK.device.queryDeviceList()`

## Bluetooth / Glasses Connection

Glasses communicate over **Bluetooth via the Rokid AI glasses SDK** (`pod 'RokidSDK' ~> 1.10.2`).

| Mode | iOS status |
|------|-----------|
| Device discovery | ✅ `RokidMobileSDK.device.queryDeviceList()` |
| BLE data transport (send JSON / TTS) | ✅ `RokidMobileSDK.vui.sendMessage()` + `sendTts()` |
| Receive voice commands from glasses | ✅ `SDKBinderObserver.onAsrResult()` |

The old Debug Wi-Fi Mode and raw CoreBluetooth stub have been replaced by the SDK. Credentials are obtained from [account.rokid.com/#/setting/prove](https://account.rokid.com/#/setting/prove).

## SDK Setup

The glasses now connect over **Bluetooth via the Rokid AI glasses SDK** — no Wi-Fi port or TCP server needed.

The only thing left for each app is filling in the three credential constants (`kAppKey`, `kAppSecret`, `kAccessKey`) from [account.rokid.com/#/setting/prove](https://account.rokid.com/#/setting/prove), then running `pod install`.

1. **Get credentials** at <https://account.rokid.com/#/setting/prove> and paste them into `Clawsses/Glasses/GlassesConnectionManager.swift`:
   ```swift
   private let kAppKey    = "YOUR_APP_KEY"
   private let kAppSecret = "YOUR_APP_SECRET"
   private let kAccessKey = "YOUR_ACCESS_KEY"
   ```

2. **Install CocoaPods dependencies** from the repo root:
   ```bash
   pod install
   open *.xcworkspace   # always open the .xcworkspace, not .xcodeproj
   ```

3. **Pair your glasses** once in the Rokid companion app — the SDK auto-connects over Bluetooth every launch.

## Setup in Xcode

1. Clone the repo:
   ```bash
   git clone https://github.com/kbaker827/clawsses-ios.git
   cd clawsses-ios
   ```

2. Fill in your Rokid credentials in `Clawsses/Glasses/GlassesConnectionManager.swift`:
   ```swift
   private let kAppKey    = "YOUR_APP_KEY"
   private let kAppSecret = "YOUR_APP_SECRET"
   private let kAccessKey = "YOUR_ACCESS_KEY"
   ```

3. Run `pod install` to fetch RokidSDK and dependencies:
   ```bash
   pod install
   ```

4. Open the workspace (not the `.xcodeproj`):
   ```bash
   open Clawsses.xcworkspace
   ```

5. Set your Apple Developer team in **Signing & Capabilities**.

6. Build and run on a physical iPhone (iOS 17+) — Bluetooth requires real hardware.

### Required capabilities in Xcode

Go to your target → Signing & Capabilities → + Capability and add:
- Background Modes → check **Audio, AirPlay, and Picture in Picture** and **Background fetch**

## Architecture

```
OpenClaw Gateway  ←WebSocket→  Clawsses iOS  ←Bluetooth/RokidSDK→  Rokid Glasses (Android)
      │                              │                                      │
   AI agent                   OpenClawClient                        Glasses HUD app
   Chat streaming             VoiceRecognitionManager                (unchanged Android app)
   Sessions                   ElevenLabsClient
                              GlassesConnectionManager (RokidSDK)
```

### Key source files

| File | Purpose |
|------|---------|
| `Protocol/Protocol.swift` | All message types (mirrors Android `Protocol.kt`) |
| `Network/OpenClawClient.swift` | WebSocket client, Ed25519 auth, chat streaming |
| `Network/DeviceIdentity.swift` | Ed25519 keypair via CryptoKit, stored in Keychain |
| `Glasses/GlassesConnectionManager.swift` | **RokidSDK** — device discovery, send messages/TTS, receive ASR |
| `Glasses/WakeSignalManager.swift` | Wake-signal buffering for glasses standby handling |
| `Glasses/DebugGlassesServer.swift` | Legacy TCP/WebSocket debug server (superseded by RokidSDK) |
| `Voice/VoiceCommandHandler.swift` | iOS Speech framework recognition |
| `Voice/VoiceRecognitionManager.swift` | OpenAI Realtime primary + SFSpeechRecognizer fallback |
| `TTS/ElevenLabsClient.swift` | ElevenLabs REST API client |
| `TTS/TtsPlaybackManager.swift` | AVFoundation audio playback |
| `UI/MainView.swift` | Main SwiftUI screen (mirrors Android `MainScreen.kt`) |

## Configuration

All settings are in the app's Settings screen (gear icon):

- **OpenClaw Server**: host, port, and access token
- **Glasses**: Rokid SDK device picker (tap a paired device to connect)
- **Voice**: OpenAI API key and enable/disable toggle
- **TTS**: ElevenLabs API key and voice picker

## Protocol compatibility

The iOS app uses the exact same JSON wire protocol as the Android app. No changes are needed to the glasses-side Android app or the OpenClaw gateway.

## License

MIT — same as the original [Clawsses](https://github.com/dweddepohl/clawsses).
