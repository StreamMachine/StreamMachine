var RewindDumpRestore, fs, path, _,
  __hasProp = {}.hasOwnProperty,
  __extends = function(child, parent) { for (var key in parent) { if (__hasProp.call(parent, key)) child[key] = parent[key]; } function ctor() { this.constructor = child; } ctor.prototype = parent.prototype; child.prototype = new ctor(); child.__super__ = parent.prototype; return child; };

path = require("path");

fs = require("fs");

_ = require("underscore");

module.exports = RewindDumpRestore = (function(_super) {
  var Dumper;

  __extends(RewindDumpRestore, _super);

  function RewindDumpRestore(master, settings) {
    var obj, s, _ref, _ref1;
    this.master = master;
    this.settings = settings;
    this._streams = {};
    this._queue = [];
    this._working = false;
    this._shouldLoad = false;
    this.log = this.master.log.child({
      module: "rewind_dump_restore"
    });
    this._path = fs.realpathSync(path.resolve(process.cwd(), this.settings.dir));
    if ((_ref = (s = fs.statSync(this._path))) != null ? _ref.isDirectory() : void 0) {

    } else {
      this.log.error("RewindDumpRestore path (" + this._path + ") is invalid.");
      return false;
    }
    _ref1 = this.master.streams;
    for (s in _ref1) {
      obj = _ref1[s];
      this._streams[s] = new Dumper(s, obj.rewind, this._path);
      obj.once("destroy", (function(_this) {
        return function() {
          return delete _this._streams[s];
        };
      })(this));
    }
    this.master.on("new_stream", (function(_this) {
      return function(stream) {
        _this.log.debug("RewindDumpRestore got new stream: " + stream.key);
        return _this._streams[stream.key] = new Dumper(stream.key, stream.rewind, _this._path);
      };
    })(this));
    if ((this.settings.frequency || -1) > 0) {
      this.log.debug("RewindDumpRestore initialized with interval of " + this.settings.frequency + " seconds.");
      this._int = setInterval((function(_this) {
        return function() {
          return _this._triggerDumps();
        };
      })(this), this.settings.frequency * 1000);
    }
  }

  RewindDumpRestore.prototype.load = function(cb) {
    var d, k, load_q, results, _load;
    this._shouldLoad = true;
    load_q = (function() {
      var _ref, _results;
      _ref = this._streams;
      _results = [];
      for (k in _ref) {
        d = _ref[k];
        _results.push(d);
      }
      return _results;
    }).call(this);
    results = {
      success: 0,
      errors: 0
    };
    _load = (function(_this) {
      return function() {
        if (d = load_q.shift()) {
          return d._tryLoad(function(err, stats) {
            if (err) {
              _this.log.error("Load for " + d.key + " errored: " + err, {
                stream: d.key
              });
              results.errors += 1;
            } else {
              results.success += 1;
            }
            return _load();
          });
        } else {
          _this.log.info("RewindDumpRestore load complete.", {
            success: results.success,
            errors: results.errors
          });
          return typeof cb === "function" ? cb(null, results) : void 0;
        }
      };
    })(this);
    return _load();
  };

  RewindDumpRestore.prototype._triggerDumps = function(cb) {
    var d, k, _ref;
    this.log.silly("Queuing Rewind dumps");
    (_ref = this._queue).push.apply(_ref, (function() {
      var _ref, _results;
      _ref = this._streams;
      _results = [];
      for (k in _ref) {
        d = _ref[k];
        _results.push(d);
      }
      return _results;
    }).call(this));
    if (!this._working) {
      return this._dump(cb);
    }
  };

  RewindDumpRestore.prototype._dump = function(cb) {
    var d;
    this._working = true;
    if (d = this._queue.shift()) {
      return d._dump((function(_this) {
        return function(err, file, timing) {
          if (err) {
            if (d.stream) {
              _this.log.error("Dump for " + d.key + " errored: " + err, {
                stream: d.stream.key
              });
            } else {
              _this.log.error("Dump for " + d.key + " errored (with no stream): " + err);
            }
          } else {
            _this.log.debug("Dump for " + d.key + " succeeded in " + timing + "ms.");
          }
          _this.emit("debug", "dump", d.key, err, {
            file: file,
            timing: timing
          });
          return _this._dump(cb);
        };
      })(this));
    } else {
      this._working = false;
      return typeof cb === "function" ? cb() : void 0;
    }
  };

  Dumper = (function(_super1) {
    __extends(Dumper, _super1);

    function Dumper(key, rewind, _path) {
      this.key = key;
      this.rewind = rewind;
      this._path = _path;
      this._i = null;
      this._active = false;
      this._loaded = null;
      this._tried_load = false;
      this._filepath = path.join(this._path, "" + this.rewind._rkey + ".dump");
    }

    Dumper.prototype._tryLoad = function(cb) {
      var rs;
      rs = fs.createReadStream(this._filepath);
      rs.once("error", (function(_this) {
        return function(err) {
          _this._setLoaded(false);
          if (err.code === "ENOENT") {
            return cb(null);
          }
          return cb(err);
        };
      })(this));
      return rs.once("open", (function(_this) {
        return function() {
          return _this.rewind.loadBuffer(rs, function(err, stats) {
            _this._setLoaded(true);
            return cb(null, stats);
          });
        };
      })(this));
    };

    Dumper.prototype._setLoaded = function(status) {
      this._loaded = status;
      this._tried_load = true;
      return this.emit("loaded", status);
    };

    Dumper.prototype.once_loaded = function(cb) {
      if (this._tried_load) {
        return typeof cb === "function" ? cb() : void 0;
      } else {
        return this.once("loaded", cb);
      }
    };

    Dumper.prototype._dump = function(cb) {
      var start_ts, w;
      if (this._active) {
        cb(new Error("RewindDumper failed: Already active for " + this.rewind._rkey));
        return false;
      }
      if (this.rewind.isLoading()) {
        cb(new Error("RewindDumper: Cannot dump while rewind buffer is loading."));
        return false;
      }
      this._active = true;
      start_ts = _.now();
      cb = _.once(cb);
      w = fs.createWriteStream("" + this._filepath + ".new");
      w.once("open", (function(_this) {
        return function() {
          return _this.rewind.dumpBuffer(function(err, writer) {
            writer.pipe(w);
            return w.once("close", function() {
              var af;
              if (w.bytesWritten === 0) {
                err = null;
                af = _.after(2, function() {
                  var end_ts;
                  end_ts = _.now();
                  _this._active = false;
                  return cb(err, null, end_ts - start_ts);
                });
                fs.unlink("" + _this._filepath + ".new", function(e) {
                  if (e) {
                    err = e;
                  }
                  return af();
                });
                return fs.unlink(_this._filepath, function(e) {
                  if (e && e.code !== "ENOENT") {
                    err = e;
                  }
                  return af();
                });
              } else {
                return fs.rename("" + _this._filepath + ".new", _this._filepath, function(err) {
                  var end_ts;
                  if (err) {
                    cb(err);
                    return false;
                  }
                  end_ts = _.now();
                  _this._active = false;
                  return cb(null, _this._filepath, end_ts - start_ts);
                });
              }
            });
          });
        };
      })(this));
      return w.on("error", (function(_this) {
        return function(err) {
          return cb(err);
        };
      })(this));
    };

    return Dumper;

  })(require('events').EventEmitter);

  return RewindDumpRestore;

})(require('events').EventEmitter);

//# sourceMappingURL=dump_restore.js.map
