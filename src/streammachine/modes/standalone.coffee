_u = require "underscore"
express = require "express"
nconf   = require "nconf"

Logger  = require "../logger"
Master  = require "../master"
Slave   = require "../slave"

module.exports = class StandaloneMode extends require("./base")
    MODE: "StandAlone"
    constructor: (opts) ->
        @options = _u.defaults opts||{}, @DefaultOptions
        
        # -- Set up logging -- #
        
        @log = (new Logger @options.log).child pid:process.pid
        @log.debug("StreamMachine standalone initialized.")
        
        process.title = "StreamMachine"
        
        @streams = {}
                    
        # -- Set up master and slave -- #
        
        @master = new Master _u.extend {}, opts, logger:@log.child(mode:"master")
        @slave  = new Slave _u.extend {}, opts, logger:@log.child(mode:"slave"), max_zombie_life:5000
        
        # -- Set up combined server -- #
        
        @server = express()
        @server.use "/admin", @master.admin.app
        @server.use @slave.server.app
        
        # -- Handoff? -- #
        
        if nconf.get("handoff")
            @_runHandoff()
        
        else
            @log.info "Attaching listeners."
            @master.sourcein.listen()
            @handle = @server.listen opts.listen
                    
        # proxy data events from master -> slave
        @master.on "streams", (streams) =>
            @slave.configureStreams @master.config().streams                
            @slave._onConnect()
            
            #console.log "in standalone streams", streams
            process.nextTick =>
                for k,v of streams 
                    console.log "looking to attach #{k}", @streams[k]?, @slave.streams[k]?
                    if @streams[k]
                        # got it already
                        
                    else
                        if @slave.streams[k]?
                            console.log "mapping master -> slave on #{k}"
                            @slave.streams[k].useSource v
                            @streams[k] = true
                        else
                            console.log "Unable to map master -> slave for #{k}"
                
        @slave.on "listeners", (obj) =>
            @master._recordListeners "standalone", obj
        
        @log.debug "Standalone is listening on port #{@options.listen}"
        
        # -- restart handling -- #
        
        process.on "SIGHUP", =>
            if @_restarting
                # we've already been asked to restart.  do nothing more
                return false
            
            @_restarting = true
            
            # We've been asked to restart.  We do so by starting up a new 
            # process and scripting the handoff of master and slave data
            
            @log.event "Standalone process asked to restart."
            
            # Start the new process and wait for streams signal
            @_spawnReplacement (err,translator) =>
                @log.event "Got streams signal from new process."
                # Send master data (includes source port handoff)
                @master.sendHandoffData translator, (err) =>
                    @log.event "Sent master data to new process."
                    
                    # Hand over our public listening port
                    @log.info "Hand off standalone socket."
                    translator.send "standalone_socket", {}, @handle
                    
                    translator.once "standalone_socket_up", =>
                        @log.info "Got standalone socket confirmation. Closing listener."
                        @handle.unref()
                            
                        # Hand over the source port
                        @log.info "Hand off source socket."
                        translator.send "source_socket", {}, @master.sourcein.server
                
                        translator.once "source_socket_up", =>
                            @log.info "Got source socket confirmation. Closing listener."
                            @master.sourcein.server.unref()
                 
                            # Send slave data
                            @slave.sendHandoffData translator, (err) =>
                                @log.event "Sent slave data to new process. Exiting."

                                # Exit
                                process.exit()
    
    #----------
                    
    _runHandoff: ->
        @log.info "Initializing handoff receptor."
        
        if !process.send?
            @log.error "Handoff called, but process has no send function. Aborting."
            return false
            
        console.log "Sending GO"
        process.send "HANDOFF_GO"
        
        # set up our translator
        translator = new StandaloneMode.HandoffTranslator process
        
        # watch for streams
        @master.once "streams", =>
            console.log "Sending STREAMS"
            # signal that we're ready
            translator.send "streams"

            @master.loadHandoffData translator
            @slave.loadHandoffData translator
            
            # -- socket handovers -- #
            
            translator.once "standalone_socket", (msg,handle) =>
                @log.info "Got standalone socket."
                @handle = @server.listen handle
                @log.info "Listening!"
                translator.send "standalone_socket_up"
                
            translator.once "source_socket", (msg,handle) =>
                @log.info "Got source socket."
                @master.sourcein.listen handle
                @log.info "Listening for sources!"
                translator.send "source_socket_up"