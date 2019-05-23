var FileSource, IcecastSource, debug, net,
  __hasProp = {}.hasOwnProperty,
  __extends = function(child, parent) { for (var key in parent) { if (__hasProp.call(parent, key)) child[key] = parent[key]; } function ctor() { this.constructor = child; } ctor.prototype = parent.prototype; child.prototype = new ctor(); child.__super__ = parent.prototype; return child; };

FileSource = require("../sources/file");

net = require("net");

debug = require("debug")("sm:sources:icecast");

module.exports = IcecastSource = (function(_super) {
  __extends(IcecastSource, _super);

  function IcecastSource(opts) {
    this.opts = opts;
    this._connected = false;
    this.sock = null;
    this.fsource = new FileSource({
      format: this.opts.format,
      filePath: this.opts.filePath,
      chunkDuration: 0.2
    });
    this.fsource.on("data", (function(_this) {
      return function(chunk) {
        var _ref;
        return (_ref = _this.sock) != null ? _ref.write(chunk.data) : void 0;
      };
    })(this));
  }

  IcecastSource.prototype.start = function(cb) {
    var sFunc;
    sFunc = (function(_this) {
      return function() {
        _this.fsource.start();
        return typeof cb === "function" ? cb(null) : void 0;
      };
    })(this);
    if (this.sock) {
      return sFunc();
    } else {
      return this._connect((function(_this) {
        return function(err) {
          if (err) {
            return cb(err);
          }
          _this._connected = true;
          return sFunc();
        };
      })(this));
    }
  };

  IcecastSource.prototype.pause = function() {
    return this.fsource.stop();
  };

  IcecastSource.prototype._connect = function(cb) {
    this.sock = net.connect(this.opts.port, this.opts.host, (function(_this) {
      return function() {
        var auth, authTimeout;
        debug("Connected!");
        authTimeout = null;
        _this.sock.once("readable", function() {
          var err, resp;
          resp = _this.sock.read();
          clearTimeout(authTimeout);
          if (resp && /^HTTP\/1\.0 200 OK/.test(resp.toString())) {
            debug("Got HTTP OK. Starting streaming.");
            return cb(null);
          } else {
            err = "Unknown response: " + (resp.toString());
            debug(err);
            cb(new Error(err));
            return _this.disconnect();
          }
        });
        _this.sock.write("SOURCE /" + _this.opts.stream + " HTTP/1.0\r\n");
        if (_this.opts.password) {
          auth = Buffer.from("source:" + _this.opts.password, 'ascii').toString("base64");
          _this.sock.write("Authorization: Basic " + auth + "\r\n\r\n");
          debug("Writing auth with " + auth + ".");
        } else {
          _this.sock.write("\r\n");
        }
        return authTimeout = setTimeout(function() {
          var err;
          err = "Timed out waiting for authentication.";
          debug(err);
          cb(new Error(err));
          return _this.disconnect();
        }, 5000);
      };
    })(this));
    return this.sock.once("error", (function(_this) {
      return function(err) {
        debug("Socket error: " + err);
        return _this.disconnect();
      };
    })(this));
  };

  IcecastSource.prototype.disconnect = function() {
    var _ref;
    this._connected = false;
    if ((_ref = this.sock) != null) {
      _ref.end();
    }
    this.sock = null;
    return this.emit("disconnect");
  };

  return IcecastSource;

})(require("events").EventEmitter);

//# sourceMappingURL=icecast_source.js.map
