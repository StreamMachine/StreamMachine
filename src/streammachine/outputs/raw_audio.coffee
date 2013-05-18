_u = require 'underscore'

module.exports = class RawAudio
    constructor: (@stream,@opts) ->
        @id = null
        
        @client = output:"raw"
        @pump = true
        
        if @opts.req && @opts.res
            @client.ip      = @opts.req.connection.remoteAddress
            @client.path    = @opts.req.url
            @client.ua      = _u.compact([@opts.req.param("ua"),@opts.req.headers?['user-agent']]).join(" | ")
            @client.offset  = @opts.req.param("offset") || -1
            
            @opts.res.chunkedEncoding = false
            @opts.res.useChunkedEncodingByDefault = false
            
            headers = 
                "Content-Type":         
                    if @stream.opts.format == "mp3"         then "audio/mpeg"
                    else if @stream.opts.format == "aac"    then "audio/aacp"
                    else "unknown"
            
            # write out our headers
            @opts.res.writeHead 200, headers
            @opts.res._send ''
            
            @socket = @opts.req.connection
            
            process.nextTick =>
        
                # -- send a preroll if we have one -- #
        
                if @stream.preroll && !@req.param("preskip")
                    @stream.log.debug "making preroll request", stream:@stream.key
                    @stream.preroll.pump @res, => @connectToStream()
                else
                    @connectToStream()
            
        else if @opts.socket
            # -- just the data -- #
            
            @client = @opts.client
            @socket = @opts.socket
            @pump = false
            process.nextTick => @connectToStream()
            
        else
            # fail
            @stream.log.error "Listener passed without connection handles or socket."
            
        # register our various means of disconnection
        @socket.on "end",   => @disconnect()
        @socket.on "close", => @disconnect()
        
    #----------
    
    disconnect: (force=false) ->
        if force || @socket.destroyed
            @source?.disconnect()            
            @socket?.end() unless (@socket.destroyed)
    
    #----------
    
    prepForHandoff: (cb) ->
        cb?()
    
    #----------
    
    connectToStream: ->
        unless @socket.destroyed
            @source = @stream.listen @, offset:@client.offset, pump:@pump
            
            # update our offset now that it's been checked for availability
            @client.offset = @source.offset()
            
            @source.pipe @socket