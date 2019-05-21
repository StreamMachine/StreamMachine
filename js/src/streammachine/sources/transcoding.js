var Debounce, FFmpeg, PassThrough, TranscodingSource, debug, _,
  __hasProp = {}.hasOwnProperty,
  __extends = function(child, parent) { for (var key in parent) { if (__hasProp.call(parent, key)) child[key] = parent[key]; } function ctor() { this.constructor = child; } ctor.prototype = parent.prototype; child.prototype = new ctor(); child.__super__ = parent.prototype; return child; };

_ = require("underscore");

FFmpeg = require("fluent-ffmpeg");

PassThrough = require("stream").PassThrough;

Debounce = require("../util/debounce");

debug = require("debug")("sm:sources:transcoding");

module.exports = TranscodingSource = (function(_super) {
  __extends(TranscodingSource, _super);

  TranscodingSource.prototype.TYPE = function() {
    return "Transcoding (" + (this.connected ? "Connected" : "Waiting") + ")";
  };

  function TranscodingSource(opts) {
    this.opts = opts;
    TranscodingSource.__super__.constructor.call(this, {
      skipParser: true
    });
    this._disconnected = false;
    this.d = require("domain").create();
    this.d.on("error", (function(_this) {
      return function(err) {
        var _ref;
        if ((_ref = _this.log) != null) {
          _ref.error("TranscodingSource domain error:" + err);
        }
        debug("Domain error: " + err, err);
        return _this.disconnect();
      };
    })(this));
    this.d.run((function(_this) {
      return function() {
        _this._queue = [];
        _this.o_stream = _this.opts.stream;
        _this.last_ts = null;
        _this._buf = new PassThrough;
        _this.ffmpeg = new FFmpeg({
          source: _this._buf,
          captureStderr: false
        }).addOptions(_this.opts.ffmpeg_args.split("|"));
        _this.ffmpeg.on("start", function(cmd) {
          var _ref;
          return (_ref = _this.log) != null ? _ref.info("ffmpeg started with " + cmd) : void 0;
        });
        _this.ffmpeg.on("error", function(err, stdout, stderr) {
          var _ref, _ref1, _ref2, _ref3;
          if (err.code === "ENOENT") {
            if ((_ref = _this.log) != null) {
              _ref.error("ffmpeg failed to start.");
            }
            return _this.disconnect();
          } else {
            if ((_ref1 = _this.log) != null) {
              _ref1.error("ffmpeg transcoding error: " + err);
            }
            if ((_ref2 = _this.log) != null) {
              _ref2.error("ffmpeg transcoding error stdout: " + stdout);
            }
            if ((_ref3 = _this.log) != null) {
              _ref3.error("ffmpeg transcoding error stderr: " + stderr);
            }
            return _this.disconnect();
          }
        });
        _this.ffmpeg.writeToStream(_this.parser);
        _this._pingData = new Debounce(_this.opts.discontinuityTimeout || 30 * 1000, function(last_ts) {
          var _ref;
          if ((_ref = _this.log) != null) {
            _ref.info("Transcoder data interupted. Marking discontinuity.");
          }
          _this.emit("discontinuity_begin", last_ts);
          return _this.o_stream.once("data", function(chunk) {
            var _ref1;
            if ((_ref1 = _this.log) != null) {
              _ref1.info("Transcoder data resumed. Reseting time to " + chunk.ts + ".");
            }
            _this.emit("discontinuity_end", chunk.ts, last_ts);
            return _this.chunker.resetTime(chunk.ts);
          });
        });
        _this.oDataFunc = function(chunk) {
          _this._pingData.ping();
          return _this._buf.write(chunk.data);
        };
        _this.oFirstDataFunc = function(first_chunk) {
          _this.emit("connected");
          _this.connected = true;
          _this.oFirstDataFunc = null;
          _this.chunker = new TranscodingSource.FrameChunker(_this.emitDuration * 1000, first_chunk.ts);
          _this.parser.on("frame", function(frame, header) {
            return _this.chunker.write({
              frame: frame,
              header: header
            });
          });
          _this.chunker.on("readable", function() {
            var c, _results;
            _results = [];
            while (c = _this.chunker.read()) {
              _this.last_ts = c.ts;
              _results.push(_this.emit("data", c));
            }
            return _results;
          });
          _this.o_stream.on("data", _this.oDataFunc);
          return _this._buf.write(first_chunk.data);
        };
        _this.o_stream.once("data", _this.oFirstDataFunc);
        return _this.parser.once("header", function(header) {
          var _ref, _ref1;
          _this.framesPerSec = header.frames_per_sec;
          _this.streamKey = header.stream_key;
          if ((_ref = _this.log) != null) {
            _ref.debug("setting framesPerSec to ", {
              frames: _this.framesPerSec
            });
          }
          if ((_ref1 = _this.log) != null) {
            _ref1.debug("first header is ", header);
          }
          return _this._setVitals({
            streamKey: _this.streamKey,
            framesPerSec: _this.framesPerSec,
            emitDuration: _this.emitDuration
          });
        });
      };
    })(this));
  }

  TranscodingSource.prototype.status = function() {
    var _ref;
    return {
      source: (_ref = typeof this.TYPE === "function" ? this.TYPE() : void 0) != null ? _ref : this.TYPE,
      connected: this.connected,
      url: "N/A",
      streamKey: this.streamKey,
      uuid: this.uuid,
      last_ts: this.last_ts
    };
  };

  TranscodingSource.prototype.disconnect = function() {
    if (!this._disconnected) {
      this._disconnected = true;
      this.d.run((function(_this) {
        return function() {
          var _ref;
          _this.o_stream.removeListener("data", _this.oDataFunc);
          if (_this.oFirstDataFunc) {
            _this.o_stream.removeListener("data", _this.oFirstDataFunc);
          }
          _this.ffmpeg.kill();
          if ((_ref = _this._pingData) != null) {
            _ref.kill();
          }
          return _this.connected = false;
        };
      })(this));
      this.emit("disconnect");
      return this.removeAllListeners();
    }
  };

  return TranscodingSource;

})(require("./base"));

//# sourceMappingURL=transcoding.js.map
