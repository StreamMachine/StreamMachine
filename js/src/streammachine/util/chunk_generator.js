var ChunkGenerator, debug, _,
  __hasProp = {}.hasOwnProperty,
  __extends = function(child, parent) { for (var key in parent) { if (__hasProp.call(parent, key)) child[key] = parent[key]; } function ctor() { this.constructor = child; } ctor.prototype = parent.prototype; child.prototype = new ctor(); child.__super__ = parent.prototype; return child; };

_ = require("underscore");

debug = require("debug")("sm:util:chunk_generator");

module.exports = ChunkGenerator = (function(_super) {
  __extends(ChunkGenerator, _super);

  function ChunkGenerator(start_ts, chunk_duration) {
    this.start_ts = start_ts;
    this.chunk_duration = chunk_duration;
    this._count_f = 0;
    this._count_b = 1;
    ChunkGenerator.__super__.constructor.call(this, {
      objectMode: true
    });
  }

  ChunkGenerator.prototype.skip_forward = function(count, cb) {
    this._count_f += count;
    return typeof cb === "function" ? cb() : void 0;
  };

  ChunkGenerator.prototype.skip_backward = function(count, cb) {
    this._count_b += count;
    return typeof cb === "function" ? cb() : void 0;
  };

  ChunkGenerator.prototype.ts = function() {
    return {
      forward: new Date(Number(this.start_ts) + this._count_f * this.chunk_duration),
      backward: new Date(Number(this.start_ts) + this._count_b * this.chunk_duration)
    };
  };

  ChunkGenerator.prototype.forward = function(count, cb) {
    var af;
    af = _.after(count, (function(_this) {
      return function() {
        _this._count_f += count;
        _this.emit("readable");
        debug("Forward emit " + count + " chunks. Finished at " + (new Date(Number(_this.start_ts) + _this._count_f * _this.chunk_duration)));
        return typeof cb === "function" ? cb() : void 0;
      };
    })(this));
    return _(count).times((function(_this) {
      return function(c) {
        var chunk;
        chunk = {
          ts: new Date(Number(_this.start_ts) + (_this._count_f + c) * _this.chunk_duration),
          duration: _this.chunk_duration,
          data: Buffer.alloc(0)
        };
        _this.push(chunk);
        return af();
      };
    })(this));
  };

  ChunkGenerator.prototype.backward = function(count, cb) {
    var af;
    af = _.after(count, (function(_this) {
      return function() {
        _this._count_b += count;
        _this.emit("readable");
        debug("Backward emit " + count + " chunks. Finished at " + (new Date(Number(_this.start_ts) + _this._count_b * _this.chunk_duration)));
        return typeof cb === "function" ? cb() : void 0;
      };
    })(this));
    return _(count).times((function(_this) {
      return function(c) {
        var chunk;
        chunk = {
          ts: new Date(Number(_this.start_ts) - (_this._count_b + c) * _this.chunk_duration),
          duration: _this.chunk_duration,
          data: Buffer.alloc(0)
        };
        _this.push(chunk);
        return af();
      };
    })(this));
  };

  ChunkGenerator.prototype.end = function() {
    return this.push(null);
  };

  ChunkGenerator.prototype._read = function(size) {};

  return ChunkGenerator;

})(require("stream").Readable);

//# sourceMappingURL=chunk_generator.js.map
