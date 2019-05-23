_           = require 'underscore'
Concentrate = require "concentrate"
Dissolve    = require "dissolve"
nconf       = require "nconf"

Rewinder        = require "./rewind/rewinder"
HLSSegmenter    = require "./rewind/hls_segmenter"

MemoryStore     = require "./rewind/memory_store"

# RewindBuffer supports play from an arbitrary position in the last X hours
# of our stream.

# Buffer is an array of objects. Each object should have:
# * ts:         Timestamp for when chunk was emitted from master stream
# * data:       Chunk of audio data (in either MP3 or AAC)
# * meta:       Metadata that should be running as of this chunk
# * duration:   Duration of the audio chunk

# When the buffer is dumped, it will be in the form of a loop of binary
# packets.  Each will contain:
# * uint8: metadata length
# * Buffer: metadata, stringified into JSON and stuck in a buffer (obj is ts,
#   duration and meta)
# * uint16: data length
# * Buffer: data chunk

module.exports = class RewindBuffer extends require("events").EventEmitter
    constructor: (rewind_opts={}) ->
        @_rsecs         = rewind_opts.seconds || 0
        @_rburstsecs    = rewind_opts.burst || 0
        @_rsecsPerChunk = Infinity
        @_rmax          = null
        @_rburst        = null
        @_rkey          = rewind_opts.key

        @_risLoading    = false

        # This could already be set if we've subclassed RewindBuffer, so
        # only set it if it doesn't exist
        @log            = rewind_opts.log if rewind_opts.log && !@log

        # each listener should be an object that defines obj._offset and
        # obj.writeFrame. We implement RewindBuffer.Listener, but other
        # classes can work with those pieces
        @_rlisteners = []

        # -- instantiate our memory buffer -- #

        @_rbuffer = rewind_opts.buffer_store || new MemoryStore
        @_rbuffer.on "shift",    (b) => @emit "rshift", b
        @_rbuffer.on "push",     (b) => @emit "rpush", b
        @_rbuffer.on "unshift",  (b) => @emit "runshift", b

        # -- set up Live Streaming segments -- #

        if rewind_opts.hls
            @log.debug "Setting up HLS Segmenter.", segment_duration:rewind_opts.hls
            @hls_segmenter = new HLSSegmenter @, rewind_opts.hls, @log

        # -- set up header and frame functions -- #

        @_rdataFunc = (chunk) =>
            # push the chunk on the buffer
            @_rbuffer.insert chunk

            # loop through all connected listeners and pass the frame buffer at
            # their offset.
            for l in @_rlisteners
                # we'll give them whatever is at length - offset
                # FIXME: This lookup strategy is horribly inefficient
                @_rbuffer.at l._offset, (err,b) =>
                    l._insert b

        # -- look for stream connections -- #

        @on "source", (newsource) =>
            @_rConnectSource newsource

    #----------

    disconnect: ->
        @_rdataFunc = ->
        @_rbuffer.removeAllListeners()

        true

    #----------

    isLoading: ->
        @_risLoading

    #----------

    resetRewind: (cb) ->
        @_rbuffer.reset cb
        @emit "reset"

    #----------

    setRewind: (secs,burst) ->
        @_rsecs = secs
        @_rburstsecs = burst
        @_rUpdateMax()

    #----------

    _rConnectSource: (newsource,cb) ->
        @log.debug "RewindBuffer got source event"
        # -- disconnect from old source -- #

        if @_rsource
            @_rsource.removeListener "data", @_rdataFunc
            @log.debug "removed old rewind data listener"

        # -- compute initial stats -- #

        newsource.vitals (err,vitals) =>
            if @_rstreamKey && @_rstreamKey == vitals.streamKey
                # reconnecting, but rate matches so we can keep using
                # our existing buffer.
                @log.debug "Rewind buffer validated new source.  Reusing buffer."

            else
                @_rChunkLength vitals

            # connect our data listener
            newsource.on "data", @_rdataFunc

            # keep track of our source
            @_rsource = newsource

            cb? null

    #----------

    # Return rewind buffer status, including HTTP Live Streaming if enabled
    _rStatus: ->
        status =
            buffer_length:      @_rbuffer.length()
            first_buffer_ts:    @_rbuffer.first()?.ts
            last_buffer_ts:     @_rbuffer.last()?.ts

        if @hls_segmenter
            _.extend status, @hls_segmenter.status()

        status

    #----------

    _rChunkLength: (vitals) ->
        if @_rstreamKey != vitals.streamKey
            if @_rstreamKey
                # we're reconnecting, but didn't match rate...  we
                # should wipe out the old buffer
                @log.debug "Invalid existing rewind buffer. Reset."
                @_rbuffer.reset()

            # compute new frame numbers
            @_rsecsPerChunk = vitals.emitDuration
            @_rstreamKey    = vitals.streamKey

            @_rUpdateMax()

            @log.debug "Rewind's max buffer length is ", max:@_rmax, secsPerChunk:@_rsecsPerChunk, secs:vitals.emitDuration

    #----------

    _rUpdateMax: ->
        if @_rsecsPerChunk
            @_rmax          = Math.round @_rsecs / @_rsecsPerChunk
            @_rbuffer.setMax @_rmax
            @_rburst        = Math.round @_rburstsecs / @_rsecsPerChunk
        @log.debug "Rewind's max buffer length is ", max:@_rmax, seconds:@_rsecs

    #----------

    getRewinder: (id,opts,cb) ->
        # create a rewinder object
        rewind = new Rewinder @, id, opts, cb

        unless opts.pumpOnly
            # add it to our list of listeners
            @_raddListener rewind

    #----------

    recordListen: (opts) ->
        # stub function. must be defined for real in the implementing class

    #----------

    bufferedSecs: ->
        # convert buffer length to seconds
        Math.round @_rbuffer.length() * @_rsecsPerChunk

    #----------

    # Insert a chunk into the RewindBuffer. Inserts can only go backward, so
    # the timestamp must be less than @_rbuffer[0].ts for a valid chunk
    _insertBuffer: (chunk) ->
        @_rbuffer.insert chunk

    #----------

    # Load a RewindBuffer.  Buffer should arrive newest first, which means
    # that we can simply shift() it into place and don't have to lock out
    # any incoming data.

    loadBuffer: (stream,cb) ->
        @_risLoading = true
        @emit "rewind_loading"

        if !stream
            # Calling loadBuffer with no stream is really just for testing
            process.nextTick =>
                @emit "rewind_loaded"
                @_risLoading = false

            @hls_segmenter._loadMap null if @hls_segmenter

            return cb null, seconds:0, length:0

        parser = Dissolve()
            .uint32le("header_length")
            .tap ->
                @buffer("header",@vars.header_length)
                    .tap ->
                        @push JSON.parse(@vars.header)
                        @vars = {}

                        @loop (end) ->
                            @uint8("meta_length")
                                .tap ->
                                    @buffer("meta",@vars.meta_length)
                                        .uint16le("data_length")
                                        .tap ->
                                            @buffer("data",@vars.data_length)
                                                .tap ->
                                                    meta = JSON.parse @vars.meta.toString()
                                                    @push ts:new Date(meta.ts), meta:meta.meta, duration:meta.duration, data:@vars.data
                                                    @vars = {}

        stream.pipe(parser)

        headerRead = false

        parser.on "readable", =>
            while c = parser.read()
                if !headerRead
                    headerRead = true

                    @emit "header", c
                    @_rChunkLength emitDuration:c.secs_per_chunk, streamKey:c.stream_key

                    if c.hls && @hls_segmenter
                        @hls_segmenter._loadMap c.hls

                else
                    @_insertBuffer(c)
                    @emit "buffer", c

                true

        parser.on "end", =>
            obj = seconds:@bufferedSecs(), length:@_rbuffer.length()
            @log.info "RewindBuffer is now at ", obj
            @emit "rewind_loaded"
            @_risLoading = false
            cb? null, obj

    #----------

    # Dump the rewindbuffer. We want to dump the newest data first, so that
    # means running back from the end of the array to the front.

    dumpBuffer: (cb) ->
        # taking a copy of the array should effectively freeze us in place
        @_rbuffer.clone (err,rbuf_copy) =>
            if err
                cb err
                return false

            go = (hls) =>
                writer = new RewindBuffer.RewindWriter rbuf_copy, @_rsecsPerChunk, @_rstreamKey, hls
                cb null, writer

            if @hls_segmenter
                @hls_segmenter._dumpMap (err,info) =>
                    return cb err if err
                    go info

            else
                go()


    #----------

    checkOffsetSecs: (secs) ->
        @checkOffset @secsToOffset(secs)

    #----------

    checkOffset: (offset) ->
        bl = @_rbuffer.length()

        if offset < 0
            @log.silly "offset is invalid! 0 for live."
            return 0

        if bl >= offset
            @log.silly "Granted. current buffer length is ", length:bl
            return offset
        else
            @log.silly "Not available. Instead giving max buffer of ", length:bl - 1
            return bl - 1

    #----------

    secsToOffset: (secs) ->
        Math.round Number(secs) / @_rsecsPerChunk

    #----------

    offsetToSecs: (offset) ->
        Math.round Number(offset) * @_rsecsPerChunk

    #----------

    timestampToOffset: (time,cb) ->
        cb null, @_rbuffer._findTimestampOffset time

    #----------

    pumpSeconds: (rewinder,seconds,concat,cb) ->
        # pump the most recent X seconds
        frames = @checkOffsetSecs seconds
        @pumpFrom rewinder, frames, frames, concat, cb

    #----------

    pumpFrom: (rewinder,offset,length,concat,cb) ->
        # we want to send _length_ chunks, starting at _offset_

        if offset == 0 || length == 0
            cb? null, null
            return true

        @_rbuffer.range offset, length, (err,chunks) =>
            pumpLen     = 0
            duration    = 0
            meta        = null
            buffers     = []

            for b in chunks
                pumpLen     += b.data.length
                duration    += b.duration

                if concat
                  buffers.push b.data
                else
                  rewinder._insert b

                meta = b.meta if !meta

            if concat
                cbuf = Buffer.concat(buffers)
                rewinder._insert { data:cbuf, meta:meta, duration:duration }

            offsetSeconds = if (offset instanceof Date)
                # how many seconds are between this date and the end of the
                # buffer?
                ( Number(@_rbuffer.last().ts) - Number(offset) ) / 1000
            else
                @offsetToSecs(offset)

            @log?.silly "Converting offset to seconds: ", offset:offset, secs:offsetSeconds
            cb? null, meta:meta, duration:duration, length:pumpLen, offsetSeconds:offsetSeconds

    #----------

    burstFrom: (rewinder,offset,burstSecs,cb) ->
        # we want to send them @burst frames (if available), starting at offset.
        # return them the new offset position and the burst data

        # convert burstSecs to frames
        burst = @checkOffsetSecs burstSecs

        if offset > burst
            @pumpFrom rewinder, offset, burst, false, (err,info) =>
                cb? err, offset-burst
        else
            @pumpFrom rewinder, offset, offset, false, (err,info) =>
                cb? err, 0

    #----------

    _raddListener: (obj) ->
        if obj._offset? && obj._offset >= 0
            @_rlisteners.push obj
            return true
        else
            return false

    #----------

    _rremoveListener: (obj) ->
        @_rlisteners = _(@_rlisteners).without obj
        return true

    #----------

    class @RewindWriter extends require("stream").Readable
        constructor: (@buf,@secs,@streamKey,@hls) ->
            @c          = Concentrate()
            @slices     = 0
            @i          = @buf.length - 1
            @_ended     = false

            super highWaterMark:25*1024*1024

            # make sure there's something to send
            if @buf.length == 0
                @push null
                return false

            @_writeHeader()

        #----------

        _writeHeader: (cb) ->
            # -- Write header -- #

            header_buf = Buffer.from JSON.stringify
                start_ts:       @buf[0].ts
                end_ts:         @buf[ @buf.length - 1 ].ts
                secs_per_chunk: @secs
                stream_key:     @streamKey
                hls:            @hls

            # header buffer length
            @c.uint32le header_buf.length

            # header buffer json
            @c.buffer header_buf

            @push @c.result()
            @c.reset()

        #----------

        _read: (size) ->
            if @i < 0
                return false

            # -- Data Chunks -- #
            wlen = 0

            loop
                chunk = @buf[ @i ]

                meta_buf = Buffer.from JSON.stringify ts:chunk.ts, meta:chunk.meta, duration:chunk.duration

                # 1) metadata length
                @c.uint8 meta_buf.length

                # 2) metadata json
                @c.buffer meta_buf

                # 3) data chunk length
                @c.uint16le chunk.data.length

                # 4) data chunk
                @c.buffer chunk.data

                r = @c.result()
                @c.reset()
                result = @push r

                wlen += r.length

                @i -= 1

                if @i < 0
                    # finished
                    @push null
                    return true

                if !result || wlen > size
                    return false

                # otherwise loop again
