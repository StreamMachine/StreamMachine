Icecast = require 'icecast'
_u      = require 'underscore'

util    = require 'util'
url     = require 'url'

module.exports = class ProxyRoom extends require("./base")
    DefaultOptions:
        url:     ""
        
    #----------
    
    TYPE: -> "Proxy (#{@url})"
    constructor: (@stream,@url) ->
        super()
        
        @connected      = false
        @framesPerSec   = null
        
        @_in_disconnect = false
        
        @emitDuration  = 0.5
        
        @_chunk_queue = []
        @_chunk_queue_ts = null
        
        @log = @stream.log
        
        @last_header = null
        
        # connection drop handling
        # (FIXME: bouncing not yet implemented)
        @_maxBounces    = 10
        @_bounces       = 0
        @_bounceInt     = 5
        
        @StreamTitle    = null
        @StreamUrl      = null
    
    #----------
    
    info: ->
        source:     @TYPE?() ? @TYPE
        connected:  @connected
        url:        @url
        streamKey: @streamKey
        uuid:       @uuid
    
    #----------
        
    connect: ->
        @log.debug "connecting to #{@url}"
        
        # attach mp3 parser for rewind buffer
        @parser = @_new_parser()
        
        url_opts = url.parse @url        
        url_opts.headers = "user-agent":"StreamMachine 0.1.0"
                
        Icecast.get url_opts, (ice) =>
            @icecast = ice
            
            @icecast.on "close", =>
                console.log "proxy got close event"
                unless @_in_disconnect
                    setTimeout ( => @connect() ), 5000
            
                    @log.debug "Lost connection to #{@url}. Retrying in 5 seconds"
                    @connected = false
            
            @icecast.on "metadata", (data) =>
                unless @_in_disconnect
                    meta = Icecast.parse(data)
                    console.log "metadata is ", meta
            
                    if meta.StreamTitle
                        @StreamTitle = meta.StreamTitle
            
                    if meta.StreamUrl
                        @StreamUrl = meta.StreamUrl
                
                    @emit "metadata", StreamTitle:@StreamTitle, StreamUrl:@StreamUrl

            # incoming -> Parser
            @icecast.on "data", (chunk) => @parser.write chunk
            
            # return with success
            @connected = true
        
        # outgoing -> Stream
        @parser.on "frame", (frame) =>
            @emit "frame", frame

            # -- queue up frames until we get to @emitDuration -- #
            if @last_header
                # -- recombine frame and header -- #
                
                fbuf = new Buffer( @last_header.length + frame.length )
                @last_header.copy(fbuf,0)
                frame.copy(fbuf,@last_header.length)
                @_chunk_queue.push fbuf
                
                if !@_chunk_queue_ts
                    @_chunk_queue_ts = (new Date)
                
                if @framesPerSec && ( @_chunk_queue.length / @framesPerSec > @emitDuration )
                    len = 0
                    len += b.length for b in @_chunk_queue
                
                    # make this into one buffer
                    buf = new Buffer(len)
                    pos = 0
                
                    for fb in @_chunk_queue
                        fb.copy(buf,pos)
                        pos += fb.length
                        
                    buf_ts = @_chunk_queue_ts
                    
                    duration = (@_chunk_queue.length / @framesPerSec)
                    
                    # reset chunk array
                    @_chunk_queue.length = 0
                    @_chunk_queue_ts = (new Date)
                
                    # emit new buffer
                    @emit "data", 
                        data:       buf 
                        ts:         buf_ts
                        duration:   duration
                        streamKey:  @streamKey
                    
        
        # we need to grab one frame to compute framesPerSec
        @parser.on "header", (data,header) =>
            if !@framesPerSec || !@streamKey
                # -- compute frames per second and stream key -- #
                
                if @stream.opts.format == 'mp3'
                    @framesPerSec = header.samplingRateHz / header.samplesPerFrame                    
                    @streamKey = ['mp3',header.samplingRateHz,header.bitrateKBPS,(if header.modeName in ["Stereo","J-Stereo"] then "s" else "m")].join("-")
                
                else if @stream.opts.format == 'aac'
                    # each AAC frame is 1024 samples
                    @framesPerSec = header.sample_freq * 1000 / 1024
                    @streamKey = ['aac',header.sample_freq,header.profile,header.channels].join("-")
                    
                @log.debug "setting framesPerSec to ", frames:@framesPerSec
                @log.debug "first header is ", header
                
                # -- send out our stream vitals -- #    

                @_setVitals
                    streamKey:          @streamKey
                    framesPerSec:       @framesPerSec
                    emitDuration:       @emitDuration
                
            @last_header = data
            @emit "header", data, header

        
    #----------
        
    disconnect: ->
        @_in_disconnect = true
        
        @icecast.removeAllListeners()
        @parser.removeAllListeners()
        @removeAllListeners()
        
        @icecast.end()        
        
        @parser = null
        @icecast = null
        
        console.log "Shut down proxy source using #{@url}"
    