_           = require "underscore"
temp        = require "temp"
net         = require "net"
fs          = require "fs"
express     = require "express"
Throttle    = require "throttle"

Redis       = require "../redis"
RedisConfig = require "../redis_config"
API         = require "./admin/api"
Stream      = require "./stream"
SourceIn    = require "./source_in"
Alerts      = require "../alerts"
Analytics   = require "./analytics"
Monitoring  = require "./monitoring"
SlaveIO     = require "./master_io"
Prometheus  = require "./prometheus"

RewindDumpRestore   = require "../rewind/dump_restore"

# A Master handles configuration, slaves, incoming sources, logging and the admin interface

module.exports = class Master extends require("events").EventEmitter
    constructor: (@options) ->
        @_configured = false

        @streams        = {}
        @stream_groups  = {}
        @proxies        = {}

        # -- set up logging -- #

        @log = @options.logger


        if @options.redis?
            # -- load our streams configuration from redis -- #

            @log.debug "Initializing Redis connection"
            @redis = new Redis @options.redis
            @redis_config = new RedisConfig @redis
            @redis_config.on "config", (config) =>
                # stash the configuration
                @options = _.defaults config||{}, @options

                # (re-)configure our master stream objects
                @configureStreams @options.streams

            # Persist changed configuration to Redis
            @log.debug "Registering config_update listener"
            @on "config_update", =>
                @redis_config._update @config()

        else if @options.streams
            # -- look for hard-coded configuration -- #

            process.nextTick =>
                @configureStreams @options.streams
        else
            # nothing there...
            process.nextTick =>
                @configureStreams {}

        @once "streams", =>
            @_configured = true

        # -- create a server to provide the API -- #

        @api = new API @, @options.admin?.require_auth

        # -- create a backend server for stream requests -- #

        @transport = new Master.StreamTransport @

        # -- start the source listener -- #

        @sourcein = new SourceIn core:@, port:@options.source_port, behind_proxy:@options.behind_proxy

        # -- create an alerts object -- #

        @alerts = new Alerts logger:@log.child(module:"alerts")

        # -- create a listener for slaves -- #

        if @options.master
            @slaves = new SlaveIO @, @log.child(module:"master_io"), @options.master
            @on "streams", =>
                @slaves.updateConfig @config()

        # -- Analytics -- #

        if @options.analytics
            @analytics = new Analytics
                config: @options.analytics
                log:    @log.child(module:"analytics")
                redis:  @redis

            # add a log transport
            @log.logger.add new Analytics.LogTransport(@analytics), {}, true

        # -- Rewind Dump and Restore -- #

        @rewind_dr = new RewindDumpRestore @, @options.rewind_dump if @options.rewind_dump

        # -- Set up our monitoring module -- #

        @monitoring = new Monitoring @, @log.child(module:"monitoring")

        # -- Prometheus metrics -- #

        if @options.prometheus
            @prometheus = new Prometheus @

    #----------

    once_configured: (cb) ->
        if @_configured
            cb()
        else
            @once "streams", => cb()

    #----------

    loadRewinds: (cb) ->
        @once "streams", =>
            @rewind_dr?.load cb

    #----------

    config: ->
        config = streams:{}

        config.streams[k] = s.config() for k,s of @streams

        return config

    #----------

    # configureStreams can be called on a new core, or it can be called to
    # reconfigure an existing core.  we need to support either one.
    configureStreams: (options,cb) ->
        @log.debug "In configure with ", options

        # -- Sources -- #

        # are any of our current streams missing from the new options? if so,
        # disconnect them
        for k,obj of @streams
            @log.debug "calling destroy on ", k
            if !options?[k]
                obj.destroy()
                delete @streams[ k ]

        # run through the streams we've been passed, initializing sources and
        # creating rewind buffers
        for key,opts of options
            @log.debug "Parsing stream for #{key}"
            if @streams[key]
                # existing stream...  pass it updated configuration
                @log.debug "Passing updated config to master stream: #{key}", opts:opts
                @streams[key].configure opts
            else
                @log.debug "Starting up master stream: #{key}", opts:opts
                @_startStream key, opts

            # part of a stream group?
            if g = @streams[key].opts.group
                # do we have a matching group?
                sg = ( @stream_groups[ g ] ||= new Stream.StreamGroup g, @log.child stream_group:g )
                sg.addStream @streams[key]

        @emit "streams", @streams

        cb? null, @streams

    #----------

    _startStream: (key,opts) ->
        stream = new Stream @, key, @log.child(stream:key), _.extend opts,
            hls:        @options.hls

        if stream
            # attach a listener for configs
            stream.on "config", => @emit "config_update"; @emit "streams", @streams

            @streams[ key ] = stream
            @_attachIOProxy stream

            @emit "new_stream", stream
            return stream
        else
            return false

    #----------

    createStream: (opts,cb) ->
        @log.debug "createStream called with ", opts

        # -- make sure the stream key is present and unique -- #

        if !opts.key
            cb? "Cannot create stream without key."
            return false

        if @streams[ opts.key ]
            cb? "Stream key must be unique."
            return false

        # -- create the stream -- #

        if stream = @_startStream opts.key, opts
            @emit "config_update"
            @emit "streams"
            cb? null, stream.status()
        else
            cb? "Stream failed to start."

    #----------

    updateStream: (stream,opts,cb) ->
        @log.info "updateStream called for ", key:stream.key, opts:opts

        # -- if they want to rename, the key must be unique -- #

        if opts.key && stream.key != opts.key
            if @streams[ opts.key ]
                cb? "Stream key must be unique."
                return false

            @streams[ opts.key ] = stream
            delete @streams[ stream.key ]

        # -- if we're good, ask the stream to configure -- #

        stream.configure opts, (err,config) =>
            if err
                cb? err
                return false


            cb? null, config

    #----------

    removeStream: (stream,cb) ->
        @log.info "removeStream called for ", key:stream.key

        delete @streams[ stream.key ]
        stream.destroy()

        @emit "config_update"

        cb? null, "OK"

    #----------

    streamsInfo: ->
        obj.status() for k,obj of @streams

    groupsInfo: ->
        obj.status() for k,obj of @stream_groups

    #----------

    vitals: (stream,cb) ->
        if s = @streams[ stream ]
            s.vitals cb
        else
            cb "Invalid Stream"

    #----------

    getHLSSnapshot: (stream,cb) ->
        if s = @streams[ stream ]
            s.getHLSSnapshot cb
        else
            cb "Invalid Stream"

    #----------

    # Get a status snapshot by looping through each stream to get buffer stats
    _rewindStatus: ->
        status = {}
        status[ key ] = s.rewind._rStatus() for key,s of @streams
        status

    #----------

    slavesInfo: ->
        if @slaves
            slaveCount: Object.keys(@slaves.slaves).length
            slaves:     ( { id:k, status:s.last_status||"WARMING UP" } for k,s of @slaves.slaves )
            master:     @_rewindStatus()
        else
            slaveCount: 0
            slaves:     []
            master:     @_rewindStatus()

    #----------

    sendHandoffData: (rpc,cb) ->
        streams_sent = {}

        fFunc = _.after (Object.keys(@streams).length+Object.keys(@stream_groups).length), =>
            @log.info "Rewind buffers and sources sent."
            cb null

        # -- Stream Group Sources -- #

        # no rewind buffers, only sources

        rpc.on "group_sources", (msg,handle,cb) =>
            @log.info "StreamGroup sources requested for #{ msg.key }"

            sg = @stream_groups[ msg.key ]

            if sg._stream.sources.length == 0
                # no sources to send... return right away
                fFunc()
                return cb null

            # if we have sources, count up to make sure we return them all
            af = _.after sg._stream.sources.length, =>
                fFunc()
                cb null

            for source in sg._stream.sources
                if source._shouldHandoff
                    do (source) =>
                        @log.info "Sending StreamGroup source #{msg.key}/#{source.uuid}"
                        rpc.request "group_source",
                            group:      sg.key
                            type:       source.HANDOFF_TYPE
                            opts:       format:source.opts.format, uuid:source.uuid, source_ip:source.opts.source_ip, connectedAt:source.connectedAt
                        , source.opts.sock
                        , (err,reply) =>
                            @log.error "Error sending group source #{msg.key}/#{source.uuid}: #{err}" if err
                            af()
                else
                    af()


        # -- Stream Rewind Buffers and Sources -- #

        rpc.on "stream_rewind", (msg,handle,cb) =>
            @log.info "Rewind buffer requested for #{ msg.key }"
            stream = @streams[msg.key]

            # go ahead and send over any sources...
            for source in stream.sources
                if source._shouldHandoff
                    do (source) =>
                        rpc.request "stream_source",
                            stream:     stream.key
                            type:       source.HANDOFF_TYPE
                            opts:       format:source.opts.format, uuid:source.uuid, source_ip:source.opts.source_ip, connectedAt:source.connectedAt
                        , source.opts.sock
                        , (err,reply) =>
                            @log.error "Error sending stream source #{msg.key}/#{source.uuid}: #{err}" if err

            if stream.rewind.bufferedSecs() > 0
                @log.info "RewindBuffer write for #{ msg.key } to #{ msg.path }"
                sock = net.connect msg.path, (err) =>
                    @log.info "Writer socket connected for rewind buffer #{msg.key}", error:err
                    return cb err if err

                    stream.getRewind (err,writer) =>
                        return cb err if err

                        writer.pipe(sock)
                        writer.on "end", =>
                            @log.info "RewindBuffer for #{ msg.key } written to socket."

                        @log.info "Waiting for sock close for #{ msg.key }..."
                        sock.on "close", (err) =>
                            @log.info "Dumped buffer for #{msg.key}", bytesWritten:sock.bytesWritten, error:err
                            fFunc()
                            cb null

            else
                @log.info "No rewind buffer to send for #{msg.key}."
                fFunc()
                cb null

    #----------

    loadHandoffData: (rpc,cb) ->
        # -- set up a listener for sources -- #

        rpc.on "stream_source", (msg,handle,cb) =>
            stream = @streams[ msg.stream ]
            source = new (require "../sources/#{msg.type}") _.extend {}, msg.opts, sock:handle, logger:stream.log
            stream.addSource source
            @log.info "Added stream source: #{stream.key}/#{source.uuid}"
            cb null

        rpc.on "group_source", (msg,handle,cb) =>
            sg = @stream_groups[ msg.group ]
            source = new (require "../sources/#{msg.type}") _.extend {}, msg.opts, sock:handle, logger:stream.log
            sg._stream.addSource source
            @log.info "Added group source: #{stream.key}/#{source.uuid}"
            cb null

        af = _.after (Object.keys(@streams).length+Object.keys(@stream_groups).length), =>
            cb null

        for key,group of @stream_groups
            do (key,group) =>
                # we don't need rewind buffers for stream groups, but we do
                # need sources.
                rpc.request "group_sources", key:key, null, timeout:10000, (err) =>
                    @log.error "Error getting StreamGroup sources: #{err}" if err
                    @log.info "Sources received for StreamGroup #{ key }."
                    af()

        for key,stream of @streams
            do (key,stream) =>
                # set up a socket to accept the buffer on
                # create a socket
                spath = temp.path suffix:".sock"

                @log.info "Asking to get rewind buffer for #{key} over #{spath}."

                sock = net.createServer()

                sock.listen spath, =>
                    sock.once "connection", (c) =>
                        stream.rewind.loadBuffer c, (err) =>
                            @log.error "Error loading rewind buffer: #{err}" if err
                            c.end()

                    rpc.request "stream_rewind", key:key,path:spath, null, timeout:10000, (err) =>
                        return @log.error "Error loading rewind buffer for #{key}: #{err}" if err
                        @log.info "Rewind buffer loaded for #{key}"

                        # cleanup...
                        sock.close => fs.unlink spath, (err) =>
                            @log.info "RewindBuffer socket unlinked.", error:err
                            af()


    #----------

    _attachIOProxy: (stream) ->
        @log.debug "attachIOProxy call for #{stream.key}.", slaves:@slaves?, proxy:@proxies[stream.key]?
        return false if !@slaves

        if @proxies[ stream.key ]
            return false

        # create a new proxy
        @log.debug "Creating StreamProxy for #{stream.key}"
        @proxies[ stream.key ] = new Master.StreamProxy key:stream.key, stream:stream, master:@

        # and attach a listener to destroy it if the stream is removed
        stream.once "destroy", =>
            @proxies[ stream.key ]?.destroy()

    #----------

    class @StreamTransport
        constructor: (@master) ->
            @app = express()

            # -- Param Handlers -- #

            @app.param "stream", (req,res,next,key) =>
                # make sure it's a valid stream key
                if key? && s = @master.streams[ key ]
                    req.stream = s
                    next()
                else
                    res.status(404).end "Invalid stream.\n"

            # -- Validate slave id -- #

            @app.use (req,res,next) =>
                sock_id = req.get 'stream-slave-id'
                if sock_id && @master.slaves.slaves[ sock_id ]
                    #req.slave_socket = @master.slaves[ sock_id ]
                    next()

                else
                    @master.log.debug "Rejecting StreamTransport request with missing or invalid socket ID.", sock_id:sock_id
                    res.status(401).end "Missing or invalid socket ID.\n"

            # -- Routes -- #

            @app.get "/:stream/rewind", (req,res) =>
                @master.log.debug "Rewind Buffer request from slave on #{req.stream.key}."
                res.status(200).write ''
                req.stream.getRewind (err,writer) =>
                    writer.pipe( new Throttle 100*1024*1024 ).pipe(res)
                    res.on "end", =>
                        @master.log.debug "Rewind dumpBuffer finished."

    #----------

    class @StreamProxy extends require("events").EventEmitter
        constructor: (opts) ->
            @key = opts.key
            @stream = opts.stream
            @master = opts.master

            @dataFunc = (chunk) =>
                @master.slaves.broadcastAudio @key, chunk

            @hlsSnapFunc = (snapshot) =>
                @master.slaves.broadcastHLSSnapshot @key, snapshot

            @stream.on "data", @dataFunc
            @stream.on "hls_snapshot", @hlsSnapFunc

        destroy: ->
            @stream.removeListener "data", @dataFunc
            @stream.removeListener "hls_snapshot", @hlsSnapFunc

    #----------
