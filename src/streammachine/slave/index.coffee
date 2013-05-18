_u = require "underscore"

Stream = require "./stream"
Server = require "./server"

Socket = require "socket.io-client"

URL = require "url"
HTTP = require "http"

module.exports = class Slave extends require("events").EventEmitter
    DefaultOptions:
        max_zombie_life:    1000 * 60 * 60
        
    Outputs:
        pumper:     require "../outputs/pumper"
        shoutcast:  require "../outputs/shoutcast"
        raw:        require "../outputs/raw_audio"
        sockets:    require "../outputs/sockets"
        
    constructor: (opts) ->
        @options = _u.defaults opts||{}, @DefaultOptions
        
        @streams = {}
        @root_route = null
        
        @connected = false
        
        @_retrying = null
        @_retryConnection = =>
            @log.debug "Failed to connect to master. Trying again in 5 seconds."
            @_retrying = setTimeout =>
                @log.debug "Retrying connection to master."
                @_connectMaster()
            , 5000
            
        # -- Set up logging -- #
        
        @log = @options.logger
            
        # -- Make sure we have the proper slave config options -- #
            
        if @options.slave?.master 
            # -- connect to the master server -- #
            
            @log.debug "Connecting to master at ", master:@options.slave.master
            
            @_connectMaster()
                                                        
        # -- set up our stream server -- #
            
        # init our server
        @server = new Server core:@
            
        @log.debug "Slave is listening on port #{@options.listen}"
        
        # start up the socket manager on the listener
        #@sockets = new @Outputs.sockets server:@server.server, core:@
        
        # -- Listener Counts -- #
        
        # once every 30 seconds, count all listeners and send them on to the master
        
        @_listeners_interval = setInterval =>
            return if !@connected?
            
            counts = {}
            total = 0
            
            for k,s of @streams
                l = s.listeners()
                counts[k] = l
                total += l

            @log.debug "sending listeners: #{total}", counts
            
            @emit "listeners", counts:counts, total:total
            @master?.emit "listeners", counts:counts, total:total

        , 30 * 1000
        
        # -- Buffer Stats -- #
        
        @_buffer_interval = setInterval =>
            return if !@connected?
            
            counts = []
            for k,s of @streams
                counts.push [s.key,s._rbuffer?.length].join(":")
                
            @log.debug "Rewind buffers: " + counts.join(" -- ")
            
        , 5 * 1000
                            
        # -- Graceful Shutdown -- #
        
        # attach a USR2 handler that causes us to stop listening. this is 
        # used to allow a new server to start up

        process.on "SIGTERM", =>
            @log.debug "Got SIGTERM in core...  Starting shutdown"
            
            # stop accepting new connections
            @server?.stopListening()
            
            # when should we get pushy?
            @_shutdownMaxTime = (new Date).getTime() + @options.max_zombie_life
            
            # need to start a process to quit when existing connections disconnect
            @_shutdownTimeout = setInterval =>
               # have we used up the grace period yet?
               force_shut = if (new Date).getTime() > @_shutdownMaxTime then true else false
                
               # build a listener count for all streams
               listeners = 0
               for k,stream of @streams
                   slisteners = stream.countListeners()
                    
                   if slisteners == 0 || force_shut
                       # if everyone's done (or we're feeling pushy), disconnect
                       stream.disconnect()
                   else
                       listeners += slisteners
                    
               if listeners == 0
                   # everyone's out...  go ahead and shut down
                   @log.debug "Shutdown complete", => process.exit()
               else
                   @log.debug "Still awaiting shutdown; #{listeners} listeners"
                
            , 60 * 1000
    
    #----------
    
    _connectMaster: ->
        @log.debug "Trying connection to master."
        @master = Socket.connect @options.slave.master, "connect timeout":5000
            
        @master.on "connect", => @_onConnect()
        @master.on "reconnect", => @_onConnect()
            
        @master.on "connect_failed", @_retryConnection
        @master.on "error", (err) =>
            if err.code =~ /ECONNREFUSED/
                @_retryConnection()
            else
                console.log "got connection error of ", err
            
        @master.on "config", (config) =>
            console.log "got config of ", config
            @configureStreams config.streams
                
        @master.on "disconnect", =>
            @_onDisconnect()
    
    #----------
    
    _onConnect: ->
        return false if @connected
        
        if @_retrying
            clearTimeout @_retrying
            @_retrying = null
        
        @connected = true
        
        if @master
            # connect up our logging proxy
            @log.debug "Connected to master."
            @log.proxyToMaster @master
        
        true
        
    _onDisconnect: ->
        @connected = false
        @log.debug "Disconnected from master."
        @server?.stopListening()
        
        @log.proxyToMaster()
                
        true
    
    #----------
           
    configureStreams: (options) ->
        @log.debug "In slave configureStreams with ", options:options

        # are any of our current streams missing from the new options? if so, 
        # disconnect them
        for k,obj in @streams
            console.log "calling disconnect on ", k
            obj.disconnect() unless options?[k]
            @streams.delete k
        
        # run through the streams we've been passed, initializing sources and 
        # creating rewind buffers
        for key,opts of options
            console.log "Slave stream for #{key}"
            if @streams[key]
                # existing stream...  pass it updated configuration
                @log.debug "Passing updated config to source: #{key}", opts:opts
                @streams[key].configure opts
            else
                @log.debug "Starting up source: #{key}", opts:opts
                
                slog = @log.child stream:key
                @streams[key] = new Stream @, key, slog, opts
                                
            # should this stream accept requests to /?
            if opts.root_route
                @root_route = key
    
    #----------
    
    socketSource: (stream) ->
        new Slave.SocketSource @, stream
    
    #----------
    
    sendHandoffData: (translator,cb) ->
        # need to transfer listeners and their offsets to the new process
        
        @log.info "Sending slave handoff data."
        
        fFunc = _u.after Object.keys(@streams).length, =>
            @log.info "Listeners sent."
            cb? null
        
        sFunc = (stream) =>
            @log.info "Sending #{ Object.keys(stream._lmeta).length } listeners for #{ stream.key }."
            
            sfFunc = _u.after Object.keys(stream._lmeta).length, =>
                fFunc()
                
            for id,l of stream._lmeta
                l.obj.prepForHandoff =>
                    translator.send "stream_listener",
                        stream:     stream.key
                        id:         id
                        startTime:  l.startTime
                        minuteTime: l.minuteTime
                        client:     l.obj.client
                    , l.obj.socket
                    
                    sfFunc()
        
        sFunc(s) for k,s of @streams
    
    loadHandoffData: (translator,cb) ->
        
        # -- look for transferred listeners -- #
        
        translator.on "stream_listener", (obj,socket) =>
            # create an output and attach it to the proper stream
            output = new @Outputs[ obj.client.output ] @streams[ obj.stream ], socket:socket, client:obj.client
    
    #----------
    
    # emulate a source connection, receiving data via sockets from our master server
                
    class @SocketSource extends require("events").EventEmitter
        constructor: (@slave,@stream) ->
            @log = @stream.log.child subcomponent:"socket_source"

            @log.debug "created SocketSource for #{@stream.key}"
            
            @slave.master.on "streamdata:#{@stream.key}",    (chunk) => 
                # our data gets converted into an octet array to go over the 
                # socket. convert it back before insertion
                chunk.data = new Buffer(chunk.data)
                @emit "data", chunk
            
            @slave.master.emit "stream_stats", @stream.key, (err,obj) =>
                @emit "vitals", obj
                
            #@slave.master.on "disconnect", =>
            #    @emit "disconnect"

        #----------
        
        getRewind: (cb) ->
            # connect to the master's StreamTransport and ask for any rewind 
            # buffer that is available

            # connect to: @master.options.host:@master.options.port
            
            # GET request for rewind buffer
            @log.debug "Making Rewind Buffer request for #{@stream.key}", sock_id:@slave.master.socket.sessionid
            req = HTTP.request 
                hostname:   @slave.master.socket.options.host
                port:       @slave.master.socket.options.port
                path:       "/s/#{@stream.key}/rewind"
                headers:   
                    'stream-slave-id':    @slave.master.socket.sessionid
            , (res) =>
                @log.debug "Got Rewind response with status code of #{ res.statusCode }"
                if res.statusCode == 200
                    # emit a 'rewind' event with a callback to get the response 
                    cb? null, res

            req.on "error", (err) =>
                @log.debug "Rewind request got error: #{err}", error:err
                cb? err

            req.end()
            
        #----------
            
        disconnect: ->
            console.log "SocketSource disconnect for #{@stream.key} called"
        