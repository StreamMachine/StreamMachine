_       = require "underscore"
uuid    = require "node-uuid"
URL     = require "url"

Rewind              = require '../rewind_buffer'
FileSource          = require "../sources/file"
ProxySource         = require '../sources/proxy'
TranscodingSource   = require "../sources/transcoding"
HLSSegmenter        = require "../rewind/hls_segmenter"
SourceMount         = require "./source_mount"

module.exports = class Stream extends require('events').EventEmitter
    DefaultOptions:
        meta_interval:      32768
        max_buffer:         4194304 # 4 megabits (64 seconds of 64k audio)
        key:                null
        seconds:            (60*60*4) # 4 hours
        burst:              30
        source_password:    null
        host:               null
        fallback:           null
        acceptSourceMeta:   false
        log_minutes:        true
        monitored:          false
        metaTitle:          ""
        metaUrl:            ""
        format:             "mp3"
        preroll:            ""
        preroll_key:        ""
        transcoder:         ""
        root_route:         false
        group:              null
        bandwidth:          0
        codec:              null
        ffmpeg_args:        null
        stream_key:         null
        impression_delay:   5000
        log_interval:       30000
        geolock:            null

    constructor: (@key,@log,@mount,opts)->
        @opts = _.defaults opts||{}, @DefaultOptions

        # We have three options for what source we're going to use:
        # a) Internal: Create our own source mount and manage our own sources.
        #    Basically the original stream behavior.
        # b) Source Mount: Connect to a source mount and use its source
        #    directly. You'll get whatever incoming format the source gets.
        # c) Source Mount w/ Transcoding: Connect to a source mount, but run a
        #    transcoding source between it and us, so that we always get a
        #    certain format as our input.

        @destroying = false
        @source = null

        if opts.ffmpeg_args
            # Source Mount w/ transcoding
            @_initTranscodingSource()

        else
            # Source Mount directly
            @source = @mount

        # Cache the last stream vitals we've seen
        @_vitals = null

        @emitDuration = 0

        @STATUS = "Initializing"

        @log.event "Stream is initializing."

        # -- Initialize Master Rewinder -- #

        # set up a rewind buffer, for use in bringing new slaves up to speed
        # or to transfer to a new master when restarting
        @log.info "Initializing RewindBuffer for master stream."
        @rewind = new Rewind
            seconds:    @opts.seconds
            burst:      @opts.burst
            key:        "master__#{@key}"
            log:        @log.child(module:"rewind")
            hls:        @opts.hls?.segment_duration

        # Rewind listens to us, not to our source
        @rewind.emit "source", @

        # Pass along buffer loads
        @rewind.on "buffer", (c) => @emit "buffer", c

        # if we're doing HLS, pass along new segments
        if @opts.hls?
            @rewind.hls_segmenter.on "snapshot", (snap) =>
                @emit "hls_snapshot", snap

        # -- Set up data functions -- #

        @_meta =
            StreamTitle:    @opts.metaTitle
            StreamUrl:      ""

        @sourceMetaFunc = (meta) =>
            if @opts.acceptSourceMeta
                @setMetadata meta

        @dataFunc = (data) =>
            # inject our metadata into the data object
            @emit "data", _.extend {}, data, meta:@_meta

        @vitalsFunc = (vitals) =>
            @_vitals = vitals
            @emit "vitals", vitals

        @source.on "data", @dataFunc
        @source.on "vitals", @vitalsFunc

        # -- Hardcoded Source -- #

        # This is an initial source like a proxy that should be connected from
        # our end, rather than waiting for an incoming connection

        if @opts.fallback?
            # what type of a fallback is this?
            uri = URL.parse @opts.fallback

            newsource = switch uri.protocol
                when "file:"
                    new FileSource
                        format:     @opts.format
                        filePath:   uri.path
                        logger:     @log

                when "http:"
                    new ProxySource
                        format:     @opts.format
                        url:        @opts.fallback
                        fallback:   true
                        logger:     @log

                else
                    null

            if newsource
                newsource.once "connect", =>
                    @addSource newsource, (err) =>
                        if err
                            @log.error "Connection to fallback source failed."
                        else
                            @log.event "Fallback source connected."

                newsource.on "error", (err) =>
                    @log.error "Fallback source error: #{err}", error:err

            else
                @log.error "Unable to determine fallback source type for #{@opts.fallback}"

    #----------

    _initTranscodingSource: ->
        @log.debug "Setting up transcoding source for #{ @key }"

        # -- create a transcoding source -- #

        tsource = new TranscodingSource
            stream:         @mount
            ffmpeg_args:    @opts.ffmpeg_args
            format:         @opts.format
            logger:         @log

        @source = tsource

        # if our transcoder goes down, restart it
        tsource.once "disconnect", =>
            @log.error "Transcoder disconnected for #{ @key }."
            process.nextTick (=> @_initTranscodingSource()) if !@destroying

    #----------

    addSource: (source,cb) ->
        @source.addSource source, cb

    #----------

    # Return our configuration

    config: ->
        @opts

    #----------

    vitals: (cb) ->
        _vFunc = (v) =>
            cb? null, v

        if @_vitals
            _vFunc @_vitals
        else
            @once "vitals", _vFunc

    #----------

    getHLSSnapshot: (cb) ->
        if @rewind.hls_segmenter
            @rewind.hls_segmenter.snapshot cb
        else
            cb "Stream does not support HLS"

    #----------

    getStreamKey: (cb) ->
        if @_vitals
            cb? @_vitals.streamKey
        else
            @once "vitals", => cb? @_vitals.streamKey

    #----------

    status: ->
        # id is DEPRECATED in favor of key
        key:        @key
        id:         @key
        vitals:     @_vitals
        source:     @source.status()
        rewind:     @rewind._rStatus()

    #----------

    setMetadata: (opts,cb) ->
        if opts.StreamTitle? || opts.title?
            @_meta.StreamTitle = opts.StreamTitle||opts.title

        if opts.StreamUrl? || opts.url?
            @_meta.StreamUrl = opts.StreamUrl||opts.url

        @emit "meta", @_meta

        cb? null, @_meta

    #----------

    configure: (new_opts,cb) ->
        # allow updates, but only to keys that are present in @DefaultOptions.
        for k,v of @DefaultOptions
            @opts[k] = new_opts[k] if new_opts[k]?

            # convert to a number if necessary
            @opts[k] = Number(@opts[k]) if _.isNumber(@DefaultOptions[k])

        if @key != @opts.key
            @key = @opts.key

        # did they update the metaTitle?
        if new_opts.metaTitle
            @setMetadata title:new_opts.metaTitle

        # Update our rewind settings
        @rewind.setRewind @opts.seconds, @opts.burst

        @emit "config"

        cb? null, @config()

    #----------

    getRewind: (cb) ->
        @rewind.dumpBuffer (err,writer) =>
            cb? null, writer

    #----------

    destroy: ->
        # shut down our sources and go away
        @destroying = true

        @source.disconnect() if @source instanceof TranscodingSource
        @rewind.disconnect()

        @source.removeListener "data", @dataFunc
        @source.removeListener "vitals", @vitalsFunc

        @dataFunc = @vitalsFunc = @sourceMetaFunc = ->

        @emit "destroy"
        true

    #----------

    class @StreamGroup extends require("events").EventEmitter
        constructor: (@key,@log) ->
            @streams        = {}
            @transcoders    = {}
            @hls_min_id     = null

        #----------

        addStream: (stream) ->
            if !@streams[ stream.key ]
                @log.debug "SG #{@key}: Adding stream #{stream.key}"

                @streams[ stream.key ] = stream

                # listen in case it goes away
                delFunc = =>
                    @log.debug "SG #{@key}: Stream disconnected: #{ stream.key }"
                    delete @streams[ stream.key ]

                stream.on "disconnect", delFunc

                stream.on "config", =>
                    delFunc() if stream.opts.group != @key

                # if HLS is enabled, sync the stream to the rest of the group
                stream.rewind.hls_segmenter?.syncToGroup @

        #----------

        status: ->
            sstatus = {}
            sstatus[k] = s.status() for k,s of @streams

            id:         @key
            streams:    sstatus

        #----------

        hlsUpdateMinSegment: (id) ->
            if !@hls_min_id || id > @hls_min_id
                prev = @hls_min_id
                @hls_min_id = id
                @emit "hls_update_min_segment", id
                @log.debug "New HLS min segment id: #{id} (Previously: #{prev})"

        #----------
