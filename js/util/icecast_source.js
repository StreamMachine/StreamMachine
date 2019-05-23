var LoopingSource, Throttle, file, filepath, fs, lsource, net, path, sock, throttle, _ref,
  __hasProp = {}.hasOwnProperty,
  __extends = function(child, parent) { for (var key in parent) { if (__hasProp.call(parent, key)) child[key] = parent[key]; } function ctor() { this.constructor = child; } ctor.prototype = parent.prototype; child.prototype = new ctor(); child.__super__ = parent.prototype; return child; };

fs = require("fs");

path = require("path");

net = require("net");

Throttle = require("throttle");

this.args = require("optimist").usage("Usage: $0 --host localhost --port 8001 --stream foo --password abc123 [file]").describe({
  host: "Server",
  port: "Server source port",
  stream: "Stream key",
  password: "Stream password",
  rate: "Throttle rate for streaming"
})["default"]({
  rate: 32000
}).demand("host", "port", "stream").argv;

LoopingSource = (function(_super) {
  __extends(LoopingSource, _super);

  function LoopingSource(opts) {
    this._reading = false;
    this._data = Buffer.alloc(0);
    this._readPos = 0;
    LoopingSource.__super__.constructor.call(this, opts);
  }

  LoopingSource.prototype._write = function(chunk, encoding, cb) {
    var buf;
    buf = Buffer.concat([this._data, chunk]);
    this._data = buf;
    console.log("_data length is now ", this._data.length);
    if (!this.reading) {
      this.emit("readable");
    }
    return cb();
  };

  LoopingSource.prototype._read = function(size) {
    var rFunc;
    if (this._reading) {
      console.log("_read while reading");
      return true;
    }
    if (this._data.length === 0) {
      this.push('');
      return true;
    }
    this._reading = true;
    rFunc = (function(_this) {
      return function() {
        var buf, remaining;
        remaining = Math.min(_this._data.length - _this._readPos, size);
        console.log("reading from " + _this._readPos + " with " + remaining);
        buf = Buffer.from(remaining);
        _this._data.copy(buf, 0, _this._readPos, _this._readPos.remaining);
        _this._readPos = _this._readPos + remaining;
        if (_this._readPos >= _this._data.length) {
          _this._readPos = 0;
        }
        console.log("pushing buffer of " + buf.length);
        if (_this.push(buf, 'binary')) {
          return rFunc();
        } else {
          return _this._reading = false;
        }
      };
    })(this);
    return rFunc();
  };

  return LoopingSource;

})(require('stream').Duplex);

filepath = (_ref = this.args._) != null ? _ref[0] : void 0;

if (!filepath) {
  console.error("A file path is required.");
  process.exit(1);
}

filepath = path.resolve(filepath);

if (!fs.existsSync(filepath)) {
  console.error("File not found.");
  process.exit(1);
}

console.log("file is ", filepath);

lsource = new LoopingSource;

throttle = new Throttle(this.args.rate);

file = fs.createReadStream(filepath);

file.pipe(lsource);

lsource.pipe(throttle);

sock = net.connect(this.args.port, this.args.host, (function(_this) {
  return function() {
    var auth, authTimeout;
    console.log("Connected!");
    authTimeout = null;
    sock.once("readable", function() {
      var resp;
      resp = sock.read();
      if (/^HTTP\/1\.0 200 OK/.test(resp.toString())) {
        console.log("Got HTTP OK. Starting streaming.");
        clearTimeout(authTimeout);
        return throttle.pipe(sock);
      } else {
        console.error("Unknown response: " + (resp.toString()));
        return process.exit(1);
      }
    });
    sock.write("SOURCE /" + _this.args.stream + " ICE/1.0\r\n");
    if (_this.args.password) {
      auth = Buffer.from("source:" + _this.args.password, 'ascii').toString("base64");
      sock.write("Authorization: basic " + auth + "\r\n\r\n");
      console.log("Writing auth with " + auth + ".");
    }
    return authTimeout = setTimeout(function() {
      console.error("Timed out waiting for authentication.");
      return process.exit(1);
    }, 5000);
  };
})(this));

sock.on("error", (function(_this) {
  return function(err) {
    console.error("Socket error: " + err);
    return process.exit(1);
  };
})(this));

//# sourceMappingURL=icecast_source.js.map
