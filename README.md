# xzyqrn amp

**Tech stack:** Swift, SwiftUI, C++, Core Audio, AudioUnit, Accelerate, AVFoundation, Neural Amp Modeler

![xzyqrn amp](docs/xzyqrn-amp.png)

**xzyqrn amp** is a native macOS bass amp and multi-effects rig. Plug a bass into the Mac through an audio interface (or any available input), shape the tone, and play through headphones or speakers.

It is built for bassists who want a complete practice and recording setup on the computer: tuner, NAM amp and cabinet simulation, a full pedal chain, groove playback, and audio or video capture — without a hardware amp.

Live mode is the playing surface. Studio mode opens companion workspaces for practice, lessons, and tabs:

- **Practice Lab** — live rig plus tuner, groove player, tempo ladder, recording, lesson shortcuts, notes, and session history
- **Bass Method** — reads a user-owned Hal Leonard Complete Edition folder in place (PDF, audio exercises, backing-only playback, notes, completion marks)
- **Bass Tabs** — licensed web providers, saved links and favorites, and local plain-text, MusicXML, or Guitar Pro files

The signal path is:

Bass → input gain → noise gate → compressor → octaver → envelope filter → drive → NAM amp → cabinet IR → EQ → chorus → delay → reverb → HPF/LPF filter → master

A jam-along drum loop can mix in after the amp. Recording taps the post-master mix, or bass only.

## License

xzyqrn amp is released under the [MIT License](LICENSE). Third-party libraries and bundled NAM captures keep their original licenses; see [NOTICE.md](NOTICE.md).
