var MP3, assert, strtok,
  __hasProp = {}.hasOwnProperty,
  __extends = function(child, parent) { for (var key in parent) { if (__hasProp.call(parent, key)) child[key] = parent[key]; } function ctor() { this.constructor = child; } ctor.prototype = parent.prototype; child.prototype = new ctor(); child.__super__ = parent.prototype; return child; },
  __slice = [].slice;

strtok = require('strtok2');

assert = require("assert");

module.exports = MP3 = (function(_super) {
  var BITRATE_MAP, BITRATE_MPEG1_LAYER1, BITRATE_MPEG1_LAYER2, BITRATE_MPEG1_LAYER3, BITRATE_MPEG2_LAYER1, BITRATE_MPEG2_LAYER2A3, FIRST_BYTE, ID3V1_LENGTH, ID3V2_HEADER_LENGTH, LAYER1_ID, LAYER2_ID, LAYER3_ID, LAYER_NAME, MODE_DUAL, MODE_JOINT, MODE_MONO, MODE_NAME, MODE_STEREO, MPEG1_ID, MPEG25_ID, MPEG2_ID, MPEG_HEADER, MPEG_HEADER_LENGTH, MPEG_NAME, REST_OF_ID3V1, REST_OF_ID3V2_HEADER, SAMPLING_RATES;

  __extends(MP3, _super);

  ID3V1_LENGTH = 128;

  ID3V2_HEADER_LENGTH = 10;

  MPEG_HEADER_LENGTH = 4;

  FIRST_BYTE = new strtok.BufferType(1);

  MPEG_HEADER = new strtok.BufferType(MPEG_HEADER_LENGTH);

  REST_OF_ID3V2_HEADER = new strtok.BufferType(ID3V2_HEADER_LENGTH - MPEG_HEADER_LENGTH);

  REST_OF_ID3V1 = new strtok.BufferType(ID3V1_LENGTH - MPEG_HEADER_LENGTH);

  LAYER1_ID = 3;

  LAYER2_ID = 2;

  LAYER3_ID = 1;

  MPEG1_ID = 3;

  MPEG2_ID = 2;

  MPEG25_ID = 0;

  MODE_MONO = 3;

  MODE_DUAL = 2;

  MODE_JOINT = 1;

  MODE_STEREO = 0;

  MPEG_NAME = ["MPEG2.5", null, "MPEG2", "MPEG1"];

  LAYER_NAME = [null, "Layer3", "Layer2", "Layer1"];

  MODE_NAME = ["Stereo", "J-Stereo", "Dual", "Mono"];

  SAMPLING_RATES = [44100, 48000, 32000, 0];

  BITRATE_MPEG1_LAYER1 = [0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448];

  BITRATE_MPEG1_LAYER2 = [0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384];

  BITRATE_MPEG1_LAYER3 = [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320];

  BITRATE_MPEG2_LAYER1 = [0, 32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256];

  BITRATE_MPEG2_LAYER2A3 = [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160];

  BITRATE_MAP = [[null, BITRATE_MPEG2_LAYER2A3, BITRATE_MPEG2_LAYER2A3, BITRATE_MPEG2_LAYER1], null, [null, BITRATE_MPEG2_LAYER2A3, BITRATE_MPEG2_LAYER2A3, BITRATE_MPEG2_LAYER1], [null, BITRATE_MPEG1_LAYER3, BITRATE_MPEG1_LAYER2, BITRATE_MPEG1_LAYER1]];

  function MP3() {
    var _emitAndMaybeEnd;
    MP3.__super__.constructor.apply(this, arguments);
    this.istream = new (require("events").EventEmitter);
    this.outbuf = [];
    this._flushing = false;
    this.frameSize = -1;
    this.beginning = true;
    this.gotFF = false;
    this.gotID3 = 0;
    this.byteTwo = null;
    this.frameHeader = null;
    this.frameHeaderBuf = null;
    this.id3v2 = null;
    this._parsingId3v1 = false;
    this._parsingId3v2 = false;
    this._finishingId3v2 = false;
    this._id3v2_1 = null;
    this._id3v2_2 = null;
    this._id3v1_1 = null;
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
        var b, buf, e, frame, h, id3, tag;
        if (v === void 0) {
          return FIRST_BYTE;
        }
        if (_this._parsingId3v1) {
          id3 = _this.parseId3V1(Buffer.concat([_this._id3v1_1, v]));
          _emitAndMaybeEnd("id3v1", id3);
          _this._id3v1_1 = null;
          _this._parsingId3v1 = false;
          return MPEG_HEADER;
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
          } else if (tag === 'TAG') {
            _emitAndMaybeEnd("debug", "got a TAG");
            _this._id3v1_1 = v;
            _this._parsingId3v1 = true;
            return REST_OF_ID3V1;
          } else {
            try {
              h = _this.parseFrame(v);
            } catch (_error) {
              e = _error;
              _emitAndMaybeEnd("debug", "invalid header... ", v, tag, _this.frameHeader);
              _this.frameHeader = null;
              return FIRST_BYTE;
            }
            _this.frameHeader = h;
            _this.frameHeaderBuf = v;
            _emitAndMaybeEnd("header", v, h);
            _this.frameSize = _this.frameHeader.frameSize;
            if (_this.frameSize === 1) {
              _emitAndMaybeEnd("debug", "Invalid frame header: ", h);
              return FIRST_BYTE;
            } else {
              return new strtok.BufferType(_this.frameSize - MPEG_HEADER_LENGTH);
            }
          }
        }
        if (_this.gotFF && _this.byteTwo) {
          buf = Buffer.alloc(4);
          buf[0] = 0xFF;
          buf[1] = _this.byteTwo;
          buf[2] = v[0];
          buf[3] = v[1];
          try {
            h = _this.parseFrame(buf);
          } catch (_error) {
            e = _error;
            _emitAndMaybeEnd("debug", "chucking invalid try at header: ", buf);
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
          _this.frameSize = _this.frameHeader.frameSize;
          if (_this.frameSize === 1) {
            _emitAndMaybeEnd("debug", "Invalid frame header: ", h);
            return FIRST_BYTE;
          } else {
            _emitAndMaybeEnd("debug", "On-tracking with frame of: ", _this.frameSize - MPEG_HEADER_LENGTH);
            return new strtok.BufferType(_this.frameSize - MPEG_HEADER_LENGTH);
          }
        }
        if (_this.gotFF) {
          if (v[0] >> 4 >= 0xE) {
            _this.byteTwo = v[0];
            return new strtok.BufferType(2);
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
        return MPEG_HEADER;
      };
    })(this));
  }

  MP3.prototype._write = function(chunk, encoding, cb) {
    if (this._flushing) {
      throw new Error("MP3 write while flushing.");
    }
    this.istream.emit("data", chunk);
    return typeof cb === "function" ? cb() : void 0;
  };

  MP3.prototype.parseId3V1 = function(id3v1) {
    var id3, _stripNull;
    id3 = {};
    _stripNull = function(buf) {
      var idx;
      idx = buf.toJSON().indexOf(0);
      return buf.toString("ascii", 0, idx === -1 ? buf.length : idx);
    };
    id3.title = _stripNull(id3v1.slice(3, 33));
    id3.artist = _stripNull(id3v1.slice(33, 63));
    id3.album = _stripNull(id3v1.slice(63, 93));
    id3.year = _stripNull(id3v1.slice(93, 97));
    if (id3v1[125] === 0) {
      id3.comment = _stripNull(id3v1.slice(97, 125));
      id3.track = id3v1.readUInt8(126);
    } else {
      id3.track = null;
      id3.comment = _stripNull(id3v1.slice(97, 127));
    }
    id3.genre = id3v1.readUInt8(127);
    return id3;
  };

  MP3.prototype.parseFrame = function(b) {
    var header32, r, _ref, _ref1;
    assert.ok(Buffer.isBuffer(b));
    assert.ok(b[0] === 0xFF && (b[1] >> 4) >= 0xE, "Buffer does not start with FF[EF]");
    header32 = b.readUInt32BE(0);
    r = {
      mpegID: (header32 >> 19) & 3,
      layerID: (header32 >> 17) & 3,
      crc16used: (header32 & 0x00010000) === 0,
      bitrateIndex: (header32 >> 12) & 0xF,
      samplingRateIndex: (header32 >> 10) & 3,
      padding: (header32 & 0x00000200) !== 0,
      privateBitSet: (header32 & 0x00000100) !== 0,
      mode: (header32 >> 6) & 3,
      modeExtension: (header32 >> 4) & 3,
      copyrighted: (header32 & 0x00000008) !== 0,
      original: (header32 & 0x00000004) === 0,
      emphasis: header32 & 3,
      channels: 0,
      bitrateKBPS: 0,
      mpegName: "",
      layerName: "",
      modeName: "",
      samplingRateHz: 0,
      samplesPerFrame: 0,
      bytesPerSlot: 0,
      frameSizeRaw: 0,
      frameSize: 0,
      frames_per_sec: 0,
      stream_key: ""
    };
    r.channels = r.mode === MODE_MONO ? 1 : 2;
    r.bitrateKBPS = BITRATE_MAP[r.mpegID][r.layerID][r.bitrateIndex];
    r.mpegName = MPEG_NAME[r.mpegID];
    r.layerName = LAYER_NAME[r.layerID];
    r.modeName = MODE_NAME[r.mode];
    r.samplingRateHz = SAMPLING_RATES[r.samplingRateIndex];
    if (r.mpegID === MPEG2_ID) {
      r.samplingRateHz >>= 1;
    } else if (r.mpegID === MPEG25_ID) {
      r.samplingRateHz >>= 2;
    }
    if (r.layerID === LAYER1_ID) {
      r.samplesPerFrame = 384;
      r.bytesPerSlot = 4;
      r.frameSizeRaw = (12 * (r.bitrateKBPS * 1000) / (r.samplingRateHz * 10) + ((_ref = r.padding) != null ? _ref : {
        1: 0
      })) * 4;
    } else {
      r.samplesPerFrame = (r.mpegID === MPEG1_ID) || (r.layerID === LAYER2_ID) ? 1152 : 576;
      r.bytesPerSlot = 1;
      r.frameSizeRaw = (r.samplesPerFrame / 8) * (r.bitrateKBPS * 1000) / r.samplingRateHz + (r.padding ? 1 : 0);
    }
    r.frameSize = ~~r.frameSizeRaw;
    if (!r.frameSize) {
      throw new Error('bad size: ' + r.frameSize);
    }
    r.frames_per_sec = r.samplingRateHz / r.samplesPerFrame;
    r.duration = (1 / r.frames_per_sec) * 1000;
    r.stream_key = ['mp3', r.samplingRateHz, r.bitrateKBPS, ((_ref1 = r.modeName) === "Stereo" || _ref1 === "J-Stereo" ? "s" : "m")].join("-");
    return r;
  };

  return MP3;

})(require("stream").Writable);

//# sourceMappingURL=mp3.js.map
