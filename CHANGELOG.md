# Changelog

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
