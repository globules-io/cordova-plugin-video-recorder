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
          exec(success, error, 'VideoRecorder', 'start', [options]);
     },

     stop: function (success, error) {
          exec(success, error, 'VideoRecorder', 'stop', []);
     },
};

module.exports = VideoRecorder;
