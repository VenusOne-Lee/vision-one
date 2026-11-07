# iPhone

Vision One uses your iPhone two ways, with no iPhone app needed. Research and mockups: [iPhone and Prompt Presets](https://claude.ai/artifact/MEn3osXANGbz89GksBwoE1).

## The iPhone's screen, over USB

Plug in your iPhone, unlock it, and pick it under **iPhone screen** in the menu bar panel. Its screen and sound record to `phone.mov` in the take, next to `screen.mov`. This is how QuickTime Player records an iPhone, and it suits launch videos for iPhone apps: your Mac, your phone and your face in one take.

How: `CaptureDevices` sets CoreMediaIO's `kCMIOHardwarePropertyAllowScreenCaptureDevices`, after which a plugged-in iPhone appears a moment later as a `.muxed` `AVCaptureDevice`. `DeviceTrackRecorder` records it with `AVCaptureMovieFileOutput` (2 second fragments, so a crash loses little). If the phone is unplugged or Camera access is off, the screen recording carries on and the panel says why. macOS asks for Camera access the first time, because it treats a phone's screen as a camera.

In the editor and export: when recording stops, `phone.json` saves when `phone.mov` began relative to `screen.mov`'s first frame (both on the host clock; neither stops for a pause, whose stretch is cut in `edits.json`). The preview and every export then show the phone on the right, centred and 72% of the frame's height, in a plain ink phone body (`PhoneTrack.frame`, `FrameCompositor.phone`), under the camera bubble, cut the same way as the screen. The phone's sound is mixed in, faded at each join. Takes recorded before this have no `phone.json` and show the screen alone.

Not yet: frame-exact alignment (the start time comes from the movie file output's start callback, which is close but not to the frame), and a switch to hide the phone or move it.

## The iPhone as your camera

Continuity Camera makes an iPhone an ordinary camera on the Mac (macOS 13+ and iOS 16+, over USB or nearby), with Desk View as a second camera. `CaptureDevices` lists cameras in picker order (iPhone, Desk View, this Mac, others) as `CameraInfo`, and `CameraChoice` picks one: **Auto** follows `AVCaptureDevice.systemPreferredCamera`, which switches to an iPhone on a stand by itself, and a manual pick is saved as `userPreferredCamera`, as Apple recommends. The camera bubble records `camera.mov` from `CaptureDevices.shared.cameraToRecord()`.

## Later

Vision One for iPhone (record on the phone, send the take to the Mac) and the iPhone as a remote, both reusing VisionOneKit.
