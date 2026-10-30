var exec = require('cordova/exec');

/**
 * Shared camera setup for recording and preview.
 * If setCamera is not called, native code uses camera "back" and resolution "1920x1080".
 *
 * startRecording options: { maxLength, bitrate, saveToGallery, watermark }
 *   defaults: maxLength 0, bitrate 10000000, saveToGallery false, watermark off
 *
 * startPreview options: { scale, fps, quality }
 *   defaults: scale 0.3, fps 10, quality 40
 *   onFrame receives "preview_started", then "data:image/jpeg;base64,..." frames.
 *
 * captureFrame() grabs one JPEG at the setCamera resolution while preview is running.
 *   success receives "data:image/jpeg;base64,..."
 */
var VideoRecorder = {
    setCamera: function (options, success, error) {
        exec(success || function () {}, error || function () {}, 'VideoRecorder', 'setCamera', [options || {}]);
    },

    startRecording: function (options, success, error) {
        exec(success, error, 'VideoRecorder', 'startRecording', [options || {}]);
    },

    stopRecording: function (success, error) {
        exec(success, error, 'VideoRecorder', 'stopRecording', []);
    },

    startPreview: function (options, onFrame, onError) {
        if (typeof options === 'function') {
            onError = onFrame;
            onFrame = options;
            options = {};
        }
        exec(onFrame || function () {}, onError || function () {}, 'VideoRecorder', 'startPreview', [options || {}]);
    },

    stopPreview: function (onStopped, onError) {
        exec(onStopped || function () {}, onError || function () {}, 'VideoRecorder', 'stopPreview', []);
    },

    captureFrame: function (success, error) {
        exec(success, error, 'VideoRecorder', 'captureFrame', []);
    }
};

module.exports = VideoRecorder;
