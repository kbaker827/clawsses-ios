# Clawsses iOS


> **🔵 Connectivity Update — May 2025**
> The glasses connection has been migrated from **raw TCP sockets** to
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
- **Glasses bridge** — forwards all messages to/from Rokid glasses
- **Debug Wi-Fi mode** — phone runs a WebSocket server; glasses connect over local Wi-Fi (fully functional on iOS)
- **BLE scan** — discovers nearby Rokid glasses via CoreBluetooth

## Bluetooth / Glasses Connection

The original Android app uses Rokid's proprietary **CXR-M SDK** for the Bluetooth data channel. That SDK is Android-only and has no public iOS equivalent.

| Mode | iOS status |
|------|-----------|
| BLE device discovery (scan) | ✅ Fully functional via CoreBluetooth |
| BLE data transport (send/receive JSON) | ⚠️ Stubbed — requires Rokid iOS SDK or GATT spec |
| Debug Wi-Fi mode (WebSocket server on port 8081) | ✅ Fully functional |

**Recommended for iOS:** Use **Debug Wi-Fi Mode** in Settings → Developer. The glasses app (Android) will connect to the phone's IP on port 8081.  The full BLE data path will work once Rokid releases an iOS SDK or documents their GATT characteristics.

## SDK Setup

The glasses now connect over **Bluetooth via the Rokid AI glasses SDK** — no Wi-Fi port or TCP server needed.

The only thing left for each app is filling in the three credential constants (`kAppKey`, `kAppSecret`, `kAccessKey`) from [account.rokid.com/#/setting/prove](https://account.rokid.com/#/setting/prove), then running `pod install`.

1. **Get credentials** at <https://account.rokid.com/#/setting/prove> and paste them into the glasses Swift file:
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

3. *(Glasses now connect automatically over Bluetooth — no TCP port needed.)*

## Setup in Xcode

This repository contains Swift source files. To build and run:

1. Open Xcode → File → New → Project → iOS App
2. Set the bundle identifier to `com.clawsses.ios`
3. Delete the auto-generated `ContentView.swift`
4. Drag the `Clawsses/` folder from this repo into the Xcode project (check "Copy items if needed")
5. Replace the generated `Info.plist` with `Clawsses/Info.plist` from this repo (or merge the keys)
6. Add these capabilities in Signing & Capabilities:
   - **Bluetooth** (implicitly granted via Info.plist keys)
   - **Speech Recognition** (via Info.plist)
   - **Microphone** (via Info.plist)
7. Build and run on a physical iPhone (Bluetooth and microphone require real hardware)

### Required capabilities in Xcode

Go to your target → Signing & Capabilities → + Capability and add:
- Background Modes → check **Audio, AirPlay, and Picture in Picture** and **Background fetch**

## Architecture

```
OpenClaw Gateway  ←WebSocket→  Clawsses iOS  ←Wi-Fi/BLE→  Rokid Glasses (Android)
      │                              │                              │
   AI agent                   OpenClawClient               Glasses HUD app
   Chat streaming             VoiceRecognitionManager       (unchanged Android app)
   Sessions                   ElevenLabsClient
                              GlassesConnectionManager
```

### Key source files

| File | Purpose |
|------|---------|
| `Protocol/Protocol.swift` | All message types (mirrors Android `Protocol.kt`) |
| `Network/OpenClawClient.swift` | WebSocket client, Ed25519 auth, chat streaming |
| `Network/DeviceIdentity.swift` | Ed25519 keypair via CryptoKit, stored in Keychain |
| `Glasses/GlassesConnectionManager.swift` | CoreBluetooth scan + debug WebSocket server mode |
| `Glasses/WakeSignalManager.swift` | Wake-signal buffering for glasses standby handling |
| `Glasses/DebugGlassesServer.swift` | TCP/WebSocket server for debug mode (Network.framework) |
| `Voice/VoiceCommandHandler.swift` | iOS Speech framework recognition |
| `Voice/VoiceRecognitionManager.swift` | OpenAI Realtime primary + SFSpeechRecognizer fallback |
| `TTS/ElevenLabsClient.swift` | ElevenLabs REST API client |
| `TTS/TtsPlaybackManager.swift` | AVFoundation audio playback |
| `UI/MainView.swift` | Main SwiftUI screen (mirrors Android `MainScreen.kt`) |

## Configuration

All settings are in the app's Settings screen (gear icon):

- **OpenClaw Server**: host, port, and access token
- **Glasses**: BLE scan / debug Wi-Fi mode toggle
- **Voice**: OpenAI API key and enable/disable toggle
- **TTS**: ElevenLabs API key and voice picker
- **Developer**: debug Wi-Fi mode

## Protocol compatibility

The iOS app uses the exact same JSON wire protocol as the Android app. No changes are needed to the glasses-side Android app or the OpenClaw gateway.

## License

MIT — same as the original [Clawsses](https://github.com/dweddepohl/clawsses).
