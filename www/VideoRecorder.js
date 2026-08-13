var exec = require('cordova/exec');

var VideoRecorder = {
     start: function (options, success, error) {
          options = options || {};
          // options:
          // - camera: "front" | "back" (default: "back")
          // - maxLength: number (seconds, 0 = unlimited)
          // - resolution: "WIDTHxHEIGHT" (e.g. "1920x1080")
          // - bitrate: number (bits per second)
          // - saveToGallery: boolean
          // - watermark: false
          exec(success, error, 'VideoRecorder', 'start', [options]);
     },

     stop: function (success, error) {
          exec(success, error, 'VideoRecorder', 'stop', []);
     },

     /**
      * Enable or disable native preview forwarding to JS.
      *
      * preview(true, onFrame, onError)
      *   - onFrame receives a string like "data:image/jpeg;base64,/9j/..."
      *   - onError optional
      *
      * preview(false, onStopped, onError)
      *   - onStopped called once when preview stops
      */
     preview: function (arg, success, error) {
          // normalize arguments: allow preview(true, callback) or preview(false, callback)
          // If first param is a function, treat as start with default options
          if (typeof arg === 'function') {
               // preview(callback)
               success = arg;
               arg = true;
          }

          // If arg is undefined, toggle behavior (start if not running, stop if running)
          // We cannot know running state here, so default to start
          if (typeof arg === 'undefined') {
               arg = true;
          }

          // If arg is an options object -> start preview with options
          if (arg && typeof arg === 'object' && !Array.isArray(arg)) {
               exec(success || function () {}, error || function () {}, 'VideoRecorder', 'preview', [arg]);
               return;
          }

          // If arg is an array, forward it (handles older callers that pass arrays)
          if (Array.isArray(arg)) {
               // Examples: [true], [false], [{ camera: 'front', resolution: '1080x1920' }]
               exec(success || function () {}, error || function () {}, 'VideoRecorder', 'preview', arg);
               return;
          }

          // If arg is boolean
          if (typeof arg === 'boolean') {
               exec(success || function () {}, error || function () {}, 'VideoRecorder', 'preview', [arg]);
               return;
          }

          // If arg is string "start"/"stop"
          if (typeof arg === 'string') {
               var lower = arg.toLowerCase();
               if (lower === 'start') {
                    exec(success || function () {}, error || function () {}, 'VideoRecorder', 'preview', [true]);
                    return;
               } else if (lower === 'stop') {
                    exec(success || function () {}, error || function () {}, 'VideoRecorder', 'preview', [false]);
                    return;
               }
          }

          // Fallback: treat as start
          exec(success || function () {}, error || function () {}, 'VideoRecorder', 'preview', [true]);
     },

     // Convenience helpers
     // startPreview(options, onFrame, onError)
     startPreview: function (options, onFrame, onError) {
          // allow startPreview(onFrame) or startPreview(options, onFrame)
          if (typeof options === 'function') {
               onFrame = options;
               options = { fps: 10 };
          }
          this.preview(options || { fps: 10 }, onFrame, onError);
     },

     // stopPreview(onStopped, onError)
     stopPreview: function (onStopped, onError) {
          this.preview(false, onStopped, onError);
     },
};

module.exports = VideoRecorder;
