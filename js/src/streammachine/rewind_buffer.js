var Concentrate, Dissolve, HLSSegmenter, MemoryStore, RewindBuffer, Rewinder, nconf, _,
  __hasProp = {}.hasOwnProperty,
  __extends = function(child, parent) { for (var key in parent) { if (__hasProp.call(parent, key)) child[key] = parent[key]; } function ctor() { this.constructor = child; } ctor.prototype = parent.prototype; child.prototype = new ctor(); child.__super__ = parent.prototype; return child; };

_ = require('underscore');

Concentrate = require("concentrate");

Dissolve = require("dissolve");

nconf = require("nconf");

Rewinder = require("./rewind/rewinder");

HLSSegmenter = require("./rewind/hls_segmenter");

MemoryStore = require("./rewind/memory_store");

module.exports = RewindBuffer = (function(_super) {
  __extends(RewindBuffer, _super);

  function RewindBuffer(rewind_opts) {
    if (rewind_opts == null) {
      rewind_opts = {};
    }
    this._rsecs = rewind_opts.seconds || 0;
    this._rburstsecs = rewind_opts.burst || 0;
    this._rsecsPerChunk = Infinity;
    this._rmax = null;
    this._rburst = null;
    this._rkey = rewind_opts.key;
    this._risLoading = false;
    if (rewind_opts.log && !this.log) {
      this.log = rewind_opts.log;
    }
    this._rlisteners = [];
    this._rbuffer = rewind_opts.buffer_store || new MemoryStore;
    this._rbuffer.on("shift", (function(_this) {
      return function(b) {
        return _this.emit("rshift", b);
      };
    })(this));
    this._rbuffer.on("push", (function(_this) {
      return function(b) {
        return _this.emit("rpush", b);
      };
    })(this));
    this._rbuffer.on("unshift", (function(_this) {
      return function(b) {
        return _this.emit("runshift", b);
      };
    })(this));
    if (rewind_opts.hls) {
      this.log.debug("Setting up HLS Segmenter.", {
        segment_duration: rewind_opts.hls
      });
      this.hls_segmenter = new HLSSegmenter(this, rewind_opts.hls, this.log);
    }
    this._rdataFunc = (function(_this) {
      return function(chunk) {
        var l, _i, _len, _ref, _results;
        _this._rbuffer.insert(chunk);
        _ref = _this._rlisteners;
        _results = [];
        for (_i = 0, _len = _ref.length; _i < _len; _i++) {
          l = _ref[_i];
          _results.push(_this._rbuffer.at(l._offset, function(err, b) {
            return l._insert(b);
          }));
        }
        return _results;
      };
    })(this);
    this.on("source", (function(_this) {
      return function(newsource) {
        return _this._rConnectSource(newsource);
      };
    })(this));
  }

  RewindBuffer.prototype.disconnect = function() {
    this._rdataFunc = function() {};
    this._rbuffer.removeAllListeners();
    return true;
  };

  RewindBuffer.prototype.isLoading = function() {
    return this._risLoading;
  };

  RewindBuffer.prototype.resetRewind = function(cb) {
    this._rbuffer.reset(cb);
    return this.emit("reset");
  };

  RewindBuffer.prototype.setRewind = function(secs, burst) {
    this._rsecs = secs;
    this._rburstsecs = burst;
    return this._rUpdateMax();
  };

  RewindBuffer.prototype._rConnectSource = function(newsource, cb) {
    this.log.debug("RewindBuffer got source event");
    if (this._rsource) {
      this._rsource.removeListener("data", this._rdataFunc);
      this.log.debug("removed old rewind data listener");
    }
    return newsource.vitals((function(_this) {
      return function(err, vitals) {
        if (_this._rstreamKey && _this._rstreamKey === vitals.streamKey) {
          _this.log.debug("Rewind buffer validated new source.  Reusing buffer.");
        } else {
          _this._rChunkLength(vitals);
        }
        newsource.on("data", _this._rdataFunc);
        _this._rsource = newsource;
        return typeof cb === "function" ? cb(null) : void 0;
      };
    })(this));
  };

  RewindBuffer.prototype._rStatus = function() {
    var status, _ref, _ref1;
    status = {
      buffer_length: this._rbuffer.length(),
      first_buffer_ts: (_ref = this._rbuffer.first()) != null ? _ref.ts : void 0,
      last_buffer_ts: (_ref1 = this._rbuffer.last()) != null ? _ref1.ts : void 0
    };
    if (this.hls_segmenter) {
      _.extend(status, this.hls_segmenter.status());
    }
    return status;
  };

  RewindBuffer.prototype._rChunkLength = function(vitals) {
    if (this._rstreamKey !== vitals.streamKey) {
      if (this._rstreamKey) {
        this.log.debug("Invalid existing rewind buffer. Reset.");
        this._rbuffer.reset();
      }
      this._rsecsPerChunk = vitals.emitDuration;
      this._rstreamKey = vitals.streamKey;
      this._rUpdateMax();
      return this.log.debug("Rewind's max buffer length is ", {
        max: this._rmax,
        secsPerChunk: this._rsecsPerChunk,
        secs: vitals.emitDuration
      });
    }
  };

  RewindBuffer.prototype._rUpdateMax = function() {
    if (this._rsecsPerChunk) {
      this._rmax = Math.round(this._rsecs / this._rsecsPerChunk);
      this._rbuffer.setMax(this._rmax);
      this._rburst = Math.round(this._rburstsecs / this._rsecsPerChunk);
    }
    return this.log.debug("Rewind's max buffer length is ", {
      max: this._rmax,
      seconds: this._rsecs
    });
  };

  RewindBuffer.prototype.getRewinder = function(id, opts, cb) {
    var rewind;
    rewind = new Rewinder(this, id, opts, cb);
    if (!opts.pumpOnly) {
      return this._raddListener(rewind);
    }
  };

  RewindBuffer.prototype.recordListen = function(opts) {};

  RewindBuffer.prototype.bufferedSecs = function() {
    return Math.round(this._rbuffer.length() * this._rsecsPerChunk);
  };

  RewindBuffer.prototype._insertBuffer = function(chunk) {
    return this._rbuffer.insert(chunk);
  };

  RewindBuffer.prototype.loadBuffer = function(stream, cb) {
    var headerRead, parser;
    this._risLoading = true;
    this.emit("rewind_loading");
    if (!stream) {
      process.nextTick((function(_this) {
        return function() {
          _this.emit("rewind_loaded");
          return _this._risLoading = false;
        };
      })(this));
      if (this.hls_segmenter) {
        this.hls_segmenter._loadMap(null);
      }
      return cb(null, {
        seconds: 0,
        length: 0
      });
    }
    parser = Dissolve().uint32le("header_length").tap(function() {
      return this.buffer("header", this.vars.header_length).tap(function() {
        this.push(JSON.parse(this.vars.header));
        this.vars = {};
        return this.loop(function(end) {
          return this.uint8("meta_length").tap(function() {
            return this.buffer("meta", this.vars.meta_length).uint16le("data_length").tap(function() {
              return this.buffer("data", this.vars.data_length).tap(function() {
                var meta;
                meta = JSON.parse(this.vars.meta.toString());
                this.push({
                  ts: new Date(meta.ts),
                  meta: meta.meta,
                  duration: meta.duration,
                  data: this.vars.data
                });
                return this.vars = {};
              });
            });
          });
        });
      });
    });
    stream.pipe(parser);
    headerRead = false;
    parser.on("readable", (function(_this) {
      return function() {
        var c, _results;
        _results = [];
        while (c = parser.read()) {
          if (!headerRead) {
            headerRead = true;
            _this.emit("header", c);
            _this._rChunkLength({
              emitDuration: c.secs_per_chunk,
              streamKey: c.stream_key
            });
            if (c.hls && _this.hls_segmenter) {
              _this.hls_segmenter._loadMap(c.hls);
            }
          } else {
            _this._insertBuffer(c);
            _this.emit("buffer", c);
          }
          _results.push(true);
        }
        return _results;
      };
    })(this));
    return parser.on("end", (function(_this) {
      return function() {
        var obj;
        obj = {
          seconds: _this.bufferedSecs(),
          length: _this._rbuffer.length()
        };
        _this.log.info("RewindBuffer is now at ", obj);
        _this.emit("rewind_loaded");
        _this._risLoading = false;
        return typeof cb === "function" ? cb(null, obj) : void 0;
      };
    })(this));
  };

  RewindBuffer.prototype.dumpBuffer = function(cb) {
    return this._rbuffer.clone((function(_this) {
      return function(err, rbuf_copy) {
        var go;
        if (err) {
          cb(err);
          return false;
        }
        go = function(hls) {
          var writer;
          writer = new RewindBuffer.RewindWriter(rbuf_copy, _this._rsecsPerChunk, _this._rstreamKey, hls);
          return cb(null, writer);
        };
        if (_this.hls_segmenter) {
          return _this.hls_segmenter._dumpMap(function(err, info) {
            if (err) {
              return cb(err);
            }
            return go(info);
          });
        } else {
          return go();
        }
      };
    })(this));
  };

  RewindBuffer.prototype.checkOffsetSecs = function(secs) {
    return this.checkOffset(this.secsToOffset(secs));
  };

  RewindBuffer.prototype.checkOffset = function(offset) {
    var bl;
    bl = this._rbuffer.length();
    if (offset < 0) {
      this.log.silly("offset is invalid! 0 for live.");
      return 0;
    }
    if (bl >= offset) {
      this.log.silly("Granted. current buffer length is ", {
        length: bl
      });
      return offset;
    } else {
      this.log.silly("Not available. Instead giving max buffer of ", {
        length: bl - 1
      });
      return bl - 1;
    }
  };

  RewindBuffer.prototype.secsToOffset = function(secs) {
    return Math.round(Number(secs) / this._rsecsPerChunk);
  };

  RewindBuffer.prototype.offsetToSecs = function(offset) {
    return Math.round(Number(offset) * this._rsecsPerChunk);
  };

  RewindBuffer.prototype.timestampToOffset = function(time, cb) {
    return cb(null, this._rbuffer._findTimestampOffset(time));
  };

  RewindBuffer.prototype.pumpSeconds = function(rewinder, seconds, concat, cb) {
    var frames;
    frames = this.checkOffsetSecs(seconds);
    return this.pumpFrom(rewinder, frames, frames, concat, cb);
  };

  RewindBuffer.prototype.pumpFrom = function(rewinder, offset, length, concat, cb) {
    if (offset === 0 || length === 0) {
      if (typeof cb === "function") {
        cb(null, null);
      }
      return true;
    }
    return this._rbuffer.range(offset, length, (function(_this) {
      return function(err, chunks) {
        var b, buffers, cbuf, duration, meta, offsetSeconds, pumpLen, _i, _len, _ref;
        pumpLen = 0;
        duration = 0;
        meta = null;
        buffers = [];
        for (_i = 0, _len = chunks.length; _i < _len; _i++) {
          b = chunks[_i];
          pumpLen += b.data.length;
          duration += b.duration;
          if (concat) {
            buffers.push(b.data);
          } else {
            rewinder._insert(b);
          }
          if (!meta) {
            meta = b.meta;
          }
        }
        if (concat) {
          cbuf = Buffer.concat(buffers);
          rewinder._insert({
            data: cbuf,
            meta: meta,
            duration: duration
          });
        }
        offsetSeconds = offset instanceof Date ? (Number(_this._rbuffer.last().ts) - Number(offset)) / 1000 : _this.offsetToSecs(offset);
        if ((_ref = _this.log) != null) {
          _ref.silly("Converting offset to seconds: ", {
            offset: offset,
            secs: offsetSeconds
          });
        }
        return typeof cb === "function" ? cb(null, {
          meta: meta,
          duration: duration,
          length: pumpLen,
          offsetSeconds: offsetSeconds
        }) : void 0;
      };
    })(this));
  };

  RewindBuffer.prototype.burstFrom = function(rewinder, offset, burstSecs, cb) {
    var burst;
    burst = this.checkOffsetSecs(burstSecs);
    if (offset > burst) {
      return this.pumpFrom(rewinder, offset, burst, false, (function(_this) {
        return function(err, info) {
          return typeof cb === "function" ? cb(err, offset - burst) : void 0;
        };
      })(this));
    } else {
      return this.pumpFrom(rewinder, offset, offset, false, (function(_this) {
        return function(err, info) {
          return typeof cb === "function" ? cb(err, 0) : void 0;
        };
      })(this));
    }
  };

  RewindBuffer.prototype._raddListener = function(obj) {
    if ((obj._offset != null) && obj._offset >= 0) {
      this._rlisteners.push(obj);
      return true;
    } else {
      return false;
    }
  };

  RewindBuffer.prototype._rremoveListener = function(obj) {
    this._rlisteners = _(this._rlisteners).without(obj);
    return true;
  };

  RewindBuffer.RewindWriter = (function(_super1) {
    __extends(RewindWriter, _super1);

    function RewindWriter(buf, secs, streamKey, hls) {
      this.buf = buf;
      this.secs = secs;
      this.streamKey = streamKey;
      this.hls = hls;
      this.c = Concentrate();
      this.slices = 0;
      this.i = this.buf.length - 1;
      this._ended = false;
      RewindWriter.__super__.constructor.call(this, {
        highWaterMark: 25 * 1024 * 1024
      });
      if (this.buf.length === 0) {
        this.push(null);
        return false;
      }
      this._writeHeader();
    }

    RewindWriter.prototype._writeHeader = function(cb) {
      var header_buf;
      header_buf = Buffer.from(JSON.stringify({
        start_ts: this.buf[0].ts,
        end_ts: this.buf[this.buf.length - 1].ts,
        secs_per_chunk: this.secs,
        stream_key: this.streamKey,
        hls: this.hls
      }));
      this.c.uint32le(header_buf.length);
      this.c.buffer(header_buf);
      this.push(this.c.result());
      return this.c.reset();
    };

    RewindWriter.prototype._read = function(size) {
      var chunk, meta_buf, r, result, wlen;
      if (this.i < 0) {
        return false;
      }
      wlen = 0;
      while (true) {
        chunk = this.buf[this.i];
        meta_buf = Buffer.from(JSON.stringify({
          ts: chunk.ts,
          meta: chunk.meta,
          duration: chunk.duration
        }));
        this.c.uint8(meta_buf.length);
        this.c.buffer(meta_buf);
        this.c.uint16le(chunk.data.length);
        this.c.buffer(chunk.data);
        r = this.c.result();
        this.c.reset();
        result = this.push(r);
        wlen += r.length;
        this.i -= 1;
        if (this.i < 0) {
          this.push(null);
          return true;
        }
        if (!result || wlen > size) {
          return false;
        }
      }
    };

    return RewindWriter;

  })(require("stream").Readable);

  return RewindBuffer;

})(require("events").EventEmitter);

//# sourceMappingURL=rewind_buffer.js.map
