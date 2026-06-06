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
```js
VideoRecorder.start({
     camera: "back",           // "front" or "back"
     maxLength: 0,             // 0 = unlimited
     resolution: "1920x1080",  // WIDTHxHEIGHT
     bitrate: 10000000,        // bits per second
     saveToGallery: false,     // save video to gallery
     watermark: false          // see watermark
});
```

Stop Recording
```js
VideoRecorder.stop();
```

Watermark
```js
VideoRecorder.start({
     ...,
     watermark: {
          image:'path_to_image',   //relative to cordova www
          position: 'bottomright'  //bottomright, topright, bottomleft, topleft
     }
});
```

Playback

cordova-plugin-file is needed for resolveLocalFileSystemURL
```js
document.addEventListener("VideoRecorderFinished", e => {
    const fileUrl = e.detail.file;
    window.resolveLocalFileSystemURL(fileUrl, entry => {
        const url = entry.toURL();
        console.log("Resolved:", url);
        //set as source to video element on page
        document.getElementById("preview").src = url;
    }, err => {
        console.log("resolve error", err);
    });
});
```