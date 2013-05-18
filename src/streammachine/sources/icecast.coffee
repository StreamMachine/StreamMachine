_u = require "underscore"

module.exports = class IcecastSource extends require("./base")    
    TYPE: -> "Icecast (#{[@sock.remoteAddress,@sock.remotePort].join(":")})"
    
    constructor: (@stream,@sock,@headers) ->
        super()
        
        @log = @stream.log
        
        @emitDuration  = 0.5
    
        # data is going to start streaming in as data on req. We need to pipe 
        # it into a parser to turn it into frames, headers, etc
        
        console.log "New Icecast source!"
        
        @parser = @_new_parser()
                
        @_chunk_queue = []
        @_chunk_queue_ts = null
        
        @last_header = null
        
        # incoming -> Parser
        @sock.pipe @parser
        
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
        
        @sock.on "close", =>
            @connected = false
            @log.debug "Icecast source got close event"
            @emit "disconnect"
            @sock.end()
            
        @sock.on "end", =>
            @connected = false
            @log.debug "Icecast source got end event"
            # source has gone away
            @emit "disconnect"
            @sock.end()

        # return with success
        @connected = true
    
    #----------
    
    info: ->
        source:     @TYPE?() ? @TYPE
        connected:  @connected
        url:        [@sock.remoteAddress,@sock.remotePort].join(":")
        streamKey: @streamKey
        uuid:       @uuid
    
    #----------
    
    disconnect: ->
        @res.end()
        @connected = false
        @emit "disconnect"