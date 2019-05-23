fs          = require "fs"
path        = require "path"
net = require "net"
Throttle    = require "throttle"

@args = require("optimist")
    .usage("Usage: $0 --host localhost --port 8001 --stream foo --password abc123 [file]")
    .describe
        host:       "Server"
        port:       "Server source port"
        stream:     "Stream key"
        password:   "Stream password"
        rate:       "Throttle rate for streaming"
    .default
        rate:       32000
    .demand("host","port","stream")
    .argv

# -- Looping Source -- #

class LoopingSource extends require('stream').Duplex
    constructor: (opts) ->
        @_reading = false

        @_data = Buffer.alloc 0
        @_readPos = 0

        super opts

    #----------

    _write: (chunk,encoding,cb) ->
        buf = Buffer.concat([@_data,chunk])
        @_data = buf
        console.log "_data length is now ", @_data.length
        @emit "readable" if !@reading
        cb()

    #----------

    _read: (size) ->
        if @_reading
            console.log "_read while reading"
            return true

        if @_data.length == 0
            @push ''
            return true

        @_reading = true

        rFunc = =>
            remaining = Math.min (@_data.length - @_readPos), size

            console.log "reading from #{ @_readPos } with #{ remaining }"
            buf = Buffer.from remaining
            @_data.copy buf, 0, @_readPos, @_readPos.remaining

            @_readPos = @_readPos + remaining

            if @_readPos >= @_data.length
                @_readPos = 0

            console.log "pushing buffer of #{ buf.length }"
            if @push buf, 'binary'
                rFunc()
            else
                @_reading = false

        rFunc()

# -- Make sure they gave us a file -- #

filepath = @args._?[0]

if !filepath
    console.error "A file path is required."
    process.exit(1)

filepath = path.resolve(filepath)

if !fs.existsSync(filepath)
    console.error "File not found."
    process.exit(1)

console.log "file is ", filepath

# -- Read the file -- #

lsource = new LoopingSource
throttle = new Throttle @args.rate
file = fs.createReadStream filepath
file.pipe lsource
lsource.pipe throttle

# -- Open our connection to the server -- #

sock = net.connect @args.port, @args.host, =>
    console.log "Connected!"

    authTimeout = null

    # we really only care about the first thing we see
    sock.once "readable", =>
        resp = sock.read()

        if /^HTTP\/1\.0 200 OK/.test(resp.toString())
            console.log "Got HTTP OK. Starting streaming."

            clearTimeout authTimeout
            throttle.pipe(sock)

        else
            console.error "Unknown response: #{ resp.toString() }"
            process.exit(1)

    sock.write "SOURCE /#{@args.stream} ICE/1.0\r\n"

    if @args.password
        # username doesn't matter.
        auth = Buffer.from("source:#{@args.password}",'ascii').toString("base64")
        sock.write "Authorization: basic #{auth}\r\n\r\n"
        console.log "Writing auth with #{ auth }."

    authTimeout = setTimeout =>
        console.error "Timed out waiting for authentication."
        process.exit(1)
    , 5000

sock.on "error", (err) =>
    console.error "Socket error: #{err}"
    process.exit(1)


