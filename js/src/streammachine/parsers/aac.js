var AAC, CHANNEL_COUNTS, ID3V2_HEADER_LENGTH, MPEG_HEADER, MPEG_HEADER_LENGTH, PROFILES, REST_OF_ID3V2_HEADER, SAMPLE_FREQUENCIES, assert, strtok,
  __hasProp = {}.hasOwnProperty,
  __extends = function(child, parent) { for (var key in parent) { if (__hasProp.call(parent, key)) child[key] = parent[key]; } function ctor() { this.constructor = child; } ctor.prototype = parent.prototype; child.prototype = new ctor(); child.__super__ = parent.prototype; return child; },
  __slice = [].slice;

strtok = require('strtok2');

assert = require("assert");

PROFILES = ["Null", "AAC Main", "AAC LC", "AAC SSR", "AAC LTP", "SBR", "AAC Scalable", "TwinVQ"];

SAMPLE_FREQUENCIES = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350];

CHANNEL_COUNTS = [0, 1, 2, 3, 4, 5, 6, 8];

MPEG_HEADER_LENGTH = 4;

ID3V2_HEADER_LENGTH = 10;

MPEG_HEADER = new strtok.BufferType(MPEG_HEADER_LENGTH);

REST_OF_ID3V2_HEADER = new strtok.BufferType(ID3V2_HEADER_LENGTH - MPEG_HEADER_LENGTH);

module.exports = AAC = (function(_super) {
  var FIRST_BYTE;

  __extends(AAC, _super);

  FIRST_BYTE = new strtok.BufferType(1);

  function AAC() {
    var _emitAndMaybeEnd;
    AAC.__super__.constructor.apply(this, arguments);
    this.istream = new (require("events").EventEmitter);
    this._flushing = false;
    this.frameSize = -1;
    this.beginning = true;
    this.gotFF = false;
    this.byteTwo = null;
    this.isCRC = false;
    this.gotID3 = 0;
    this.frameHeader = null;
    this.frameHeaderBuf = null;
    this.id3v2 = null;
    this._parsingId3v2 = false;
    this._finishingId3v2 = false;
    this._id3v2_1 = null;
    this._id3v2_2 = null;
    this.once("finish", (function(_this) {
      return function() {
        return _this._flushing = setTimeout(function() {
          return _this.emit("end");
        }, 500);
      };
    })(this));
    _emitAndMaybeEnd = (function(_this) {
      return function() {
        var args;
        args = 1 <= arguments.length ? __slice.call(arguments, 0) : [];
        _this.emit.apply(_this, args);
        if (_this._flushing) {
          clearTimeout(_this._flushing);
          return _this._flushing = setTimeout(function() {
            return _this.emit("end");
          }, 500);
        }
      };
    })(this);
    strtok.parse(this.istream, (function(_this) {
      return function(v, cb) {
        var b, buf, e, frame, h, tag;
        if (v === void 0) {
          return FIRST_BYTE;
        }
        if (_this._parsingId3v2) {
          _this.id3v2.versionMinor = v[0];
          _this.id3v2.flags = v[1];
          _this.id3v2.length = (v[5] & 0x7f) | ((v[4] & 0x7f) << 7) | ((v[3] & 0x7f) << 14) | ((v[2] & 0x7f) << 21);
          _this._parsingId3v2 = false;
          _this._finishingId3v2 = true;
          _this._id3v2_2 = v;
          return new strtok.BufferType(_this.id3v2.length);
        }
        if (_this._finishingId3v2) {
          b = Buffer.concat([_this._id3v2_1, _this._id3v2_2, v]);
          _emitAndMaybeEnd('id3v2', b);
          _this._finishingId3v2 = false;
          return FIRST_BYTE;
        }
        if (_this.frameSize === -1 && _this.frameHeader) {
          tag = v.toString('ascii', 0, 3);
          if (tag === 'ID3') {
            _emitAndMaybeEnd("debug", "got an ID3");
            _this._parsingId3v2 = true;
            _this.id3v2 = {
              versionMajor: v[3]
            };
            _this._id3v2_1 = v;
            return REST_OF_ID3V2_HEADER;
          } else {
            try {
              h = _this.parseFrame(v);
            } catch (_error) {
              e = _error;
              console.log("invalid header... ", v, _this.frameHeader);
              _this.frameHeader = null;
              return FIRST_BYTE;
            }
            _this.frameHeader = h;
            _this.frameHeaderBuf = v;
            _emitAndMaybeEnd("header", h);
            _this.frameSize = _this.frameHeader.frame_length;
            if (_this.frameSize === 1) {
              console.log("Invalid frame header: ", h);
              return FIRST_BYTE;
            } else {
              return new strtok.BufferType(_this.frameSize - v.length);
            }
          }
        }
        if (_this.gotFF && _this.byteTwo) {
          buf = Buffer.alloc(2 + v.length);
          buf[0] = 0xFF;
          buf[1] = _this.byteTwo;
          v.copy(buf, 2);
          try {
            h = _this.parseFrame(buf);
          } catch (_error) {
            e = _error;
            console.log("chucking invalid try at header: ", buf);
            _this.gotFF = false;
            _this.byteTwo = null;
            return FIRST_BYTE;
          }
          _this.gotFF = false;
          _this.byteTwo = null;
          _this.beginning = false;
          _this.frameHeader = h;
          _this.frameHeaderBuf = buf;
          _emitAndMaybeEnd("header", h);
          _this.frameSize = _this.frameHeader.frame_length;
          _this.isCRC = h.crc;
          if (_this.frameSize === 1) {
            console.log("Invalid frame header: ", h);
            return FIRST_BYTE;
          } else {
            return new strtok.BufferType(_this.frameSize - buf.length);
          }
        }
        if (_this.gotFF) {
          if (v[0] >> 4 === 0xF) {
            _this.byteTwo = v[0];
            if ((v[0] & 6) === 0) {
              return new strtok.BufferType((v[0] & 1) === 1 ? 5 : 7);
            } else {
              _this.gotFF = false;
            }
          } else {
            _this.gotFF = false;
          }
        }
        if (_this.frameSize === -1 && !_this.gotFF) {
          if (v[0] === 0xFF) {
            _this.gotFF = true;
            return FIRST_BYTE;
          } else if (v[0] === 0x49) {
            _this.gotID3 = 1;
            return FIRST_BYTE;
          } else if (_this.gotID3 === 1 && v[0] === 0x44) {
            _this.gotID3 = 2;
            return FIRST_BYTE;
          } else if (_this.gotID3 === 2 && v[0] === 0x33) {
            _this.gotID3 = 3;
            return FIRST_BYTE;
          } else if (_this.gotID3 === 3) {
            _this._id3v2_1 = Buffer.from([0x49, 0x44, 0x33, v[0]]);
            _this.id3v2 = {
              versionMajor: v[0]
            };
            _this._parsingId3v2 = true;
            _this.gotID3 = 0;
            return REST_OF_ID3V2_HEADER;
          } else {
            return FIRST_BYTE;
          }
        }
        if (_this.frameHeaderBuf) {
          frame = Buffer.alloc(_this.frameHeaderBuf.length + v.length);
          _this.frameHeaderBuf.copy(frame, 0);
          v.copy(frame, _this.frameHeaderBuf.length);
          _emitAndMaybeEnd("frame", frame, _this.frameHeader);
        }
        _this.frameSize = -1;
        return new strtok.BufferType(_this.isCRC ? 9 : 7);
      };
    })(this));
  }

  AAC.prototype._write = function(chunk, encoding, callback) {
    this.istream.emit("data", chunk);
    return typeof callback === "function" ? callback() : void 0;
  };

  AAC.prototype.parseFrame = function(b) {
    var header;
    assert.ok(Buffer.isBuffer(b));
    assert.ok(b.length >= 7);
    assert.ok(b[0] === 0xFF && (b[1] >> 4) === 0xF, "Buffer does not start with FFF");
    header = {
      crc: !(b[1] & 0x1),
      mpeg_type: b[1] & 0x8 ? "MPEG2" : "MPEG4",
      profile: (b[2] >> 6) + 1,
      sample_freq: SAMPLE_FREQUENCIES[b[2] >> 2 & 0xF],
      channel_config: (b[2] & 1) << 2 | b[3] >> 6,
      frame_length: (b[3] & 0x3) << 11 | b[4] << 3 | b[5] >> 5,
      buffer_fullness: (b[5] & 0x1F) << 6 | b[6] >> 2,
      number_of_frames: (b[6] & 0x3) + 1,
      profile_name: "",
      channels: 0,
      frames_per_sec: 0,
      duration: 0,
      stream_key: ""
    };
    header.profile_name = PROFILES[header.profile];
    header.channels = CHANNEL_COUNTS[header.channel_config];
    header.frames_per_sec = header.sample_freq / 1024;
    header.duration = (1 / header.frames_per_sec) * 1000;
    header.stream_key = ['aac', header.sample_freq, header.profile, header.channels].join("-");
    return header;
  };

  return AAC;

})(require("stream").Writable);

//# sourceMappingURL=aac.js.map
