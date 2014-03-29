_u = require "underscore"
uuid = require "node-uuid"

Rewind = require('../rewind_buffer')
Proxy = require('../sources/proxy_room')

# Master streams are about source management. 

# Events:
# * source: emits when a source is promoted to active
# * add_source: emits when a source is added to the source list, but not made active
# * disconnect: emits when a source disconnects. `active` boolean indicates whether 
#   this was the live source. `count` integer indicates remaining sources

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
        monitored:          true
        metaTitle:          ""
        metaUrl:            ""
        format:             "mp3"
        preroll:            ""
        preroll_key:        ""
        root_route:         false
    
    constructor: (@core,@key,@log,opts)->
        @opts = _u.defaults opts||{}, @DefaultOptions
                
        @sources = []
        @source = null
        
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
        @rewind.opts = @opts
        @rewind.log = @log.child module:"rewind"
        
        # Rewind listens to us, not to our source
        @rewind.emit "source", @
        
        # Pass along buffer loads
        @rewind.on "buffer", (c) => @emit "buffer", c
        
        # -- Set up data functions -- #
        
        @_meta = 
            StreamTitle:    @opts.metaTitle
            StreamUrl:      ""
        
        @sourceMetaFunc = (meta) =>
            if @opts.acceptSourceMeta
                @setMetadata meta
        
        @dataFunc = (data) => 
            # inject our metadata into the data object
            @emit "data", _u.extend {}, data, meta:@_meta
            
        @vitalsFunc = (vitals) =>
            @_vitals = vitals
            @emit "vitals", vitals
                
        # -- Hardcoded Source -- #
        
        # This is an initial source like a proxy that should be connected from 
        # our end, rather than waiting for an incoming connection
        
        if @opts.fallback?
            console.log "Connecting initial source"
            newsource = new Proxy @, @opts.fallback, true

            newsource.on "connect", =>
                @addSource newsource, (result) =>
                    if result
                        @log.event "Fallback source connected."
                    else
                        @log.error "Connection to fallback source failed."
                        
            newsource.on "error", (err) =>
                @log.error "ProxyRoom error: #{err}", error:err
                    
        # -- Listener Tracking -- #
        
        # We track listener counts from each slave. They get reported by 
        # the slave to the master, which then calls recordSlaveListeners 
        # to record them here.
        
        # We need to also get rid of old counts from a slave that goes 
        # offline, though, so we attach an interval function to remove 
        # numbers that haven't been updated in the last two minutes.
        
        @_listeners = {}
        
        setInterval =>
            now = Number(new Date)
            for s,c of @_listeners
                delete @_listeners[s] if now - (120 * 1000) > c.last_at||0
        , 60 * 1000

    #----------
    
    # Return our configuration
    
    config: ->
        @opts
        
    #----------
        
    vitals: (cb) ->
        _vFunc = (v) =>
            console.log "Emit vital info", v
            cb? null, v
                        
        if @_vitals
            console.log "Sending vitals now."
            _vFunc @_vitals
        else
            console.log "Waiting for headers to send vitals"
            @once "vitals", _vFunc
    
    #----------
    
    getStreamKey: (cb) ->
        if @_vitals
            cb? @_vitals.streamKey
        else
            @once "vitals", => cb? @_vitals.streamKey
    
    #----------
    
    status: ->
        _u.defaults 
            id:         @key
            sources:    ( s.info() for s in @sources )
            listeners:  @listeners()
            rewind:     @rewind.bufferedSecs()
            vitals:     @_vitals
        , @opts 
    
    #----------
    
    setMetadata: (opts,cb) ->        
        if opts.StreamTitle? || opts.title?
            @_meta.StreamTitle = opts.StreamTitle||opts.title
            
        if opts.StreamUrl? || opts.url?
            @_meta.StreamUrl = opts.StreamUrl||opts.url
        
        @emit "meta", @_meta
        
        cb? null, @_meta
    
    #----------
    
    addSource: (source,cb) ->
        # add a disconnect monitor
        source.once "disconnect", =>
            # remove it from the list
            @sources = _u(@sources).without source
                        
            # was this our current source?
            if @source == source
                # yes...  need to promote the next one (if there is one)
                if @sources.length > 0
                    @useSource @sources[0]                    
                    @emit "disconnect", active:true, count:@sources.length, source:@source
                else
                    @log.alert "Source disconnected. No sources remaining."
                    @_disconnectSource @source
                    @source = null
                    @emit "disconnect", active:true, count:0, source:null
            else
                # no... just remove it from the list
                @log.event "Inactive source disconnected."
                @emit "disconnect", active:false, count:@sources.length, source:@source
        
        # check whether this source should be made active. It should be if 
        # the active source is defined as a fallback
        
        if !@sources[0] || @sources[0]?.isFallback
            # go to the front
            @log.event "Promoting new source to active.", source:(source.TYPE?() ? source.TYPE)
            @useSource source, cb
        else
            # add the source to the end of our list
            @log.event "Source connected.", source:(source.TYPE?() ? source.TYPE)
            @sources.push source
        
            # and emit our source event
            @emit "add_source", source
            
            cb?()
            
    #----------
    
    _disconnectSource: (s) ->
        s.removeListener "metadata",   @sourceMetaFunc
        s.removeListener "data",       @dataFunc
        s.removeListener "vitals",     @vitalsFunc

    #----------

    useSource: (newsource,cb=null) ->
        # stash our existing source if we have one
        old_source = @source || null

        # set a five second timeout for the switchover
        alarm = setTimeout =>
            @log.error "useSource failed to get switchover within five seconds.", 
                new_source: (newsource.TYPE?() ? newsource.TYPE)
                old_source: (old_source?.TYPE?() ? old_source?.TYPE)
                
            cb?(false)
        , 5000
        
        # Look for a header before switching
        newsource.vitals (vitals) =>
            # While we were waiting for vitals, another source may have been
            # made active. This might occur if two sources are connected
            # at the same time (or very quickly). This causes two sources to
            # be  "active" and you get a looping stream.
            # To prevent this, we'll make sure that the source wasn't changed
            # while we were waiting. Since @source is cached in old_source
            # above, we can use that to see if @source has been changed.
            if @source && @source != old_source
                @log.debug "Another source took over while waiting for vitals. New source won't be used.",
                    new_source: (newsource.TYPE?() ? newsource.TYPE),
                    active_source: (@source.TYPE?() ? @source.TYPE)

                @sources.push(newsource)

            else
                if old_source
                    # unhook from the old source's events
                    @_disconnectSource(old_source)
                        
                @source = newsource
                        
                # connect to the new source's events
                newsource.on "metadata",   @sourceMetaFunc
                newsource.on "data",       @dataFunc
                newsource.on "vitals",     @vitalsFunc
                
                # how often will we be emitting?
                @emitDuration = vitals.emitDuration
                    
                # note that we've got a new source
                process.nextTick =>
                    @log.event "New source is active.", 
                        new_source: (newsource.TYPE?() ? newsource.TYPE)
                        old_source: (old_source?.TYPE?() ? old_source?.TYPE)
                        
                    @emit "source", newsource
                    @vitalsFunc vitals

                # jump our new source to the front of the list (and remove it from
                # anywhere else in the list)
                @sources = _u.flatten [newsource,_u(@sources).without newsource]
            
            # cancel our timeout
            clearTimeout alarm
            
            # give the a-ok to the callback
            cb?(true)
            
    #----------
    
    promoteSource: (uuid,cb) ->
        # do we have a source with this UUID?
        if ns = _u(@sources).find( (s) => s.uuid == uuid )
            # we do... 
            # make sure it isn't already the active source, though
            if ns == @sources[0]
                # it is.  nothing to be done.
                cb? "Source is already active"
            else
                # it isn't. we can try to promote it
                @useSource ns, (status) =>
                    if status
                        cb? null, msg:"Promoted source to active.", uuid:uuid
                    else
                        cb? "Source promotion hit five second timeout."
        else
            cb? "Unable to find a source with that UUID on #{@key}"
    
    #----------
    
    configure: (new_opts,cb) ->
        # allow updates, but only to keys that are present in @DefaultOptions.
        for k,v of @DefaultOptions
            @opts[k] = new_opts[k] if new_opts[k]?
            
            # convert to a number if necessary
            @opts[k] = Number(@opts[k]) if _u.isNumber(@DefaultOptions[k])
            
        if @key != @opts.key
            @key = @opts.key
            
        # did they update the metaTitle?
        if new_opts.metaTitle
            @setMetadata title:new_opts.metaTitle
            
        @emit "config"
        
        cb? null, @status()
        
    #----------
    
    listeners: ->
        total = 0
        total += c.count for s,c of @_listeners
        total
        
    listenersBySlave: ->
        @_listeners
    
    #----------
    
    recordSlaveListeners: (slave,count) ->
        if !@_listeners[slave]
            @_listeners[slave] = count:0, last_at:null
            
        @_listeners[slave].count = count
        @_listeners[slave].last_at = Number(new Date)
    
    #----------
        
    destroy: ->
        # shut down our sources and go away
        s.disconnect() for s in @sources
        @emit "destroy"
        true
        