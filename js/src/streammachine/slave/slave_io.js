var SlaveIO, Socket,
  __hasProp = {}.hasOwnProperty,
  __extends = function(child, parent) { for (var key in parent) { if (__hasProp.call(parent, key)) child[key] = parent[key]; } function ctor() { this.constructor = child; } ctor.prototype = parent.prototype; child.prototype = new ctor(); child.__super__ = parent.prototype; return child; };

Socket = require("socket.io-client");

module.exports = SlaveIO = (function(_super) {
  __extends(SlaveIO, _super);

  function SlaveIO(slave, _log, opts) {
    this.slave = slave;
    this._log = _log;
    this.opts = opts;
    this.connected = false;
    this.io = null;
    this.id = null;
    this._log.debug("Connecting to master at ", {
      master: this.opts.master
    });
    this._connect();
  }

  SlaveIO.prototype.once_connected = function(cb) {
    if (this.connected) {
      return cb(null, this.io);
    } else {
      return this.once("connected", (function(_this) {
        return function() {
          return cb(null, _this.io);
        };
      })(this));
    }
  };

  SlaveIO.prototype.disconnect = function() {
    var _ref;
    return (_ref = this.io) != null ? _ref.disconnect() : void 0;
  };

  SlaveIO.prototype._connect = function() {
    this._log.info("Slave trying connection to master.");
    this.io = Socket.connect(this.opts.master, {
      reconnection: true,
      timeout: 2000
    });
    this.io.on("connect", (function(_this) {
      return function() {
        var pingTimeout;
        _this._log.debug("Slave in _onConnect.");
        pingTimeout = setTimeout(function() {
          return _this._log.error("Failed to get master OK ping.");
        }, 1000);
        return _this.io.emit("ok", function(res) {
          clearTimeout(pingTimeout);
          if (res === "OK") {
            _this._log.debug("Connected to master.");
            _this.id = _this.io.io.engine.id;
            _this.connected = true;
            return _this.emit("connected");
          } else {
            return _this._log.error("Master OK ping response invalid: " + res);
          }
        });
      };
    })(this));
    this.io.on("connect_error", (function(_this) {
      return function(err) {
        if (err.code = ~/ECONNREFUSED/) {
          return _this._log.info("Slave connection refused: " + err);
        } else {
          _this._log.info("Slave got connection error of " + err, {
            error: err
          });
          return console.log("got connection error of ", err);
        }
      };
    })(this));
    this.io.on("disconnect", (function(_this) {
      return function() {
        _this.connected = false;
        _this._log.debug("Disconnected from master.");
        return _this.emit("disconnect");
      };
    })(this));
    this.io.on("config", (function(_this) {
      return function(config) {
        return _this.slave.configureStreams(config.streams);
      };
    })(this));
    this.io.on("status", (function(_this) {
      return function(cb) {
        return _this.slave._streamStatus(cb);
      };
    })(this));
    this.io.on("should_shutdown", (function(_this) {
      return function(cb) {
        return _this.slave._shutdown(cb);
      };
    })(this));
    this.io.on("audio", (function(_this) {
      return function(obj) {
        obj.chunk.data = Buffer.from(obj.chunk.data);
        obj.chunk.ts = new Date(obj.chunk.ts);
        return _this.emit("audio:" + obj.stream, obj.chunk);
      };
    })(this));
    return this.io.on("hls_snapshot", (function(_this) {
      return function(obj) {
        var k, s, _i, _j, _len, _len1, _ref, _ref1, _ref2;
        _ref1 = ((_ref = obj.snapshot) != null ? _ref.segments : void 0) || [];
        for (_i = 0, _len = _ref1.length; _i < _len; _i++) {
          s = _ref1[_i];
          _ref2 = ['ts', 'end_ts', 'ts_actual', 'end_ts_actual'];
          for (_j = 0, _len1 = _ref2.length; _j < _len1; _j++) {
            k = _ref2[_j];
            if (s[k]) {
              s[k] = new Date(s[k]);
            }
          }
        }
        return _this.emit("hls_snapshot:" + obj.stream, obj.snapshot);
      };
    })(this));
  };

  SlaveIO.prototype.vitals = function(key, cb) {
    return this.io.emit("vitals", key, cb);
  };

  SlaveIO.prototype.hls_snapshot = function(key, cb) {
    return this.io.emit("hls_snapshot", key, (function(_this) {
      return function(err, snapshot) {
        var k, s, _i, _j, _len, _len1, _ref, _ref1;
        _ref = (snapshot != null ? snapshot.segments : void 0) || [];
        for (_i = 0, _len = _ref.length; _i < _len; _i++) {
          s = _ref[_i];
          _ref1 = ['ts', 'end_ts', 'ts_actual', 'end_ts_actual'];
          for (_j = 0, _len1 = _ref1.length; _j < _len1; _j++) {
            k = _ref1[_j];
            if (s[k]) {
              s[k] = new Date(s[k]);
            }
          }
        }
        return cb(err, snapshot);
      };
    })(this));
  };

  SlaveIO.prototype.log = function(obj) {
    return this.io.emit("log", obj);
  };

  return SlaveIO;

})(require("events").EventEmitter);

//# sourceMappingURL=slave_io.js.map
