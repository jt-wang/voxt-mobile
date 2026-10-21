# Install Voxt Mobile (for AI coding agents)

You are installing Voxt Mobile for the person at this Mac. Run the steps in order from the repository root. Each step ends with a check: if it fails, stop and tell the person what failed and the last 40 lines of output. Steps marked **Person** need them at the Mac or the iPhone; tell them exactly what to click and wait for them to confirm.

Rules:

- Ask before installing anything (Homebrew packages, Xcode components).
- Never print, log or commit the Voxt **Access token**.
- If a port is in use, pick another one. Don't stop the process that holds it.
- Only one `xcodebuild` at a time; the build scripts refuse to start while another one runs.
- `ios/Config/Signing.local.xcconfig` is personal and gitignored. Don't commit it.

## 1. Check the Mac

```sh
uname -m                                 # arm64
xcodebuild -version                      # Xcode installed
xcrun --sdk iphoneos --show-sdk-path     # iOS SDK present
command -v brew git go uv cmake ninja xcodegen
```

If Xcode or its iOS platform is missing, ask the person to install Xcode from the App Store, open it once and include iOS. If tools are missing, ask, then run `brew install git go uv cmake ninja xcodegen`. Go toolchains and modules download into `build/` inside this repository.

**Person:** in Xcode → Settings → Accounts, add their Apple ID (a free one works).

Check: every command above prints a path or a version.

## 2. Build Voxt Omni Dev

```sh
tools/omni-dev.sh prepare
tools/omni-dev.sh build
```

`prepare` clones the pinned Voxt release (1.16.0, tag `voxt-v1.16.0` of sgl-project/sglang-omni) into `build/omni-source` and applies the patches in `tools/patches`. `build` builds the native speech runtime and the app.

Check: the last line printed is `build: <path>/Voxt Omni Dev.app`.

## 3. Start Voxt Omni Dev

`run` stays in the foreground. Start it in its own terminal (or as a background process whose PID you report):

```sh
tools/omni-dev.sh run
```

To reuse speech models the person already has from Voxt: `VOXT_SHARED_MODELS="<their model storage>/mlx-audio" tools/omni-dev.sh run`. If port 47920 is taken, set `OMNI_DEV_REMOTE_INPUT_PORT` to a free port.

**Person:** in Voxt Omni Dev, Settings → Model: download and select a speech model and a text model (every phone mode uses both). Settings → General: turn on **Remote Input**. Recommended: Settings → Model → gear button → Memory → **Unload Delay** 10 minutes, so phone dictation doesn't wait for models to reload.

Check: `curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:47920/v1/health` prints `401` (listening, token required).

## 4. Build and install the iPhone app

**Person:** connect the iPhone (iOS 17 or later) with a cable, unlock it and tap **Trust**.

```sh
tools/build-tailcat-native.sh
ios/tools/set-team.sh
ios/tools/check-ids.sh
```

`set-team.sh` reads the team ID from the keychain's `Apple Development` certificate and writes `ios/Config/Signing.local.xcconfig` with `DEVELOPMENT_TEAM` and an ID prefix of the person's own (`VOXT_MOBILE_ID_PREFIX`, default `com.voxtmobile.<team in lowercase>`), because a free Apple ID can't reuse another team's app IDs or App Group. Exit 1 means there is no certificate yet: ask the person to open `ios/VoxtMobile.xcodeproj`, choose their **(Personal Team)** under VoxtMobile → Signing & Capabilities → Team and press Run once (it may fail), then run `set-team.sh` again. Exit 2 means several teams: show the list and ask which, then run `ios/tools/set-team.sh <TEAM_ID>`. `check-ids.sh` confirms the app, the keyboard and the App Group use the same prefix.

Check: `set-team.sh` printed `Wrote …/ios/Config/Signing.local.xcconfig`, `check-ids.sh` passes, and `ios/VoxtTailcat/Artifacts/CVoxtTailcat.xcframework` exists.

**Person:** open `ios/VoxtMobile.xcodeproj`, choose the **VoxtMobile** scheme and their iPhone, press Run. If the phone asks, turn on Settings → Privacy & Security → **Developer Mode** (it restarts), and trust the developer under Settings → General → **VPN & Device Management**. With a free Apple ID the app must be re-run from Xcode every 7 days.

Check: the person sees the Voxt app open on the phone.

## 5. Build Voxt Connector

```sh
tools/build-connector.sh
open build/connector-derived/Build/Products/Release/"Voxt Connector.app"
```

It signs with the keychain's `Apple Development` identity (Xcode created it in step 4). If there is more than one, ask which to use and set `VOXT_CONNECTOR_SIGNING_IDENTITY` to its full name.

Check: the build ends with `build: <path>/Voxt Connector.app`, and the app's window opens.

**Person:** in the Voxt Connector window, click **Connect**. The Connector asks Voxt for the port and token directly when both apps are signed by the same team (a released build). A Voxt Omni Dev from `tools/omni-dev.sh build` is not team-signed, so the Connector then asks for them: the person enters the **Port** and **Access token** shown in Voxt Omni Dev → Settings → General → Remote Input and clicks **Connect** again. Never read or print the token yourself.

Check: the window shows `Connected to Voxt <version>`.

## 6. Set up the iPhone app (Person)

On the iPhone, Voxt opens with **Say anything. Only your Mac hears it.** Tell the person to:

1. Tap **Get started**.
2. **Connect your Mac:** click **Add iPhone** in Voxt Connector (the QR code lasts two minutes) and point the iPhone at it, or on the same Wi-Fi tap **Find my Mac on this Wi-Fi** and click **Allow** on the Mac when both show the same 6-digit code. Allow the camera and **Local Network** access if asked.
3. **Add the Voxt keyboard:** tap **Continue**, then **Open Settings**; in Settings › Voxt › **Keyboards**, turn on **Voxt** and **Allow Full Access**, tap **Allow**, and go back to Voxt.

Check: Voxt Connector shows `Ready for dictation`.

## 7. Try it (Person)

In the app's **Say anything** field, switch to the Voxt keyboard with the globe key if needed, tap the mic, speak, and tap again. Allow the microphone the first time.

Check: the text appears in the field. Then tell the person: **Keep Voxt ready** on Home keeps dictation in other apps from switching to Voxt, and Settings › Translation › Languages sets up to three languages for hold-and-slide translation.

## If something fails

- Builds in steps 2, 4 or 5: report the last 40 lines.
- Step 3 check prints `000`: Voxt Omni Dev isn't listening. Check that `run` is still running and printed `Remote Input on 127.0.0.1:<port>`.
- Signing errors in Xcode: the person must be signed in under Xcode → Settings → Accounts; run `ios/tools/set-team.sh` again. This flow hasn't been tried with a free Apple ID yet; if Xcode reports a different error, show it to the person.
- The phone can't connect: Voxt Omni Dev and Voxt Connector must both be running, and both devices need internet. If the QR code expired, click **Add iPhone** again.
