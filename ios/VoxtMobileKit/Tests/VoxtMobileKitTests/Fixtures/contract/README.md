# Local API contract

Example JSON of Voxt's Local API, shared by both sides: Voxt's own contract test records them from its real output, and Voxt Mobile's tests decode them. The Mac side keeps the same files under `Voxt/Mobile/contract/` in [sglang-omni](https://github.com/sgl-project/sglang-omni) together with the API description; change them there first, then copy them here.

- `id`, `asrMs` and `enhanceMs` hold fixed values; real responses differ on every request.
- `compose-request.json` has every option field Voxt reads. Voxt ignores option keys it does not read, so a client may send its own (Voxt Mobile also sends `literalDictation`); compare a client's body with the fixture on the fixture's keys.
- `errors.json` maps a name to the status and `{"error": "…"}` body of one failure.
