# Rewinder is the general-purpose listener stream.
# Arguments:
# * offset: Number
#   - Where to position the playHead relative to now.  Should be a positive
#     number representing the number of seconds behind live
# * pump: Boolean||Number
#   - If true, burst 30 seconds or so of data as a buffer. If offset is 0,
#     that 30 seconds will effectively put the offset at 30. If offset is
#     greater than 0, burst will go forward from that point.
#   - If a number, specifies the number of seconds of data to pump
#     immediately.
# * pumpOnly: Boolean, default false
#   - Don't hook the Rewinder up to incoming data. Pump whatever data is
#     requested and then send EOF

module.exports = class Rewinder extends require("stream").Readable
    constructor: (@rewind,@conn_id,opts={},cb) ->
        super highWaterMark:256*1024

        @_pumpOnly = false

        @_offset = -1

        oFunc = (@_offset) =>
            @rewind.log.debug "Rewinder: creation with ", opts:opts, offset:@_offset

            @_queue = []
            @_queuedBytes = 0

            @_reading = false

            @pumpSecs = if opts.pump == true then @rewind.opts.burst else opts.pump

            # -- What are we sending? -- #

            if opts?.live_segment
                # we're sending a segment of HTTP Live Streaming data
                @_pumpOnly = true
                @rewind.hls_segmenter.pumpSegment opts.live_segment, (err,segment) =>
                    return cb err if err

                    @_insert segment

                    # return pump information
                    @rewind.log.debug "Pumping Live segment with ", duration:segment.duration, length:segment.data.length
                    cb null, @, duration:segment.duration, length:segment.data.length

            else if opts?.pumpOnly
                # we're just giving one pump of data, then EOF
                @_pumpOnly = true
                @rewind.pumpFrom @, @_offset, @rewind.secsToOffset(@pumpSecs), false, (err,info) =>
                    return cb err if err

                    # return pump information
                    cb null, @, info

            else if opts?.pump
                if @_offset == 0
                    # pump some data before we start regular listening
                    @rewind.log.silly "Rewinder: Pumping #{@rewind.opts.burst} seconds."
                    @rewind.pumpSeconds @, @pumpSecs, true

                    cb null, @
                else
                    # we're offset, so we'll pump from the offset point forward instead of
                    # back from live
                    @rewind.burstFrom @, @_offset, @pumpSecs, (err,new_offset) =>
                        return cb err if err

                        @_offset = new_offset

                        cb null, @

            # that's it... now RewindBuffer will call our @data directly
            #cb null, @


        if opts.timestamp
            @rewind.findTimestamp opts.timestamp, (err,offset) =>
                return cb err if err
                oFunc offset

        else
            offset =
                if opts.offsetSecs
                    @rewind.checkOffsetSecs opts.offsetSecs
                else if opts.offset
                    @rewind.checkOffset opts.offset
                else
                    0

            oFunc offset



    #----------

    onFirstMeta: (cb) ->
        if @_queue.length > 0
            cb? null, @_queue[0].meta
        else
            @once "readable", =>
                cb? null, @_queue[0].meta

    #----------

    # Implement the guts of the Readable stream. For a normal stream,
    # RewindBuffer will be calling _insert at regular ticks to put content
    # into our queue, and _read takes the task of buffering and sending
    # that out to the listener.

    _read: (size) =>
        # we only want one queue read going on at a time, so go ahead and
        # abort if we're already reading
        if @_reading
            return false

        # -- push anything queued up to size -- #

        # set a read lock
        @_reading = true

        sent = 0

        # Set up pushQueue as a function so that we can call it multiple
        # times until we get to the size requested (or the end of what we
        # have ready)

        _pushQueue = =>
            # -- Handle an empty queue -- #

            # In normal operation, you can think of the queue as infinite,
            # but not speedy.  If we've sent everything we have, we'll send
            # out an empty string to signal that more will be coming.  On
            # the other hand, in pump mode we need to send a null character
            # to signal that we've reached the end and nothing more will
            # follow.

            _handleEmpty = =>
                if @_pumpOnly
                    @rewind.log.debug "pumpOnly reached end of queue. Sending EOF"
                    @push null

                else
                    @push ''

                @_reading = false
                return false

            # See if the queue is empty to start with
            if @_queue.length == 0
                return _handleEmpty()

            # Grab a chunk off of the queued up buffer
            next_buf = @_queue.shift()

            @_queuedBytes -= next_buf.data.length

            # This shouldn't happen...
            if !next_buf
                @rewind.log.error "Shifted queue but got null", length:@_queue.length

            # Not all chunks will contain metadata, but go ahead and send
            # ours out if it does
            if next_buf.meta
                @emit "meta", next_buf.meta

            # Push the chunk of data onto our reader. The return from push
            # will tell us whether to keep pushing, or whether we need to
            # stop and wait for a drain event (basically wait for the
            # reader to catch up to us)

            if @push next_buf.data
                sent += next_buf.data.length

                if sent < size && @_queue.length > 0
                    _pushQueue()
                else
                    if @_queue.length == 0
                        _handleEmpty()

                    else
                        @push ''
                        @_reading = false

            else
                # give a signal that we're here for more when they're ready
                @_reading = false
                @emit "readable"

        _pushQueue()

    _insert: (b) =>
        @_queue.push b
        @_queuedBytes += b.data.length

        @emit "readable" if !@_reading

    #----------

    # Set a new offset (in seconds)
    setOffset: (offset) ->
        # -- make sure our offset is good -- #

        @_offset = @rewind.checkOffsetSecs offset

        # clear out the data we had buffered
        @_queue.slice(0)

        if @_offset == 0
            # pump some data before we start regular listening
            @rewind.log.silly "Rewinder: Pumping #{@rewind.opts.burst} seconds."
            @rewind.pumpSeconds @, @pumpSecs
        else
            # we're offset, so we'll pump from the offset point forward instead of
            # back from live
            [@_offset,data] = @rewind.burstFrom @_offset, @pumpSecs
            @_queue.push data

        @_offset

    #----------

    # Return the current offset in chunks
    offset: ->
        @_offset

    #----------

    # Return the current offset in seconds
    offsetSecs: ->
        @rewind.offsetToSecs @_offset

    #----------

    disconnect: ->
        @rewind._rremoveListener @

#----------