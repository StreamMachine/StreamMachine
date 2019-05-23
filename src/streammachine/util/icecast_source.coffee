FileSource = require "../sources/file"
net = require "net"

debug = require("debug")("sm:sources:icecast")

module.exports = class IcecastSource extends require("events").EventEmitter
    constructor: (@opts) ->
        @_connected = false
        @sock = null

        # we'll use FileSource to read the file and chunk it for us
        @fsource = new FileSource format:@opts.format, filePath:@opts.filePath, chunkDuration:0.2

        @fsource.on "data", (chunk) =>
            @sock?.write chunk.data

    #----------

    start: (cb) ->
        sFunc = =>
            @fsource.start()
            cb? null

        if @sock
            sFunc()
        else
            @_connect (err) =>
                return cb err if err
                @_connected = true
                sFunc()

    #----------

    pause: ->
        @fsource.stop()

    #----------

    _connect: (cb) ->
        # -- Open our connection to the server -- #

        @sock = net.connect @opts.port, @opts.host, =>
            debug "Connected!"

            authTimeout = null

            # we really only care about the first thing we see
            @sock.once "readable", =>
                resp = @sock.read()
                clearTimeout authTimeout

                if resp && /^HTTP\/1\.0 200 OK/.test(resp.toString())
                    debug "Got HTTP OK. Starting streaming."
                    cb null

                else
                    err = "Unknown response: #{ resp.toString() }"
                    debug err
                    cb new Error err
                    @disconnect()

            @sock.write "SOURCE /#{@opts.stream} HTTP/1.0\r\n"

            #@sock.write "User-Agent: StreamMachine IcecastSource"

            if @opts.password
                # username doesn't matter.
                auth = Buffer.from("source:#{@opts.password}",'ascii').toString("base64")
                @sock.write "Authorization: Basic #{auth}\r\n\r\n"
                debug "Writing auth with #{ auth }."

            else
                @sock.write "\r\n"

            authTimeout = setTimeout =>
                err = "Timed out waiting for authentication."
                debug err
                cb new Error err
                @disconnect()
            , 5000

        @sock.once "error", (err) =>
            debug "Socket error: #{err}"
            @disconnect()

    #----------

    disconnect: ->
        @_connected = false
        @sock?.end()
        @sock = null
        @emit "disconnect"
