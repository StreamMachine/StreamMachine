net     = require "net"
express = require "express"

debug = require("debug")("sm:master:source_in")

IcecastSource = require "../sources/icecast"

module.exports = class SourceIn extends require("events").EventEmitter
    constructor: (opts) ->
        @core = opts.core

        @log = @core.log.child mode:"sourcein"

        # grab our listening port
        @port = opts.port

        @behind_proxy = opts.behind_proxy

        # create our server

        @server = net.createServer (c) => @_connection(c)

    listen: (spec=@port) ->
        #@core.log.debug "SourceIn listening on ", spec:spec
        debug "SourceIn listening on #{spec}"
        @server.listen spec

    _connection: (sock) =>
        @log.debug "Incoming source attempt."

        # immediately attach an error listener so that a connection reset
        # doesn't crash the whole system
        sock.on "error", (err) =>
            @log.debug "Source socket errored with #{err}"

        # set a timeout for successful / unsuccessful parsing
        timer = setTimeout =>
            @log.debug "Incoming source connection failed to validate before timeout."

            sock.write "HTTP/1.0 400 Bad Request\r\n"
            sock.end "Unable to validate source connection.\r\n"
        , 2000

        # -- incoming data -- #

        parser = new SourceIn.IcyParser SourceIn.IcyParser.REQUEST

        readerF = =>
            parser.execute d while d = sock.read()
        sock.on "readable", readerF

        parser.once "invalid", =>
            # disconnect our reader
            sock.removeListener "readable", readerF

            # close the connection
            sock.end "HTTP/1.0 400 Bad Request\n\n"

        parser.once "headersComplete", (headers) =>
            # cancel our timeout
            clearTimeout timer

            if /^(ICE|HTTP)$/.test(parser.info.protocol) && /^(SOURCE|PUT)$/.test(parser.info.method)
                @log.debug "ICY SOURCE attempt.", url:parser.info.url
                @_trySource sock, parser.info

                # get out of the way
                sock.removeListener "readable", readerF

    _trySource: (sock,info) =>
        _authFunc = (mount) =>
            # first, make sure the authorization header contains the right password
            @log.debug "Trying to authenticate ICY source for #{mount.key}"
            if info.headers.authorization && @_authorize(mount.password,info.headers.authorization)
                sock.write "HTTP/1.0 200 OK\n\n"
                @log.debug "ICY source authenticated for #{mount.key}."

                # if we're behind a proxy, look for the true IP address
                source_ip = sock.remoteAddress
                if @behind_proxy && info.headers['x-forwarded-for']
                    source_ip = info.headers['x-forwarded-for']

                # now create a new source
                source = new IcecastSource
                    format:     mount.opts.format
                    sock:       sock
                    headers:    info.headers
                    logger:     mount.log
                    source_ip:  source_ip

                mount.addSource source

            else
                @log.debug "ICY source failed to authenticate for #{mount.key}."
                sock.write "HTTP/1.0 401 Unauthorized\r\n"
                sock.end "Invalid source or password.\r\n"


        # -- source request... is the endpoint one that we recognize? -- #

        if Object.keys(@core.source_mounts).length > 0 && m = ///^/(#{Object.keys(@core.source_mounts).join("|")})///.exec info.url
            debug "Incoming source matched mount: #{m[1]}"
            mount = @core.source_mounts[ m[1] ]
            _authFunc mount

        else
            debug "Incoming source matched nothing. Disconnecting."
            @log.debug "ICY source attempted to connect to bad URL.", url:info.url

            sock.write "HTTP/1.0 401 Unauthorized\r\n"
            sock.end "Invalid source or password.\r\n"

    _tmp: ->
        if ///^/admin/metadata///.match req.url
            res.writeHead 200, headers
            res.end "OK"

        else
            res.writeHead 400, headers
            res.end "Invalid method #{res.method}."

    #----------

    _authorize: (stream_passwd,header) ->
        # split the auth type from the value
        [type,value] = header.split " "

        if type.toLowerCase() == "basic"
            value = Buffer.from(value, 'base64').toString('ascii')
            [user,pass] = value.split ":"

            if pass == stream_passwd
                true
            else
                false
        else
            false

    #----------

    class @IcyParser extends require("events").EventEmitter
        constructor: (type) ->
            @["INIT_"+type]()
            @offset = 0

        @REQUEST:    "REQUEST"
        @RESPONSE:   "RESPONSE"

        reinitialize: @

        execute: (@chunk) ->
            @offset = 0
            @end = @chunk.length

            while @offset < @end
                @[@state]()
                @offset++;

            true

        INIT_REQUEST: ->
            @state = "REQUEST_LINE"
            @lineState = "DATA"
            @info = headers:{}

        consumeLine: ->
            @captureStart = @offset if !@captureStart?

            byte = @chunk[@offset]
            if byte == 0x0d && @lineState == "DATA" # \r
                @captureEnd = @offset
                @lineState = "ENDING"
                return

            if @lineState == "ENDING"
                @lineState = "DATA"
                return if byte != 0x0a

                line = @chunk.toString "ascii", @captureStart, @captureEnd

                @captureStart = undefined
                @captureEnd = undefined

                debug "Parser request line: #{line}"
                return line

        requestExp: /^([A-Z]+) (.*) (ICE|HTTP)\/(1).(0|1)$/;

        REQUEST_LINE: ->
            line = @consumeLine()

            return if !line?

            match = @requestExp.exec line

            if match
                [@info.method,@info.url,@info.protocol,@info.versionMajor,@info.versionMinor] = match[1..5]
            else
                # this isn't a request line that we understand... we should
                # close the connection
                @emit "invalid"

            @info.request_offset = @offset
            @info.request_line = line

            @state = "HEADER"

        headerExp: /^([^:]+): *(.*)$/

        HEADER: ->
            line = @consumeLine()

            return if !line?

            if line
                match = @headerExp.exec line
                @info.headers[match[1].toLowerCase()] = match[2]
            else
                @emit "headersComplete", @info.headers
                #@state = "BODY"
