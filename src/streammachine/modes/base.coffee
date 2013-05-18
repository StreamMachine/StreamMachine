_u = require "underscore"

#----------

module.exports = class Core
    DefaultOptions:
        # after a new deployment, allow a one hour grace period for 
        # connected listeners
        max_zombie_life:    1000 * 60 * 60
        
    #----------
    
    # Build a hash of stream information, including sources and listener counts
    
    streamInfo: ->
        s.info() for k,s of @streams
        
    #----------
    
    # Start a replacement process with our same command line arguments, plus 
    # the --handoff flag. Returns the childprocess.
    
    _spawnReplacement: (cb) ->
        cp = require "child_process"
        
        # arguments are in process.argv
        opts = require("optimist").argv
        
        new_args = _u(opts).omit "$0", "_", "handoff"
        
        new_args = ( "--#{k}=#{v}" for k,v of new_args )
        new_args.push("--handoff=true")
        
        console.log "argv is ", process.argv, process.execPath
        console.log "Spawning ", opts.$0, new_args
        newp = cp.fork process.argv[1], new_args, stdio:"inherit"

        newp.on "error", (err) =>
            @log.error "Spawned child gave error: #{err}", error:err

        newp.once "message", (m) =>
            # if all goes well, this first message will be a string that 
            # says 'HANDOFF_GO'
            
            if m == "HANDOFF_GO"
                # Good. now we set up a HandoffTranslator object
                translator = new Core.HandoffTranslator newp
                
                console.log "sR Registering for streams"
                translator.once "streams", =>
                    console.log "spawnReplacement got STREAMS"
                    cb? null, translator
            else
                @log.error "Invalid first message from handoff.", message:m
    
    #----------
                
    class @HandoffTranslator extends require("events").EventEmitter
        constructor: (@p) ->
            @p.on "message", (msg,handle) =>
                console.log "TRANSLATE GOT #{msg.key}", msg, handle?
                if msg?.key
                    msg.data = {} if !msg.data
                    @emit msg.key, msg.data, handle
        
        send: (key,data,handle=null) ->
            console.log "TRANSLATE #{key}", data, handle?
            @p.send { key:key, data:data }, handle