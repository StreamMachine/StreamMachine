express = require "express"
_u = require("underscore")
util = require 'util'
fs = require 'fs'
path = require 'path'

module.exports = class Server extends require('events').EventEmitter
    DefaultOptions:
        core:           null
        slave_mode:     false
        mount_admin:    true
    
    constructor: (opts) ->
        @opts = _u.defaults opts||{}, @DefaultOptions
        
        @core = @opts.core
        
        @app = express()
        @app.httpAllowHalfOpen = true
        @app.useChunkedEncodingByDefault = false
        
        # -- Stream Finder -- #
        
        @app.param "stream", (req,res,next,key) =>
            # make sure it's a valid stream key
            if key? && s = @core.streams[ key ]
                req.stream = s
                next()
            else
                res.status(404).end "Invalid stream.\n"
                                    
        #@server.use (req,res,next) => @streamRouter(req,res,next)
        
        # -- Funky URL Rewriters -- #
        
        @app.use (req,res,next) =>
            if @core.root_route
                if req.url == '/' || req.url == "/;stream.nsv" || req.url == "/;"
                    req.url = "/#{@core.root_route}"
                    next()
                else if req.url == "/listen.pls"
                    req.url = "/#{@core.root_route}.pls"
                else
                    next()
            else
                next()
        
        # -- Utility Routes -- #
        
        @app.get "/index.html", (req,res) =>
            res.set "content-type", "text/html"
            res.set "connection", "close"
            
            res.status(200).end """
                <html>
                    <head><title>StreamMachine</title></head>
                    <body>
                        <h1>OK</h1>
                    </body>
                </html>
            """
                    
        @app.get "/crossdomain.xml", (req,res) =>
            res.set "content-type", "text/xml"
            res.set "connection", "close"
            
            res.status(200).end """
                <?xml version="1.0"?>
                <!DOCTYPE cross-domain-policy SYSTEM "http://www.macromedia.com/xml/dtds/cross-domain-policy.dtd">
                <cross-domain-policy>
                <allow-access-from domain="*" />
                </cross-domain-policy>
            """
        # -- Stream Routes -- #
        
        # playlist file
        @app.get "/:stream.pls", (req,res) =>
            res.set "X-Powered-By", "StreamMachine"
            res.set "content-type", "audio/x-scpls"
            res.set "connection", "close"

            host = req.headers?.host || req.stream.options.host
        
            res.status(200).end "[playlist]\nNumberOfEntries=1\nFile1=http://#{host}/#{req.stream.key}/\n"
        
        # head request    
        @app.head "/:stream", (req,res) =>
            res.set "content-type", "audio/mpeg"            
            res.status(200).end()

        # listen to the stream
        @app.get "/:stream", (req,res) =>
            res.set "X-Powered-By", "StreamMachine"
            
            console.log "stream is ", req.stream.key
            console.log "format is ", req.param[0]
            
            # -- Stream match! -- #
        
            if req.param("socket")
                # socket listener
                @core.sockets.addListener req.stream,req,res
                
            else if req.param("pump")
                # pump listener pushes from the buffer as fast as possible
                new @core.Outputs.pumper req.stream, req, res
                
            else
                # normal live stream (with or without shoutcast)
                if req.headers['icy-metadata']
                    # -- shoutcast listener -- #
                    new @core.Outputs.shoutcast req.stream, req:req, res:res
                else
                    # -- straight mp3 listener -- #
                    new @core.Outputs.raw req.stream, req:req, res:res
    
    #----------
    
    listen: (port) ->
        console.log "Start listening"
        @hserver = @app.listen port
        @io = require("socket.io").listen @hserver
        @emit "io_connected", @io
        @hserver
        
    #----------
        
    stopListening: ->
        console.log "stopListening"
        @hserver?.close => console.log "listening stopped."
        