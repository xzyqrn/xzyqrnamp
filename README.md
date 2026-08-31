# xzyqrn amp

Native macOS bass amp. Plug an analog iRig (or any audio interface) into the Mac, load a NAM capture, and play through headphones.

The app is branded **xzyqrn amp**. The bundle ID stays `com.herojay.Amplifier` so existing microphone permission and the sandbox container survive the rename.

The built-in **xzyqrn Clean** model keeps the rig immediately usable. Two genuinely captured, redistributable NAM choices are also included in the factory presets: **MIG-50 Tube Stadium** and **DP-3X Bi-Amp Grind**. You can load additional bass captures from [TONE3000](https://www.tone3000.com) with **Load** on Capture.

The **Studio** menu opens three companion workspaces:

- **Practice Lab** combines the live rig, tuner, groove player, tempo ladder, recording, lesson/tab shortcuts, notes, and session history.
- **Bass Method** reads a user-owned Hal Leonard Complete Edition folder in place, with its PDF, 172 audio exercises, track volume, backing-only playback, exercise notes, completion marks, and saved reading position.
- **Bass Tabs** searches licensed web providers, saves links and favorites, and renders local plain-text, MusicXML, or Guitar Pro 3–8 (`.gp3`, `.gp4`, `.gp5`, `.gpx`, `.gp`) files. Web content stays with its provider and is not scraped into the app.

## Run it

1. Open `Amplifier.xcodeproj` in Xcode, or from this folder:

```bash
xcodebuild -project Amplifier.xcodeproj -scheme XzyqrnAmp -configuration Debug -derivedDataPath build
open "build/Build/Products/Debug/xzyqrn amp.app"
```

2. Plug the iRig into the Mac headphone jack. Plug headphones into the **iRig**, not the Mac.
3. Allow microphone access when macOS asks.
4. In **xzyqrn amp → Settings**, pick the external microphone as input and headphones as output if they are not already selected.
5. Click **POWER**.
6. Load a `.nam` capture from TONE3000. Leave the cabinet IR on for amp-only captures.

No paid Apple developer account is required to run this locally.

## Signal path

Bass → iRig → Mac input → input gain → noise gate → compressor → octaver → envelope filter → drive → NAM amp → cabinet IR → bass/mid/treble → chorus → delay → reverb → HPF/LPF utility filter → master → headphones

A jam-along drum loop can mix in after the amp. Recording taps the post-master mix (or bass only).

Buffer size defaults to 128 samples. Drop to 64 if the Mac can handle it; raise to 256 if you hear clicks.

## Beats and recordings

Factory one-bar loops live in the app bundle for 12 styles: Rock, Funk, Hip-Hop, Latin, Blues, Soul, Reggae, Disco, Metal, Jazz, Pop, and Electronic. Tempo is continuously adjustable from 40–240 BPM, with tap tempo and a practice tempo ladder. The resource set includes 80 / 100 / 120 BPM masters for each style. Takes write to `~/Library/Containers/com.herojay.Amplifier/Data/Library/Application Support/xzyqrn amp/Recordings/` (or Application Support when unsandboxed).

The factory library contains 16 complete rigs and 29 effect presets across compression, drive, octaver, envelope filter, chorus, delay, reverb, and utility filtering.

Regenerate the cabinet IR, drum loops, and app icon with:

```bash
python3 Scripts/bootstrap.py
```

Run the DSP, NAM, preset, and bundled-audio regressions with:

```bash
Scripts/test_audio.sh
```

## Credits

- [Neural Amp Modeler](https://github.com/sdatkinson/NeuralAmpModelerCore) by Steven Atkinson (MIT)
- [Eigen](https://eigen.tuxfamily.org) (MPL2)
- nlohmann/json (MIT)
- [alphaTab](https://www.alphatab.net) 1.8.4 (MPL-2.0) with Bravura (SIL Open Font License), used for local Guitar Pro rendering
- Community MIG-50 capture by Mikhail K and DP-3X bass-preamp capture by Jason Z, via pelennor2170/NAM_models (GPL-3.0; license bundled with the models)

Bundled captures retain their authors' licenses and attribution; externally loaded captures remain the property of their creators.
