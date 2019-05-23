var BaseOutput, LiveStreaming, PTS_TAG, s, tz, uuid, _,
  __hasProp = {}.hasOwnProperty,
  __extends = function(child, parent) { for (var key in parent) { if (__hasProp.call(parent, key)) child[key] = parent[key]; } function ctor() { this.constructor = child; } ctor.prototype = parent.prototype; child.prototype = new ctor(); child.__super__ = parent.prototype; return child; };

_ = require("underscore");

tz = require("timezone");

uuid = require("node-uuid");

BaseOutput = require("./base");

PTS_TAG = Buffer.from((function() {
  var _i, _len, _ref, _results;
  _ref = "49 44 33 04 00 00 00 00 00 3F 50 52 49 56 00 00 00 35 00 00 63 6F 6D\n2E 61 70 70 6C 65 2E 73 74 72 65 61 6D 69 6E 67 2E 74 72 61 6E 73 70\n6F 72 74 53 74 72 65 61 6D 54 69 6D 65 73 74 61 6D 70 00 00 00 00 00\n00 00 00 00".split(/\s+/);
  _results = [];
  for (_i = 0, _len = _ref.length; _i < _len; _i++) {
    s = _ref[_i];
    _results.push(Number("0x" + s));
  }
  return _results;
})());

module.exports = LiveStreaming = (function(_super) {
  __extends(LiveStreaming, _super);

  function LiveStreaming(stream, opts) {
    this.stream = stream;
    this.opts = opts;
    LiveStreaming.__super__.constructor.call(this, "live_streaming");
    this.stream.listen(this, {
      live_segment: this.opts.req.param("seg"),
      pumpOnly: true
    }, (function(_this) {
      return function(err, playHead, info) {
        var headers, tag;
        if (err) {
          _this.opts.res.status(404).end("Segment not found.");
          return false;
        }
        tag = null;
        if (info.pts) {
          tag = Buffer.from(PTS_TAG);
          if (info.pts > Math.pow(2, 32) - 1) {
            tag[0x44] = 0x01;
            tag.writeUInt32BE(info.pts - (Math.pow(2, 32) - 1), 0x45);
          } else {
            tag.writeUInt32BE(info.pts, 0x45);
          }
        }
        headers = {
          "Content-Type": _this.stream.opts.format === "mp3" ? "audio/mpeg" : _this.stream.opts.format === "aac" ? "audio/aac" : "unknown",
          "Connection": "close",
          "Content-Length": info.length + (tag != null ? tag.length : void 0) || 0
        };
        _this.opts.res.writeHead(200, headers);
        if (tag) {
          _this.opts.res.write(tag);
        }
        playHead.pipe(_this.opts.res);
        _this.opts.res.on("finish", function() {
          return playHead.disconnect();
        });
        _this.opts.res.on("close", function() {
          return playHead.disconnect();
        });
        return _this.opts.res.on("end", function() {
          return playHead.disconnect();
        });
      };
    })(this));
  }

  LiveStreaming.prototype.prepForHandoff = function(cb) {
    return cb(true);
  };

  LiveStreaming.Index = (function(_super1) {
    __extends(Index, _super1);

    function Index(stream, opts) {
      var outFunc, session_info;
      this.stream = stream;
      this.opts = opts;
      Index.__super__.constructor.call(this, "live_streaming");
      session_info = this.client.session_id && this.client.pass_session ? "?session_id=" + this.client.session_id : void 0;
      if (this.opts.req.param("ua")) {
        session_info = session_info ? "" + session_info + "&ua=" + (this.opts.req.param("ua")) : "?ua=" + (this.opts.req.param("ua"));
      }
      if (!this.stream.hls) {
        this.opts.res.status(500).end("No data.");
        return;
      }
      outFunc = (function(_this) {
        return function(err, writer) {
          if (writer) {
            _this.opts.res.writeHead(200, {
              "Content-type": "application/vnd.apple.mpegurl",
              "Content-length": writer.length()
            });
            return writer.pipe(_this.opts.res);
          } else {
            return _this.opts.res.status(500).end("No data.");
          }
        };
      })(this);
      if (this.opts.req.hls_limit) {
        this.stream.hls.short_index(session_info, outFunc);
      } else {
        this.stream.hls.index(session_info, outFunc);
      }
    }

    return Index;

  })(BaseOutput);

  LiveStreaming.GroupIndex = (function(_super1) {
    __extends(GroupIndex, _super1);

    function GroupIndex(group, opts) {
      this.group = group;
      this.opts = opts;
      GroupIndex.__super__.constructor.call(this, "live_streaming");
      this.opts.res.writeHead(200, {
        "Content-type": "application/vnd.apple.mpegurl"
      });
      this.group.startSession(this.client, (function(_this) {
        return function(err) {
          var key, session_bits, url, _ref;
          _this.opts.res.write("#EXTM3U\n");
          _ref = _this.group.streams;
          for (key in _ref) {
            s = _ref[key];
            url = "/" + s.key + ".m3u8";
            session_bits = [];
            if (_this.client.pass_session) {
              session_bits.push("session_id=" + _this.client.session_id);
            }
            if (_this.opts.req.param("ua")) {
              session_bits.push("ua=" + (_this.opts.req.param("ua")));
            }
            if (session_bits.length > 0) {
              url = "" + url + "?" + (session_bits.join("&"));
            }
            _this.opts.res.write("#EXT-X-STREAM-INF:BANDWIDTH=" + s.opts.bandwidth + ",CODECS=\"" + s.opts.codec + "\"\n" + url + "\n");
          }
          return _this.opts.res.end();
        };
      })(this));
    }

    return GroupIndex;

  })(BaseOutput);

  return LiveStreaming;

})(BaseOutput);

//# sourceMappingURL=live_streaming.js.map
