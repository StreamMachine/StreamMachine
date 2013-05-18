_u = require 'underscore'
url = require('url')

module.exports = class Sockets
    DefaultOptions:
        source:         null
        min_digits:     6
        
    constructor: (options) ->
        @options = _u(_u({}).extend(@DefaultOptions)).extend( options || {} )
        
        @io     = @options.io
        @core   = @options.core
        
        @sessions = {}
        
        _u(@core.streams).each (v,k) =>
            # register connection listener
            @io.of("/#{k}").on "connection", (sock) =>
                console.log "connection is ", sock.id
                console.log "stream is #{k}"
                
                @sessions[sock.id] ||= {
                    id:         sock.id
                    stream:     v
                    log:        v.log.child(output:"sockets", sock:sock.id)
                    rewind:     v.rewind
                    socket:     sock
                    listener:   null
                    offset:     1
                }
                
                sess = @sessions[sock.id]
                
                # add offset listener
                sock.on "offset", (i,fn) =>
                    # this might be called with a stream connection active, 
                    # or it might not.  we have to check
                    if sess.listener
                        sess.listener.setOffset(i)
                        sess.offset = sess.listener._playHead
                    else
                        # just set it on the socket.  we'll use it when they connect
                        sess.offset = sess.rewind.checkOffset i
                
                    secs = sess.offset / sess.rewind.framesPerSec
                    sess.log.debug offset:sess.offset, "Offset by #{secs} seconds"
                    
                    fn? secs

                # send ready signal
                sock.emit "ready",
                    time:       new Date
                    buffered:   v.rewind.bufferedSecs()
                    
                sess.log.debug "Sent ready signal"
                    
                # set stream timecheck
                setInterval( =>
                    sock.emit "timecheck",
                        time:       new Date
                        buffered:   v.rewind.bufferedSecs()
                , 5000)
    
    #----------
            
    addListener: (stream,req,res) ->
        requrl = url.parse(req.url,true)
        
        if requrl.query.socket? && sess = @sessions[requrl.query.socket]
            listen = new Sockets.Listener sess,req,res,sess.rewind,sess.offset
            sess.listener = listen
            console.log "wired listener to session #{sess.id}"

    #----------
        
    class @Listener
        constructor: (session,req,res,rewind,offset=1) ->
            @req = req
            @res = res
            @rewind = rewind
            
            @res.chunkedEncoding = false
            @res.useChunkedEncodingByDefault = false

            @reqIP      = req.connection.remoteAddress
            @reqPath    = req.url
            @reqUA      = req.headers?['user-agent']

            # set our internal offset to be live by default
            @_offset = offset
            @_playHead = 1
                        
            # register our listener
            session.stream.registerListener(@)
            
            headers = 
                "Content-Type":         "audio/mpeg"
                "Connection":           "keep-alive"
                "Content-Range":        "bytes 0-*/*"
                "Accept-Ranges":        "none"

            # write out our headers
            res.writeHead 200, headers
            
            # and register to sending data...
            @rewind.addListener @

            @req.connection.on "close", =>
                # stop listening to stream
                @rewind.removeListener @  
                
                # note listener close
                session.stream.closeListener @

        #----------

        writeFrame: (chunk) ->
            @res.write chunk

        #----------

        setOffset: (offset) ->
            @_playHead = @rewind.checkOffset offset
            @_offset = @rewind.burstFrom @_playHead, @
