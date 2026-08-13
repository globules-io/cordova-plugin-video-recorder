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
     preview: function (enable, success, error) {
          // normalize arguments: allow preview(true, callback) or preview(false, callback)
          if (typeof enable !== 'boolean') {
               if (typeof success === 'function') success(new Error('first argument must be boolean'));
               return;
          }
          exec(success || function () {}, error || function () {}, 'VideoRecorder', 'preview', [enable]);
     },

     // Convenience helpers
     startPreview: function (onFrame, onError) {
          this.preview(true, onFrame, onError);
     },

     stopPreview: function (onStopped, onError) {
          this.preview(false, onStopped, onError);
     },
};

module.exports = VideoRecorder;
