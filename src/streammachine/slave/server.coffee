express = require 'express'
_       = require 'underscore'
util    = require 'util'
fs      = require 'fs'
path    = require 'path'
uuid    = require 'node-uuid'
http    = require "http"
compression = require "compression"
cors    = require "cors"
maxmind = require "maxmind"

module.exports = class Server extends require('events').EventEmitter
    constructor: (@opts) ->

        @core   = @opts.core
        @logger = @opts.logger
        @config = @opts.config

        # -- set up our express app -- #

        @app = express()
        @_server = http.createServer @app

        if @opts.config.cors?.enabled
            origin = @opts.config.cors.origin || true

            @app.use cors(origin:origin, methods:"GET,HEAD")

        @app.httpAllowHalfOpen = true
        @app.useChunkedEncodingByDefault = false

        @app.set "x-powered-by", "StreamMachine"

        # -- are we behind a geolock? -- #

        @isGeolockEnabled = (@config.geolock && @config.geolock.enabled)
        if @isGeolockEnabled
            @logger.info "Enabling 'geolock' for streams"
            @countryLookup = maxmind.open @config.geolock.config_file

        # -- are we behind a proxy? -- #

        if @config.behind_proxy
            @logger.info "Enabling 'trust proxy' for Express.js"
            @app.set "trust proxy", true

        # -- Set up sessions -- #

        if @config.session?.secret && @config.session?.key
            @app.use express.cookieParser()
            @app.use express.cookieSession
                key:    @config.session?.key
                secret: @config.session?.secret

            @app.use (req,res,next) =>
                if !req.session.userID
                    req.session.userID = uuid.v4()

                req.user_id = req.session.userID

                next()

        # -- Stream Finder -- #

        @app.param "stream", (req,res,next,key) =>
            # make sure it's a valid stream key
            if key? && s = @core.streams[ key ]
                if @isGeolockEnabled && @isGeolocked req, s, s.opts
                    if s.opts.geolock.fallback
                        res.redirect(302, s.opts.geolock.fallback)
                    else
                        res.status(403).end("Invalid Country.")
                else
                    req.stream = s
                    next()
            else
                res.status(404).end "Invalid stream.\n"

        # -- Stream Group Finder -- #

        @app.param "group", (req,res,next,key) =>
            # make sure it's a valid stream key
            if key? && s = @core.stream_groups[ key ]
                req.group = s
                next()
            else
                res.status(404).end "Invalid stream group.\n"

        # -- Funky URL Rewriters -- #

        @app.use (req,res,next) =>
            if @core.root_route
                if req.url == '/' || req.url == "/;stream.nsv" || req.url == "/;"
                    req.url = "/#{@core.root_route}"
                    next()
                else if req.url == "/listen.pls"
                    req.url = "/#{@core.root_route}.pls"
                    next()
                else
                    next()
            else
                next()

        # -- HLS Full Index Test -- #

        if @config.hls?.limit_full_index
            idx_match = ///#{@config.hls.limit_full_index}///
            @app.use (req,res,next) =>
                ua = _.compact([req.param("ua"),req.headers?['user-agent']]).join(" | ")

                if idx_match.test(ua)
                    # do nothing...
                else
                    req.hls_limit = true

                next()

        # -- Debug Logger -- #

        if @config.debug_incoming_requests
            @app.use (req,res,next) =>
                @logger.debug "Request: #{req.url}", ip:req.ip, ua:req.headers?['user-agent']
                next()

        # -- check user agent for banned clients -- #

        if @config.ua_skip
            banned = ///#{@config.ua_skip.join("|")}///

            @app.use (req,res,next) =>
                return next() unless req.headers?['user-agent'] && banned.test(req.headers["user-agent"])

                # request from banned agent...
                @logger.debug "Request from banned User-Agent: #{req.headers['user-agent']}",
                    ip:     req.ip
                    url:    req.url

                res.status(403).end("Invalid User Agent.")

        # -- Utility Routes -- #

        @app.get "/index.html", (req,res) =>
            res.set "content-type", "text/html"
            res.set "connection", "close"

            res.status(200).end """
                <html>
                    <head><title>StreamMachine</title></head>
                    <body>
                        <h1>OK</h1>
                    </body>
                </html>
            """

        @app.get "/crossdomain.xml", (req,res) =>
            res.set "content-type", "text/xml"
            res.set "connection", "close"

            res.status(200).end """
                <?xml version="1.0"?>
                <!DOCTYPE cross-domain-policy SYSTEM "http://www.macromedia.com/xml/dtds/cross-domain-policy.dtd">
                <cross-domain-policy>
                <allow-access-from domain="*" />
                </cross-domain-policy>
            """
        # -- Stream Routes -- #

        # playlist file
        @app.get "/:stream.pls", (req,res) =>
            res.set "content-type", "audio/x-scpls"
            res.set "connection", "close"

            host = req.headers?.host || req.stream.options.host

            res.status(200).end "[playlist]\nNumberOfEntries=1\nFile1=http://#{host}/#{req.stream.key}/\n"

        # -- HTTP Live Streaming -- #

        @app.get "/sg/:group.m3u8", (req,res) =>
            new @core.Outputs.live_streaming.GroupIndex req.group, req:req, res:res

        @app.get "/:stream.m3u8", compression(filter:->true), (req,res) =>
            new @core.Outputs.live_streaming.Index req.stream, req:req, res:res

        @app.get "/:stream/ts/:seg.(:format)", (req,res) =>
            new @core.Outputs.live_streaming req.stream, req:req, res:res, format:req.param("format")


        # head request
        @app.head "/:stream", (req,res) =>
            res.set "content-type", "audio/mpeg"
            res.status(200).end()

        # listen to the stream
        @app.get "/:stream", (req,res) =>
            res.set "X-Powered-By", "StreamMachine"

            # -- Stream match! -- #

            if req.param("pump")
                # pump listener pushes from the buffer as fast as possible
                new @core.Outputs.pumper req.stream, req:req, res:res

            else
                # normal live stream (with or without shoutcast)
                if req.headers['icy-metadata']
                    # -- shoutcast listener -- #
                    new @core.Outputs.shoutcast req.stream, req:req, res:res
                else
                    # -- straight mp3 listener -- #
                    new @core.Outputs.raw req.stream, req:req, res:res

    #----------

    isGeolocked: (req,stream,opts) ->
        locked = false

        if opts.geolock && opts.geolock.enabled
            data = @countryLookup.get req.ip
            country = null

            if data && data.country
                country = data.country

            if country && country.iso_code
                index = opts.geolock.countryCodes.indexOf(country.iso_code)

                if opts.geolock.mode == "blacklist"
                    locked = index >= 0

                else
                    locked = index < 0

            if locked && country
                # request from invalid country...
                @logger.debug "Request from invalid country: #{country.names.es} (#{country.iso_code})",
                    ip: req.ip

        locked

    #----------

    listen: (port,cb) ->
        @logger.info "SlaveWorker called listen"
        @hserver = @app.listen port, =>
            #@io = require("socket.io").listen @hserver
            #@emit "io_connected", @io
            cb?(@hserver)
        @hserver

    #----------

    close: ->
        @logger.info "Slave server asked to stop listening."
        @hserver?.close => @logger.info "Slave server listening stopped."

    #----------

    handle: (conn) ->
        @_server.emit "connection", conn
        conn.resume()
