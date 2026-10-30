# cordova-plugin-video-recorder
> Cordova plugin for Android and iOS to natively record a video and display live preview as base64<br>
> Recording and preview run independently. They share the camera and resolution from the last `setCamera` call. Preview frames are that resolution multiplied by `scale`.

## Installation
```bash
cordova plugin add @globules-io/cordova-plugin-video-recorder
cordova plugin rm @globules-io/cordova-plugin-video-recorder
```
## Supported Platforms
> Android
>
> iOS

## Permissions
> Permissions are required for this plugin to function properly (CAMERA, MICROPHONE)<br>
> On Android, the POST_NOTIFICATIONS permission is required to show a local notification<br>
> On iOS, NSPhotoLibraryUsageDescription is required to read/write from the photo library<br>
> Use the plugin / mechanism of your choice to request these permissions before starting the services

## JS API
Set the camera once. Recording and preview both use it until you call `setCamera` again.
If you never call it, the native code uses `camera: "back"` and `resolution: "1920x1080"`.

```js
VideoRecorder.setCamera({
    camera: "front",          // "front" or "back"
    resolution: "1024x768"    // WIDTHxHEIGHT
});
```

Start recording. Omitted options fall back to `maxLength: 0`, `bitrate: 10000000`, `saveToGallery: false`, and no watermark.

```js
VideoRecorder.startRecording({
    maxLength: 0,             // seconds, 0 = unlimited
    bitrate: 10000000,        // bits per second
    saveToGallery: true,
    watermark: false
});
```

Stop recording
```js
VideoRecorder.stopRecording();
```

Watermark
```js
VideoRecorder.startRecording({
    watermark: {
        image: "path_to_image",  // relative to cordova www
        position: "bottomright" // bottomright, topright, bottomleft, topleft
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

Start preview. Omitted options fall back to `scale: 0.3`, `fps: 10`, and `quality: 40`.
The frame callback receives `"preview_started"`, then `data:image/jpeg;base64,...` frames.

```js
VideoRecorder.setCamera({
    camera: "front",
    resolution: "1024x768"
});

VideoRecorder.startPreview({
    scale: 0.3,                 // preview size = resolution * scale
    fps: 10,                    // frames per second
    quality: 40                 // jpeg quality, 1-100
}, function (frame) {
    // use the base64 frame
});
```

Stop preview
```js
VideoRecorder.stopPreview();
```