# Voice Type for iPhone

A keyboard that types what you say, using the same Whisper model and word list as the Mac app. It all runs on the phone.

## How it fits together

iOS doesn't let keyboards use the microphone, so there are two parts:

- **The app** (`App/`) holds the mic and runs Whisper, in the background behind whatever you're typing in.
- **The keyboard** (`Keyboard/`) is a small remote control for it. It links `VoiceTypeLink` and not whisper, as iOS kills keyboards at around 70 MB.

They talk through the App Group folder and Darwin notifications (`VoiceTypeKit`). That folder is why the keyboard needs Full Access.

iOS only lets an app start the mic while it's in front, so the first tap of a session goes to the app, which starts the mic and hops back to where you were. After that the mic stays on (the orange dot) and tapping is instant, until the session times out.

The hop back uses a private API (`ReturnToPreviousApp`). It would have to come out for an App Store build.

## Why the Neural Engine

iOS forbids GPU work from the background. The ggml xcframework is built with Core ML, so whisper.cpp uses `ggml-large-v3-turbo-encoder.mlmodelc` when it sits beside the weights, and that runs fine from the background. Short clips take about 0.9 s on the 15 Pro Max, behind another app (median of the benchmark's 174 short real dictations, 1 Nov 2026). Between 15 and 24 of those were wrong depending on how 9 new texts are judged, against 22 for the Mac's Whisper. The price is memory, about 2.5 GB while a session is on, freed when it ends. The first load compiles the encoder and takes about 30 s.

## Building

```sh
ios/scripts/install-phone.sh        # build, sign with the App Store Connect key, install
ios/scripts/push-data.sh            # send the Mac's word list and corrections
ios/scripts/push-data.sh --model    # and the model, instead of the 2 GB download in the app
```

The word list isn't in the repo, because the repo is public.

Tests for the shared logic: `cd ios/VoiceTypeKit && taskpolicy -b swift test --filter VoiceTypeLinkTests`.

## Measuring on the phone

Copy WAVs to `Documents/bench` with `devicectl device copy to`, then:

```sh
xcrun devicectl device process launch --device <id> --terminate-existing --no-activate \
  com.mikecann.voicetype -- --bench --threads 2 --tag mytest
```

Results land in `Documents/bench-results-mytest.json`. It plays silence to stay alive, so it times the real background case. Recordings never go in the repo.
