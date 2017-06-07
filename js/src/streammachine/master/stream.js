var FileSource, HLSSegmenter, ProxySource, Rewind, SourceMount, Stream, TranscodingSource, URL, uuid, _,
  __hasProp = {}.hasOwnProperty,
  __extends = function(child, parent) { for (var key in parent) { if (__hasProp.call(parent, key)) child[key] = parent[key]; } function ctor() { this.constructor = child; } ctor.prototype = parent.prototype; child.prototype = new ctor(); child.__super__ = parent.prototype; return child; };

_ = require("underscore");

uuid = require("node-uuid");

URL = require("url");

Rewind = require('../rewind_buffer');

FileSource = require("../sources/file");

ProxySource = require('../sources/proxy');

TranscodingSource = require("../sources/transcoding");

HLSSegmenter = require("../rewind/hls_segmenter");

SourceMount = require("./source_mount");

module.exports = Stream = (function(_super) {
  __extends(Stream, _super);

  Stream.prototype.DefaultOptions = {
    meta_interval: 32768,
    max_buffer: 4194304,
    key: null,
    seconds: 60 * 60 * 4,
    burst: 30,
    source_password: null,
    host: null,
    fallback: null,
    acceptSourceMeta: false,
    log_minutes: true,
    monitored: false,
    metaTitle: "",
    metaUrl: "",
    format: "mp3",
    preroll: "",
    preroll_key: "",
    transcoder: "",
    root_route: false,
    group: null,
    bandwidth: 0,
    codec: null,
    ffmpeg_args: null,
    stream_key: null,
    impression_delay: 5000,
    log_interval: 30000,
    geolock: null
  };

  function Stream(key, log, mount, opts) {
    var newsource, uri, _ref;
    this.key = key;
    this.log = log;
    this.mount = mount;
    this.opts = _.defaults(opts || {}, this.DefaultOptions);
    this.destroying = false;
    this.source = null;
    if (opts.ffmpeg_args) {
      this._initTranscodingSource();
    } else {
      this.source = this.mount;
    }
    this._vitals = null;
    this.emitDuration = 0;
    this.STATUS = "Initializing";
    this.log.event("Stream is initializing.");
    this.log.info("Initializing RewindBuffer for master stream.");
    this.rewind = new Rewind({
      seconds: this.opts.seconds,
      burst: this.opts.burst,
      key: "master__" + this.key,
      log: this.log.child({
        module: "rewind"
      }),
      hls: (_ref = this.opts.hls) != null ? _ref.segment_duration : void 0
    });
    this.rewind.emit("source", this);
    this.rewind.on("buffer", (function(_this) {
      return function(c) {
        return _this.emit("buffer", c);
      };
    })(this));
    if (this.opts.hls != null) {
      this.rewind.hls_segmenter.on("snapshot", (function(_this) {
        return function(snap) {
          return _this.emit("hls_snapshot", snap);
        };
      })(this));
    }
    this._meta = {
      StreamTitle: this.opts.metaTitle,
      StreamUrl: ""
    };
    this.sourceMetaFunc = (function(_this) {
      return function(meta) {
        if (_this.opts.acceptSourceMeta) {
          return _this.setMetadata(meta);
        }
      };
    })(this);
    this.dataFunc = (function(_this) {
      return function(data) {
        return _this.emit("data", _.extend({}, data, {
          meta: _this._meta
        }));
      };
    })(this);
    this.vitalsFunc = (function(_this) {
      return function(vitals) {
        _this._vitals = vitals;
        return _this.emit("vitals", vitals);
      };
    })(this);
    this.source.on("data", this.dataFunc);
    this.source.on("vitals", this.vitalsFunc);
    if (this.opts.fallback != null) {
      uri = URL.parse(this.opts.fallback);
      newsource = (function() {
        switch (uri.protocol) {
          case "file:":
            return new FileSource({
              format: this.opts.format,
              filePath: uri.path,
              logger: this.log
            });
          case "http:":
            return new ProxySource({
              format: this.opts.format,
              url: this.opts.fallback,
              fallback: true,
              logger: this.log
            });
          default:
            return null;
        }
      }).call(this);
      if (newsource) {
        newsource.once("connect", (function(_this) {
          return function() {
            return _this.addSource(newsource, function(err) {
              if (err) {
                return _this.log.error("Connection to fallback source failed.");
              } else {
                return _this.log.event("Fallback source connected.");
              }
            });
          };
        })(this));
        newsource.on("error", (function(_this) {
          return function(err) {
            return _this.log.error("Fallback source error: " + err, {
              error: err
            });
          };
        })(this));
      } else {
        this.log.error("Unable to determine fallback source type for " + this.opts.fallback);
      }
    }
  }

  Stream.prototype._initTranscodingSource = function() {
    var tsource;
    this.log.debug("Setting up transcoding source for " + this.key);
    tsource = new TranscodingSource({
      stream: this.mount,
      ffmpeg_args: this.opts.ffmpeg_args,
      format: this.opts.format,
      logger: this.log
    });
    this.source = tsource;
    return tsource.once("disconnect", (function(_this) {
      return function() {
        _this.log.error("Transcoder disconnected for " + _this.key + ".");
        if (!_this.destroying) {
          return process.nextTick((function() {
            return _this._initTranscodingSource();
          }));
        }
      };
    })(this));
  };

  Stream.prototype.addSource = function(source, cb) {
    return this.source.addSource(source, cb);
  };

  Stream.prototype.config = function() {
    return this.opts;
  };

  Stream.prototype.vitals = function(cb) {
    var _vFunc;
    _vFunc = (function(_this) {
      return function(v) {
        return typeof cb === "function" ? cb(null, v) : void 0;
      };
    })(this);
    if (this._vitals) {
      return _vFunc(this._vitals);
    } else {
      return this.once("vitals", _vFunc);
    }
  };

  Stream.prototype.getHLSSnapshot = function(cb) {
    if (this.rewind.hls_segmenter) {
      return this.rewind.hls_segmenter.snapshot(cb);
    } else {
      return cb("Stream does not support HLS");
    }
  };

  Stream.prototype.getStreamKey = function(cb) {
    if (this._vitals) {
      return typeof cb === "function" ? cb(this._vitals.streamKey) : void 0;
    } else {
      return this.once("vitals", (function(_this) {
        return function() {
          return typeof cb === "function" ? cb(_this._vitals.streamKey) : void 0;
        };
      })(this));
    }
  };

  Stream.prototype.status = function() {
    return {
      key: this.key,
      id: this.key,
      vitals: this._vitals,
      source: this.source.status(),
      rewind: this.rewind._rStatus()
    };
  };

  Stream.prototype.setMetadata = function(opts, cb) {
    if ((opts.StreamTitle != null) || (opts.title != null)) {
      this._meta.StreamTitle = opts.StreamTitle || opts.title;
    }
    if ((opts.StreamUrl != null) || (opts.url != null)) {
      this._meta.StreamUrl = opts.StreamUrl || opts.url;
    }
    this.emit("meta", this._meta);
    return typeof cb === "function" ? cb(null, this._meta) : void 0;
  };

  Stream.prototype.configure = function(new_opts, cb) {
    var k, v, _ref;
    _ref = this.DefaultOptions;
    for (k in _ref) {
      v = _ref[k];
      if (new_opts[k] != null) {
        this.opts[k] = new_opts[k];
      }
      if (_.isNumber(this.DefaultOptions[k])) {
        this.opts[k] = Number(this.opts[k]);
      }
    }
    if (this.key !== this.opts.key) {
      this.key = this.opts.key;
    }
    if (new_opts.metaTitle) {
      this.setMetadata({
        title: new_opts.metaTitle
      });
    }
    this.rewind.setRewind(this.opts.seconds, this.opts.burst);
    this.emit("config");
    return typeof cb === "function" ? cb(null, this.config()) : void 0;
  };

  Stream.prototype.getRewind = function(cb) {
    return this.rewind.dumpBuffer((function(_this) {
      return function(err, writer) {
        return typeof cb === "function" ? cb(null, writer) : void 0;
      };
    })(this));
  };

  Stream.prototype.destroy = function() {
    this.destroying = true;
    if (this.source instanceof TranscodingSource) {
      this.source.disconnect();
    }
    this.rewind.disconnect();
    this.source.removeListener("data", this.dataFunc);
    this.source.removeListener("vitals", this.vitalsFunc);
    this.dataFunc = this.vitalsFunc = this.sourceMetaFunc = function() {};
    this.emit("destroy");
    return true;
  };

  Stream.StreamGroup = (function(_super1) {
    __extends(StreamGroup, _super1);

    function StreamGroup(key, log) {
      this.key = key;
      this.log = log;
      this.streams = {};
      this.transcoders = {};
      this.hls_min_id = null;
    }

    StreamGroup.prototype.addStream = function(stream) {
      var delFunc, _ref;
      if (!this.streams[stream.key]) {
        this.log.debug("SG " + this.key + ": Adding stream " + stream.key);
        this.streams[stream.key] = stream;
        delFunc = (function(_this) {
          return function() {
            _this.log.debug("SG " + _this.key + ": Stream disconnected: " + stream.key);
            return delete _this.streams[stream.key];
          };
        })(this);
        stream.on("disconnect", delFunc);
        stream.on("config", (function(_this) {
          return function() {
            if (stream.opts.group !== _this.key) {
              return delFunc();
            }
          };
        })(this));
        return (_ref = stream.rewind.hls_segmenter) != null ? _ref.syncToGroup(this) : void 0;
      }
    };

    StreamGroup.prototype.status = function() {
      var k, s, sstatus, _ref;
      sstatus = {};
      _ref = this.streams;
      for (k in _ref) {
        s = _ref[k];
        sstatus[k] = s.status();
      }
      return {
        id: this.key,
        streams: sstatus
      };
    };

    StreamGroup.prototype.hlsUpdateMinSegment = function(id) {
      var prev;
      if (!this.hls_min_id || id > this.hls_min_id) {
        prev = this.hls_min_id;
        this.hls_min_id = id;
        this.emit("hls_update_min_segment", id);
        return this.log.debug("New HLS min segment id: " + id + " (Previously: " + prev + ")");
      }
    };

    return StreamGroup;

  })(require("events").EventEmitter);

  return Stream;

})(require('events').EventEmitter);

//# sourceMappingURL=stream.js.map
