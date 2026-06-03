# cordova-plugin-video-recorder
Cordova plugin for Android and iOS to natively record a video

## Installation
```bash
cordova plugin add @globules-io/cordova-plugin-video-recorder
cordova plugin rm @globules-io/cordova-plugin-video-recorder
```
## Supported Platforms
Android
iOS

## JS API
Start Recording
```bash
VideoRecorder.start({
     camera: "back",          // "front" or "back"
     maxLength: 0,            // 0 = unlimited
     resolution: "1920x1080", // WIDTHxHEIGHT
     bitrate: 10000000        // bits per second
});
```

Stop Recording
```bash
VideoRecorder.stop();
```

Playback
```bash
document.addEventListener("VideoRecorderFinished", e => {
  const file = e.detail.file;
  console.log("Video saved:", file);
  
  const video = document.getElementById("preview");
  video.src = file;
  video.load();
  video.play();
});
```