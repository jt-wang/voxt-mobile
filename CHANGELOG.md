# Changelog

## v0.1.1

Source update: the phone follows the Mac's capabilities, builds carry no personal identity by default, and two Mac fixes.

- **The phone reads what your Mac can do.** Word corrections and history sync appear only when Voxt on the Mac offers them; the Mac detects the spoken language unless you choose one.
- **Dictations no longer stall after the Mac has been idle.** After a couple of minutes without use, Voxt released its models and then could hold phone dictations for about ten minutes. Fixed in the Mac patches.
- **The live preview no longer shows Qwen's language header.**
- **Voxt Connector works with a sandboxed Voxt**: it finds Voxt's socket inside its container, and Voxt checks the Connector's app bundle on disk as well as its running code.
- **Build it as yours.** Bundle IDs, team and source link are configuration with neutral defaults (`ios/Config/Signing.shared.xcconfig`, `VOXT_CONNECTOR_BUNDLE_ID`); put your own in `Signing.local.xcconfig`. The Japanese, Pinyin and Zhuyin layouts are optional (`ios/InputMethods.yml`), and the build scripts say what to install when Go, xcodegen or a signing identity is missing.
- **Remote Input is now called Local API** (Voxt Settings › General › Local API › Allow other apps to dictate through Voxt). `tools/omni-dev.sh` takes `OMNI_DEV_LOCAL_API_PORT` (the old name still works) and builds on sglang-omni commit ffd00d35 instead of the 1.16.0 tag.
- **Try it end to end without a phone:** `tools/loopback-e2e.sh` runs the iPhone app in the simulator against Voxt's Local API on the same Mac, and the design tour runs against a fixture.

## v0.1.0

First public release. Voxt Mobile is a voice keyboard for iPhone that sends what you say to Voxt on your own Mac and types back clean text.

- **Dictate anywhere on iPhone.** Tap the mic in the Voxt keyboard, speak, and the cleaned-up text is inserted into the app you're typing in. Voxt on your Mac does the speech recognition and cleanup with the models you already use there.
- **Clean text, still in your voice.** Fillers, false starts and words you take back are removed. Long thoughts come out as readable paragraphs, and lists you count out loud as numbered lists.
- **Recordings aren't lost.** If your Mac can't be reached or the app is closed mid-way, the recording is kept. Tap Retry on the keyboard, or Send again in History.
- **Translate, edit a selection, or help me write**, from the same keyboard.
- **Typing keyboards** for English, Pinyin, Zhuyin, Japanese, Korean and Spanish. Pinyin shows syllables as you type, has a full candidate grid and fuzzy Pinyin.
- **Pair once with a QR code.** Voxt Connector on the Mac shows the code. The phone reaches your Mac over an encrypted Tailscale connection, at home or away.
- **Six interface languages:** English, 简体中文, 繁體中文, 日本語, 한국어, Español.
- **Verifiable builds.** Settings › About › Source code shows the commit each build was made from.

Needs an iPhone with iOS 17 or later and a Mac with Apple silicon. The Mac download includes Voxt Connector and an unofficial modified build of [Voxt](https://github.com/sgl-project/sglang-omni/tree/main/Voxt) (Apache-2.0) that adds the phone API; its source changes are in `tools/patches/`.
