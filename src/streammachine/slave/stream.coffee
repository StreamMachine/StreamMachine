_u = require "underscore"

Preroller = require "./preroller"
Rewind = require "../rewind_buffer"

# Streams are the endpoints that listeners connect to. 

# On startup, a slave stream should connect to the master and start serving 
# live audio as quickly as possible. It should then try to load in any 
# Rewind buffer info available on the master. 

module.exports = class Stream extends require('../rewind_buffer')        
    constructor: (@core,@key,@log,@opts) ->        
        @STATUS = "Initializing"

        # initialize RewindBuffer
        super()
        
        @StreamTitle  = ""
        @StreamUrl    = ""
        
        # remove our max listener count
        @setMaxListeners 0
            
        @_id_increment = 1
        @_lmeta = {}
                
        @preroll = null
        @mlog_timer = null

        @metaFunc = (chunk) => 
            @StreamTitle    = chunk.StreamTitle if chunk.StreamTitle
            @StreamUrl      = chunk.StreamUrl if chunk.StreamUrl
            
            console.log "setting meta on slave stream", chunk, @StreamTitle, @StreamUrl
                
        @on "source", =>
            #@source.on "data", @dataFunc
            @source.on "meta", @metaFunc
            @source.on "buffer", (c) => @_insertBuffer(c)
            
            @source.once "disconnect", =>
                # try creating a new one
                @source = null
                @_buildSocketSource()
                    
        # now run configure...
        process.nextTick => @configure(opts)

        # -- configure a source -- #
        
        @_buildSocketSource()
            
    #----------
    
    info: ->
        key:            @key
        status:         @STATUS
        sources:        []
        listeners:      @listeners()
        options:        @opts
        bufferedSecs:   @bufferedSecs()
        
    #----------
    
    useSource: (source) ->
        @log.debug "Slave stream got source connection"
        @source = source
        @emit "source", @source
    
    #----------
    
    _buildSocketSource: ->
        if !@source && @core.master
            source = @core.socketSource @
            @useSource source
            
            # -- fetch rewind? -- #
            
            if @_rbuffer.length == 0
                source.getRewind (err,stream) =>
                    @loadBuffer stream if !err
            
    #----------
    
    configure: (opts) ->
                
        # -- Preroll -- #
        
        @log.debug "Preroll settings are ", preroll:opts.preroll
        
        @preroll.disconnect() if @preroll
        
        if opts.preroll?
            # create a Preroller connection
            @preroll = new Preroller @, @key, opts.preroll
        
        # -- Should we be logging minutes? -- #
        
        if opts.log_minutes && !@mlog_timer
            # set up a timer to log minutes listened
            @mlog_timer = setInterval => 
                # run through each listener and log minute or time listened
                now = new Date
                for id,l of @_lmeta
                    # we only log requests that have lasted more than one minute. 
                    # we use startTime for the length the session has been going, 
                    # but use minuteTime for accumulating unlogged time 
                    if ( now.getTime() / 1000 - l.startTime.getTime() / 1000 ) > 60
                        dur = ( now.getTime() / 1000 - l.minuteTime.getTime() / 1000 )
                        @log.minute "", path:l.obj.reqPath, time:now, ua:l.obj.reqUA, duration:dur
                        l.minuteTime = now
                                        
            , 60*1000
            
        else if @mlog_timer && !opts.log_minutes
            clearInterval @mlog_timer
            @mlog_timer = null
            
        # -- Set up bufferSize poller -- #
        
        # We disconnect clients that have fallen too far behind on their 
        # buffers. Buffer size can be configured via the "max_buffer" setting, 
        # which takes bits
        console.log "max buffer size is ", @opts.max_buffer
        
        if @buf_timer
            clearInterval @buf_timer
            @buf_timer = null
        
        @buf_timer = setInterval =>
            all_buf = 0
            for id,l of @_lmeta
                conn = l.obj.req?.socket
                
                all_buf += conn?.bufferSize||0
                
                if (conn?.bufferSize||0) > @opts.max_buffer
                    @log.debug "Connection exceeded max buffer size.", req:l.obj.req, bufferSize:conn.bufferSize
                    l.obj.disconnect(true)

            @log.debug "All buffers: #{all_buf}"
        , 60*1000
                                
    #----------
        
    disconnect: ->
        # handle clearing out lmeta
        l.obj.disconnect(true) for k,l of @_lmeta
        
        # if we have a source, disconnect it
        if @source
            @source.disconnect()
        
    #----------
    
    listeners: ->
        _u(@_lmeta).keys().length
        
    #----------
    
    listen: (obj,opts) ->
        # generate a metadata hash
        lmeta = 
            id:         @_id_increment++
            obj:        obj
            startTime:  (new Date) 
            minuteTime: (new Date)
        
        # get a rewinder (handles the actual broadcast)
        lmeta.rewind = @getRewinder lmeta.id, opts
        
        # stash the object
        @_lmeta[ lmeta.id ] = lmeta
        
        # return the rewinder (so that they can change offsets, etc)
        lmeta.rewind
    
    #----------
            
    disconnectListener: (id) ->
        console.log "in closeListener for ", id
        
        lmeta = @_lmeta[id]
        
        if lmeta
            # -- remove from listeners -- #
            delete @_lmeta[id]
            
            # -- log the request's end -- #
            
            # compute listening duration
            seconds = null
            endTime = (new Date)
            seconds = (endTime.getTime() - lmeta.startTime.getTime()) / 1000
                    
            # log the connection end
            @log.debug "Connection end", id:id, listeners:_u(@_lmeta).keys().length, bytes:lmeta.obj.socket?.bytesWritten, seconds:seconds
        
            @log.request "", 
                path:       lmeta.obj.client.path
                ip:         lmeta.obj.client.ip
                ua:         lmeta.obj.client.ua
                bytes:      lmeta.obj.socket?.bytesWritten
                seconds:    seconds
                time:       endTime
        
            true
