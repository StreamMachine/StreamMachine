_u      = require 'underscore'
icecast = require "icecast"

module.exports = class Shoutcast
    constructor: (@stream,@opts) ->
        @id = null
        @socket = null
        
        @stream.log.debug "request is in Shoutcast output", stream:@stream.key
        
        @client = output:"shoutcast"
        @pump = true
        
        if @opts.req && @opts.res
            # -- startup mode...  sending headers -- #
            
            @client.ip          = @opts.req.connection.remoteAddress
            @client.path        = @opts.req.url
            @client.ua          = _u.compact([@opts.req.param("ua"),@opts.req.headers?['user-agent']]).join(" | ")
            @client.offset      = @opts.req.param("offset") || -1
            @client.meta_int    = @stream.opts.meta_interval
            
            @opts.res.chunkedEncoding = false
            @opts.res.useChunkedEncodingByDefault = false
            
            @headers = 
                "Content-Type":         
                    if @stream.opts.format == "mp3"         then "audio/mpeg"
                    else if @stream.opts.format == "aac"    then "audio/aacp"
                    else "unknown"
                "icy-name":             @stream.StreamTitle
                "icy-url":              @stream.StreamUrl
                "icy-metaint":          @client.meta_int
                        
            # write out our headers
            @opts.res.writeHead 200, @headers
            @opts.res._send ''
            
            @socket = @opts.req.connection
            
            process.nextTick =>     
                # -- send a preroll if we have one -- #
        
                if @stream.preroll && !@req.param("preskip")
                    @stream.log.debug "making preroll request"
                    @stream.preroll.pump @socket, => @connectToStream()
                else
                    @connectToStream()       
            
        else if @opts.socket
            # -- socket mode... just data -- #
            
            @client = @opts.client
            @socket = @opts.socket
            @pump = false
            process.nextTick => @connectToStream()
        
        # register our various means of disconnection
        @socket.on "end",   => @disconnect()
        @socket.on "close", => @disconnect()
        
    #----------
    
    disconnect: (force=false) ->
        if force || @socket.destroyed
            @source?.disconnect()            
            @socket?.end() unless (@socket?.destroyed)
    
    #----------
            
    prepForHandoff: (cb) ->
        # we need to know where we are in relation to the icecast metaint 
        # boundary so that we can set up our new stream and keep everything 
        # in sync
        
        @client.bytesToNextMeta = @ice._parserBytesLeft
        cb?()
    
    #----------
    
    connectToStream: ->
        unless @socket.destroyed
            @source = @stream.listen @, offset:@client.offset, pump:@pump
            
            # update our offset now that it's been checked for availability
            @client.offset = @source.offset()
            
            # -- create an Icecast creator to inject metadata -- #
            
            @ice = new icecast.Writer @client.meta_int, initialMetaInt:@client.bytesToNextMeta||null   
            @ice.queue StreamTitle:@stream.StreamTitle, StreamUrl:@stream.StreamUrl
        
            @metaFunc = (data) =>
                @ice.queue data if data.StreamTitle

            @ice.pipe(@socket)
            
            # -- pipe source audio to icecast -- #
            
            @source.pipe @ice
            @source.on "meta", @metaFunc
        
    #----------
            
