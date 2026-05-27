# Rivulet

A native tvOS video streaming app designed for simplicity, combining **Plex** media server integration with **Live TV** support.

This project has fairly *opinionated* designs and logic, with a few focal points:
- **Simplicity** - What is the best design to get me to the media I want to watch.
- **Live TV** - Plex's live TV is, to put it nicely, sub-par. I've spent too long trying to get it to work well for me (kudos if you don't have this problem). I don't want live TV in a separate app, so this solves my problems. You might could use this just for live tv. Go for it.
- **HomePod Integration** - The Plex app has never worked well when setting HomePod as the default audio output on my Apple TV. It hurts to have a HomePod sitting there collecting dust while my sub-par tv speakers play sound. This app helps the hurt.
- **Custom Video Player** - Direct play by default, no server transcoding. The bar I'm chasing is Infuse. This was frustratingly built because Apple's frameworks can't handle DV profile 7 or P8.6 and can't direct play most video containers. MPV and VLC can't handle DV at all and can't use Apple's HomePod controls.
- **Apple TV+ Inspired** - The UI takes heavy inspiration from Apple's own TV app. Clean, focused, and native-feeling.

## Screenshots

| | |
|---|---|
| ![](Screenshots/01-hero.png) | ![](Screenshots/02-home-rows.png) |
| ![](Screenshots/03-sidebar.png) | ![](Screenshots/04-detail.png) |
| ![](Screenshots/05-episodes.png) | ![](Screenshots/06-library.png) |

<a href="https://testflight.apple.com/join/TcCsF5As">
  <img src="https://developer.apple.com/assets/elements/icons/testflight/testflight-64x64_2x.png" alt="TestFlight" height="50">
  <br>
  <strong>Join the TestFlight Beta</strong>
</a>

<br>

![tvOS 26+](https://img.shields.io/badge/tvOS-26+-000000?logo=apple)
![Swift](https://img.shields.io/badge/Swift-6.0-FA7343?logo=swift&logoColor=white)

## Features

### Live TV
- Dispatcharr and generic M3U/XMLTV sources
- Plex Live TV
- Channel guide, favorites, and recently watched
- Multi-stream mode: watch several channels at once in a grid, or promote one to focus while the others play muted

Dispatcharr and Plex Live TV are tested regularly. Generic M3U/XMLTV is wired up but less battle-tested. Feedback welcome.

### Custom Video Player
FFmpeg for demuxing, Apple's sample-buffer frameworks for rendering (`AVSampleBufferDisplayLayer`, `AVSampleBufferAudioRenderer`, `AVSampleBufferRenderSynchronizer`). Direct play is the primary path; HLS is only a fallback.

- **Video**: H.264 and HEVC via VideoToolbox. HDR10, HLG, and Dolby Vision. DV profiles 5, 7, and 8.1. Profile 7 (dual-layer Blu-ray rips) is converted to 8.1 on-the-fly via [libdovi](https://github.com/quietvoid/dovi_tool).
- **Audio**: AAC, AC3, E-AC3, TrueHD, DTS, DTS-HD MA, FLAC, ALAC, MP3, and PCM variants.
- **Subtitles**: Text (SRT, ASS/SSA) rendered in SwiftUI. Bitmap (PGS, DVB) decoded via FFmpeg.

### Music
- Album, artist, and playlist browsing, modeled on Apple's Music app for tvOS.
- Lyrics display (synced when the source provides timestamps, static otherwise).
- Real-time audio visualizer on the Now Playing screen.
- System Now Playing controls. HomePod, AirPods, Siri Remote, Control Center all work.

Chasing Plexamp on the features side. Long way to go.

## Requirements

- Apple TV running tvOS 26 or later
- Xcode 26+ for building
- Plex Media Server (for Plex features)
- M3U/XMLTV source or Dispatcharr (for Live TV)

## Building

```bash
# Clone the repository
git clone https://github.com/l984-451/Rivulet.git
cd Rivulet

# Open in Xcode
open Rivulet.xcodeproj

# Build for Apple TV
xcodebuild -scheme Rivulet -destination 'generic/platform=tvOS' build
```

## Contributing

I welcome all contributions from any level of developer. I welcome contributions from LLMs too as long as they are checked and tested.

**If you do contribute, please build and test on an actual Apple TV. The simulator is close, but does not mimic the Apple TV fully.**

By submitting a pull request, you agree to license your contribution under the same terms as Rivulet (PolyForm Noncommercial 1.0.0, see [LICENSE](LICENSE)).

## License

Rivulet is licensed under the [PolyForm Noncommercial License 1.0.0](LICENSE).

In short: clone it, run it, modify it, share it, contribute back, for personal, educational, research, hobby, or other noncommercial use. You may not use Rivulet (or anything derived from it) for commercial purposes, including selling it, charging for access to it, or bundling it into a paid product or service.

Third-party components retain their original licenses. FFmpeg is included under LGPL-2.1+; libdovi under MIT. See [LICENSE](LICENSE) for details.

## Acknowledgments

- [FFmpeg](https://ffmpeg.org/): demuxing, audio decoding, subtitle decoding, and remuxing
- [libdovi](https://github.com/quietvoid/dovi_tool): Dolby Vision RPU conversion
- [Plex](https://plex.tv/): media server platform
- [Dispatcharr](https://github.com/Dispatcharr/Dispatcharr): IPTV management

---

**Note**: Rivulet is not affiliated with or endorsed by Plex, Inc.
