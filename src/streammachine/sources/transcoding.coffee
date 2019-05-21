_               = require "underscore"
FFmpeg          = require "fluent-ffmpeg"
PassThrough     = require("stream").PassThrough

Debounce        = require "../util/debounce"

debug = require("debug")("sm:sources:transcoding")

module.exports = class TranscodingSource extends require("./base")
    TYPE: -> "Transcoding (#{if @connected then "Connected" else "Waiting"})"

    constructor: (@opts) ->
        super skipParser:true

        @_disconnected = false

        @d = require("domain").create()
        @d.on "error", (err) =>
            @log?.error "TranscodingSource domain error:" + err
            debug "Domain error: #{err}", err

            @disconnect()

        @d.run =>
            @_queue = []

            @o_stream = @opts.stream

            @last_ts = null

            # we start up an ffmpeg transcoder and then listen for data events
            # from our source. Each time we get a chunk of audio data, we feed
            # it into ffmpeg.  We then run the stream of transcoded data that
            # comes back through our parser to re-chunk it. We count chunks to
            # attach the right timing information to the chunks that come out

            @_buf = new PassThrough
            @ffmpeg = new FFmpeg( source:@_buf, captureStderr:false ).addOptions @opts.ffmpeg_args.split("|")

            @ffmpeg.on "start", (cmd) =>
                @log?.info "ffmpeg started with #{ cmd }"

            @ffmpeg.on "error", (err, stdout, stderr) =>
                if err.code == "ENOENT"
                    @log?.error "ffmpeg failed to start."
                    @disconnect()
                else
                    @log?.error "ffmpeg transcoding error: #{ err }"
                    @log?.error "ffmpeg transcoding error stdout: #{ stdout }"
                    @log?.error "ffmpeg transcoding error stderr: #{ stderr }"
                    @disconnect()

            @ffmpeg.writeToStream @parser

            # -- watch for discontinuities -- #

            @_pingData = new Debounce (@opts.discontinuityTimeout || 30*1000), (last_ts) =>
                # data has stopped flowing. mark a discontinuity in the chunker.
                @log?.info "Transcoder data interupted. Marking discontinuity."
                @emit "discontinuity_begin", last_ts

                @o_stream.once "data", (chunk) =>
                    @log?.info "Transcoder data resumed. Reseting time to #{chunk.ts}."
                    @emit "discontinuity_end", chunk.ts, last_ts
                    @chunker.resetTime chunk.ts

            # -- chunking -- #

            @oDataFunc = (chunk) =>
                @_pingData.ping()
                @_buf.write chunk.data

            @oFirstDataFunc = (first_chunk) =>
                @emit "connected"
                @connected = true

                @oFirstDataFunc = null

                @chunker = new TranscodingSource.FrameChunker @emitDuration * 1000, first_chunk.ts

                @parser.on "frame", (frame,header) =>
                    # we need to re-apply our chunking logic to the output
                    @chunker.write frame:frame, header:header

                @chunker.on "readable", =>
                    while c = @chunker.read()
                        @last_ts = c.ts
                        @emit "data", c

                @o_stream.on "data", @oDataFunc

                @_buf.write first_chunk.data

            @o_stream.once "data", @oFirstDataFunc

            # -- watch for vitals -- #

            @parser.once "header", (header) =>
                # -- compute frames per second and stream key -- #

                @framesPerSec   = header.frames_per_sec
                @streamKey      = header.stream_key

                @log?.debug "setting framesPerSec to ", frames:@framesPerSec
                @log?.debug "first header is ", header

                # -- send out our stream vitals -- #

                @_setVitals
                    streamKey:          @streamKey
                    framesPerSec:       @framesPerSec
                    emitDuration:       @emitDuration

    #----------

    status: ->
        source:     @TYPE?() ? @TYPE
        connected:  @connected
        url:        "N/A"
        streamKey:  @streamKey
        uuid:       @uuid
        last_ts:    @last_ts

    #----------

    disconnect: ->
        if !@_disconnected
            @_disconnected = true
            @d.run =>
                @o_stream.removeListener "data", @oDataFunc
                @o_stream.removeListener "data", @oFirstDataFunc if @oFirstDataFunc
                @ffmpeg.kill()
                @_pingData?.kill()
                @connected = false

            @emit "disconnect"

            @removeAllListeners()
