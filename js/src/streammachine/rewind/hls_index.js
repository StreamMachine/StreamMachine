var HLSIndex, _,
  __hasProp = {}.hasOwnProperty,
  __extends = function(child, parent) { for (var key in parent) { if (__hasProp.call(parent, key)) child[key] = parent[key]; } function ctor() { this.constructor = child; } ctor.prototype = parent.prototype; child.prototype = new ctor(); child.__super__ = parent.prototype; return child; };

_ = require("underscore");

module.exports = HLSIndex = (function() {
  function HLSIndex(stream, tz, group) {
    this.stream = stream;
    this.tz = tz;
    this.group = group;
    this._shouldRun = false;
    this._running = false;
    this._segment_idx = {};
    this._segments = [];
    this._segment_length = null;
    this._header = null;
    this._index = null;
    this._short_header = null;
    this._short_index = null;
  }

  HLSIndex.prototype.disconnect = function() {
    return this.stream = null;
  };

  HLSIndex.prototype.loadSnapshot = function(snapshot) {
    if (snapshot) {
      this._segments = snapshot.segments;
      this._segment_duration = snapshot.segment_duration;
      return this.queueIndex();
    }
  };

  HLSIndex.prototype.queueIndex = function() {
    this._shouldRun = true;
    return this._runIndex();
  };

  HLSIndex.prototype._runIndex = function() {
    var b, dseq, has_disc, head, i, id, idx_length, idx_segs, old_seg_ids, s, seg, seg_ids, seg_map, segs, short_head, short_length, _after, _i, _j, _k, _l, _len, _len1, _len2, _len3, _ref, _ref1, _ref2, _short_length, _short_start;
    if (this._running || !this.stream) {
      return false;
    }
    this._running = true;
    this._shouldRun = false;
    _after = (function(_this) {
      return function() {
        _this._running = false;
        if (_this._shouldRun) {
          return _this._runIndex();
        }
      };
    })(this);
    segs = this._segments.slice(0);
    if (segs.length < 3) {
      this.header = null;
      this._index = null;
      _after();
      return false;
    }
    _short_length = 120 / this._segment_duration;
    _short_start = segs.length - 1 - _short_length;
    if (_short_start < 2) {
      _short_start = 2;
    }
    head = Buffer.from("#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:" + this._segment_duration + "\n#EXT-X-MEDIA-SEQUENCE:" + segs[2].id + "\n#EXT-X-DISCONTINUITY-SEQUENCE:" + segs[2].discontinuitySeq + "\n#EXT-X-INDEPENDENT-SEGMENTS\n");
    short_head = Buffer.from("#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:" + this._segment_duration + "\n#EXT-X-MEDIA-SEQUENCE:" + segs[_short_start].id + "\n#EXT-X-DISCONTINUITY-SEQUENCE:" + segs[_short_start].discontinuitySeq + "\n#EXT-X-INDEPENDENT-SEGMENTS\n");
    idx_segs = [];
    idx_length = 0;
    seg_ids = (function() {
      var _i, _len, _results;
      _results = [];
      for (_i = 0, _len = segs.length; _i < _len; _i++) {
        seg = segs[_i];
        _results.push(String(seg.id));
      }
      return _results;
    })();
    dseq = segs[1].discontinuitySeq;
    _ref = segs.slice(2);
    for (i = _i = 0, _len = _ref.length; _i < _len; i = ++_i) {
      seg = _ref[i];
      if (!this._segment_idx[seg.id]) {
        has_disc = !(seg.discontinuitySeq === dseq);
        seg.idx_buffer = Buffer.from("" + (has_disc ? "#EXT-X-DISCONTINUITY\n" : "") + "#EXTINF:" + (seg.duration / 1000) + ",\n#EXT-X-PROGRAM-DATE-TIME:" + (this.tz(seg.ts_actual, "%FT%T.%3N%:z")) + "\n/" + this.stream.key + "/ts/" + seg.id + "." + this.stream.opts.format);
        this._segment_idx[seg.id] = seg;
      }
      b = this._segment_idx[seg.id].idx_buffer;
      idx_length += b.length;
      idx_segs.push(b);
      dseq = seg.discontinuitySeq;
    }
    seg_map = {};
    for (_j = 0, _len1 = segs.length; _j < _len1; _j++) {
      s = segs[_j];
      seg_map[s.id] = s;
    }
    this._header = head;
    this._index = idx_segs;
    this._index_length = idx_length;
    this._short_header = short_head;
    this._short_index = idx_segs.slice(_short_start);
    short_length = 0;
    _ref1 = this._short_index;
    for (_k = 0, _len2 = _ref1.length; _k < _len2; _k++) {
      b = _ref1[_k];
      short_length += b.length;
    }
    this._short_length = short_length;
    old_seg_ids = Object.keys(this._segment_idx);
    _ref2 = _(old_seg_ids).difference(seg_ids);
    for (_l = 0, _len3 = _ref2.length; _l < _len3; _l++) {
      id = _ref2[_l];
      if (this._segment_idx[id]) {
        delete this._segment_idx[id];
      }
    }
    return _after();
  };

  HLSIndex.prototype.short_index = function(session, cb) {
    var writer;
    session = session ? Buffer.from(session + "\n") : Buffer.from("\n");
    if (!this._short_header) {
      return cb(null, null);
    }
    writer = new HLSIndex.Writer(this._short_header, this._short_index, this._short_length, session);
    return cb(null, writer);
  };

  HLSIndex.prototype.index = function(session, cb) {
    var writer;
    session = session ? Buffer.from(session + "\n") : Buffer.from("\n");
    if (!this._header) {
      return cb(null, null);
    }
    writer = new HLSIndex.Writer(this._header, this._index, this._index_length, session);
    return cb(null, writer);
  };

  HLSIndex.prototype.pumpSegment = function(rewinder, id, cb) {
    var dur, s;
    if (s = this._segment_idx[Number(id)]) {
      dur = this.stream.secsToOffset(s.duration / 1000);
      return this.stream.pumpFrom(rewinder, s.ts_actual, dur, false, (function(_this) {
        return function(err, info) {
          if (err) {
            return cb(err);
          } else {
            return cb(null, _.extend(info, {
              pts: s.pts
            }));
          }
        };
      })(this));
    } else {
      return cb("Segment not found in index.");
    }
  };

  HLSIndex.Writer = (function(_super) {
    __extends(Writer, _super);

    function Writer(header, index, ilength, session) {
      this.header = header;
      this.index = index;
      this.ilength = ilength;
      this.session = session;
      Writer.__super__.constructor.apply(this, arguments);
      this._sentHeader = false;
      this._idx = 0;
      this._length = this.header.length + this.ilength + (this.session.length * this.index.length);
    }

    Writer.prototype.length = function() {
      return this._length;
    };

    Writer.prototype._read = function(size) {
      var bufs, sent;
      sent = 0;
      bufs = [];
      if (!this._sentHeader) {
        bufs.push(this.header);
        this._sentHeader = true;
        sent += this.header.length;
      }
      while (true) {
        bufs.push(this.index[this._idx]);
        bufs.push(this.session);
        sent += this.index[this._idx].length;
        sent += this.session.length;
        this._idx += 1;
        if ((sent > size) || this._idx === this.index.length) {
          break;
        }
      }
      this.push(Buffer.concat(bufs, sent));
      if (this._idx === this.index.length) {
        return this.push(null);
      }
    };

    return Writer;

  })(require("stream").Readable);

  return HLSIndex;

})();

//# sourceMappingURL=hls_index.js.map
