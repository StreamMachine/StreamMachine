var Server, compression, cors, express, fs, http, maxmind, path, util, uuid, _,
  __hasProp = {}.hasOwnProperty,
  __extends = function(child, parent) { for (var key in parent) { if (__hasProp.call(parent, key)) child[key] = parent[key]; } function ctor() { this.constructor = child; } ctor.prototype = parent.prototype; child.prototype = new ctor(); child.__super__ = parent.prototype; return child; };

express = require('express');

_ = require('underscore');

util = require('util');

fs = require('fs');

path = require('path');

uuid = require('node-uuid');

http = require("http");

compression = require("compression");

cors = require("cors");

maxmind = require("maxmind");

module.exports = Server = (function(_super) {
  __extends(Server, _super);

  function Server(opts) {
    var banned, idx_match, origin, _ref, _ref1, _ref2, _ref3, _ref4, _ref5;
    this.opts = opts;
    this.core = this.opts.core;
    this.logger = this.opts.logger;
    this.config = this.opts.config;
    this.app = express();
    this._server = http.createServer(this.app);
    if ((_ref = this.opts.config.cors) != null ? _ref.enabled : void 0) {
      origin = this.opts.config.cors.origin || true;
      this.app.use(cors({
        origin: origin,
        methods: "GET,HEAD"
      }));
    }
    this.app.httpAllowHalfOpen = true;
    this.app.useChunkedEncodingByDefault = false;
    this.app.set("x-powered-by", "StreamMachine");
    this.isGeolockEnabled = this.config.geolock && this.config.geolock.enabled;
    if (this.isGeolockEnabled) {
      this.logger.info("Enabling 'geolock' for streams");
      this.countryLookup = maxmind.open(this.config.geolock.config_file);
    }
    if (this.config.behind_proxy) {
      this.logger.info("Enabling 'trust proxy' for Express.js");
      this.app.set("trust proxy", true);
    }
    if (((_ref1 = this.config.session) != null ? _ref1.secret : void 0) && ((_ref2 = this.config.session) != null ? _ref2.key : void 0)) {
      this.app.use(express.cookieParser());
      this.app.use(express.cookieSession({
        key: (_ref3 = this.config.session) != null ? _ref3.key : void 0,
        secret: (_ref4 = this.config.session) != null ? _ref4.secret : void 0
      }));
      this.app.use((function(_this) {
        return function(req, res, next) {
          if (!req.session.userID) {
            req.session.userID = uuid.v4();
          }
          req.user_id = req.session.userID;
          return next();
        };
      })(this));
    }
    this.app.param("stream", (function(_this) {
      return function(req, res, next, key) {
        var s;
        if ((key != null) && (s = _this.core.streams[key])) {
          if (_this.isGeolockEnabled && _this.isGeolocked(req, s, s.opts)) {
            if (s.opts.geolock.fallback) {
              return res.redirect(302, s.opts.geolock.fallback);
            } else {
              return res.status(403).end("Invalid Country.");
            }
          } else {
            req.stream = s;
            return next();
          }
        } else {
          return res.status(404).end("Invalid stream.\n");
        }
      };
    })(this));
    this.app.param("group", (function(_this) {
      return function(req, res, next, key) {
        var s;
        if ((key != null) && (s = _this.core.stream_groups[key])) {
          req.group = s;
          return next();
        } else {
          return res.status(404).end("Invalid stream group.\n");
        }
      };
    })(this));
    this.app.use((function(_this) {
      return function(req, res, next) {
        if (_this.core.root_route) {
          if (req.url === '/' || req.url === "/;stream.nsv" || req.url === "/;") {
            req.url = "/" + _this.core.root_route;
            return next();
          } else if (req.url === "/listen.pls") {
            req.url = "/" + _this.core.root_route + ".pls";
            return next();
          } else {
            return next();
          }
        } else {
          return next();
        }
      };
    })(this));
    if ((_ref5 = this.config.hls) != null ? _ref5.limit_full_index : void 0) {
      idx_match = RegExp("" + this.config.hls.limit_full_index);
      this.app.use((function(_this) {
        return function(req, res, next) {
          var ua, _ref6;
          ua = _.compact([req.param("ua"), (_ref6 = req.headers) != null ? _ref6['user-agent'] : void 0]).join(" | ");
          if (idx_match.test(ua)) {

          } else {
            req.hls_limit = true;
          }
          return next();
        };
      })(this));
    }
    if (this.config.debug_incoming_requests) {
      this.app.use((function(_this) {
        return function(req, res, next) {
          var _ref6;
          _this.logger.debug("Request: " + req.url, {
            ip: req.ip,
            ua: (_ref6 = req.headers) != null ? _ref6['user-agent'] : void 0
          });
          return next();
        };
      })(this));
    }
    if (this.config.ua_skip) {
      banned = RegExp("" + (this.config.ua_skip.join("|")));
      this.app.use((function(_this) {
        return function(req, res, next) {
          var _ref6;
          if (!(((_ref6 = req.headers) != null ? _ref6['user-agent'] : void 0) && banned.test(req.headers["user-agent"]))) {
            return next();
          }
          _this.logger.debug("Request from banned User-Agent: " + req.headers['user-agent'], {
            ip: req.ip,
            url: req.url
          });
          return res.status(403).end("Invalid User Agent.");
        };
      })(this));
    }
    this.app.get("/index.html", (function(_this) {
      return function(req, res) {
        res.set("content-type", "text/html");
        res.set("connection", "close");
        return res.status(200).end("<html>\n    <head><title>StreamMachine</title></head>\n    <body>\n        <h1>OK</h1>\n    </body>\n</html>");
      };
    })(this));
    this.app.get("/crossdomain.xml", (function(_this) {
      return function(req, res) {
        res.set("content-type", "text/xml");
        res.set("connection", "close");
        return res.status(200).end("<?xml version=\"1.0\"?>\n<!DOCTYPE cross-domain-policy SYSTEM \"http://www.macromedia.com/xml/dtds/cross-domain-policy.dtd\">\n<cross-domain-policy>\n<allow-access-from domain=\"*\" />\n</cross-domain-policy>");
      };
    })(this));
    this.app.get("/:stream.pls", (function(_this) {
      return function(req, res) {
        var host, _ref6;
        res.set("content-type", "audio/x-scpls");
        res.set("connection", "close");
        host = ((_ref6 = req.headers) != null ? _ref6.host : void 0) || req.stream.options.host;
        return res.status(200).end("[playlist]\nNumberOfEntries=1\nFile1=http://" + host + "/" + req.stream.key + "/\n");
      };
    })(this));
    this.app.get("/sg/:group.m3u8", (function(_this) {
      return function(req, res) {
        return new _this.core.Outputs.live_streaming.GroupIndex(req.group, {
          req: req,
          res: res
        });
      };
    })(this));
    this.app.get("/:stream.m3u8", compression({
      filter: function() {
        return true;
      }
    }), (function(_this) {
      return function(req, res) {
        return new _this.core.Outputs.live_streaming.Index(req.stream, {
          req: req,
          res: res
        });
      };
    })(this));
    this.app.get("/:stream/ts/:seg.(:format)", (function(_this) {
      return function(req, res) {
        return new _this.core.Outputs.live_streaming(req.stream, {
          req: req,
          res: res,
          format: req.param("format")
        });
      };
    })(this));
    this.app.head("/:stream", (function(_this) {
      return function(req, res) {
        res.set("content-type", "audio/mpeg");
        return res.status(200).end();
      };
    })(this));
    this.app.get("/:stream", (function(_this) {
      return function(req, res) {
        res.set("X-Powered-By", "StreamMachine");
        if (req.param("pump")) {
          return new _this.core.Outputs.pumper(req.stream, {
            req: req,
            res: res
          });
        } else {
          if (req.headers['icy-metadata']) {
            return new _this.core.Outputs.shoutcast(req.stream, {
              req: req,
              res: res
            });
          } else {
            return new _this.core.Outputs.raw(req.stream, {
              req: req,
              res: res
            });
          }
        }
      };
    })(this));
  }

  Server.prototype.isGeolocked = function(req, stream, opts) {
    var country, data, index, locked;
    locked = false;
    if (opts.geolock && opts.geolock.enabled) {
      data = this.countryLookup.get(req.ip);
      country = null;
      if (data && data.country) {
        country = data.country;
      }
      if (country && country.iso_code) {
        index = opts.geolock.countryCodes.indexOf(country.iso_code);
        if (opts.geolock.mode === "blacklist") {
          locked = index >= 0;
        } else {
          locked = index < 0;
        }
      }
      if (locked && country) {
        this.logger.debug("Request from invalid country: " + country.names.es + " (" + country.iso_code + ")", {
          ip: req.ip
        });
      }
    }
    return locked;
  };

  Server.prototype.listen = function(port, cb) {
    this.logger.info("SlaveWorker called listen");
    this.hserver = this.app.listen(port, (function(_this) {
      return function() {
        return typeof cb === "function" ? cb(_this.hserver) : void 0;
      };
    })(this));
    return this.hserver;
  };

  Server.prototype.close = function() {
    var _ref;
    this.logger.info("Slave server asked to stop listening.");
    return (_ref = this.hserver) != null ? _ref.close((function(_this) {
      return function() {
        return _this.logger.info("Slave server listening stopped.");
      };
    })(this)) : void 0;
  };

  Server.prototype.handle = function(conn) {
    this._server.emit("connection", conn);
    return conn.resume();
  };

  return Server;

})(require('events').EventEmitter);

//# sourceMappingURL=server.js.map
