_u = require "underscore"
express = require "express"
nconf = require "nconf"

Logger  = require "../logger"
Master  = require "../master"

# Master Server
# 
# Masters don't take client connections directly. They take incoming 
# source streams and proxy them to the slaves, providing an admin 
# interface and a point to consolidate logs and listener counts.

module.exports = class MasterMode extends require("./base")
    
    MODE: "Master"
    constructor: (opts) ->
        @log = new Logger opts.log
        @log.debug("Master Instance initialized")
        
        process.title = "StreamM:master"
        
        # create a master
        @master = new Master _u.extend {}, opts, logger:@log
        
        # Set up a server for our admin
        @server = express()
        @server.use "/s", @master.transport.app
        @server.use @master.admin.app
        
        if nconf.get("handoff")
            @_acceptHandoff()
            
        else
            @log.info "Listening."
            @handle = @server.listen opts.master.port
            @master.listenForSlaves(@handle)
            @master.sourcein.listen()
            
        process.on "SIGHUP", =>
            if @_restarting
                return false
                
            @_restarting = true

            @log.info "Master process got HUP. Restarting with handoff."
            
            # Start the new process and wait for streams signal
            @_spawnReplacement (err,translator) =>
                if err
                    @log.error "Error spawning replacement process: #{err}", error:err
                    return false
                    
                @_sendHandoff translator

    #----------
    
    _sendHandoff: (translator) ->
        @log.event "Got streams signal from new process."
        # Send master data (includes source port handoff)
        @master.sendHandoffData translator, (err) =>
            @log.event "Sent master data to new process."
            
            _afterSockets = _u.after 2, =>
                @log.info "Sockets transferred.  Exiting."
                process.exit()
            
            # Hand over the source port
            @log.info "Hand off source socket."
            translator.send "source_socket", {}, @master.sourcein.server
            
            translator.once "source_socket_up", =>
                _afterSockets()
                
            @log.info "Hand off master socket."
            translator.send "master_handle", {}, @handle

            translator.once "master_handle_up", =>
                _afterSockets()
        
    #----------
    
    _acceptHandoff: ->
        @log.info "Initializing handoff receptor."
        
        if !process.send?
            @log.error "Handoff called, but process has no send function. Aborting."
            return false
            
        console.log "Sending GO"
        process.send "HANDOFF_GO"
        
        # set up our translator
        translator = new MasterMode.HandoffTranslator process
        
        # watch for streams
        @master.once "streams", =>
            # signal that we're ready
            translator.send "streams"

            @master.loadHandoffData translator
            
            translator.once "source_socket", (msg,handle) =>
                @log.info "Got source socket."
                @master.sourcein.listen handle
                @log.info "Listening for sources!"
                translator.send "source_socket_up"
                
            translator.once "master_handle", (msg,handle) =>
                @log.info "Got master socket."
                @handle = @server.listen handle
                @master.listenForSlaves @handle
                @log.info "Master up!"
                translator.send "master_handle_up"
        
    #----------