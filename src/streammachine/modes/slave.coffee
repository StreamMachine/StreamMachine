_u = require "underscore"
nconf = require "nconf"

Logger  = require "../logger"
Slave   = require "../slave"

# Slave Server
#
# Slaves are born only knowing how to connect to their master. The master 
# gives them stream configuration, which the slave then uses to connect 
# and provide up streams to clients.  Logging data is always passed back 
# to the master, but can optionally also be stored on the slave host.

module.exports = class SlaveMode extends require("./base")
    
    MODE: "Slave"
    constructor: (opts) ->
        @log = new Logger opts.log
        @log.debug("Slave Instance initialized")
        
        process.title = "StreamM:slave"
        
        # create a slave
        @slave = new Slave _u.extend opts, logger:@log
        
        if nconf.get("handoff")
            @_acceptHandoff()
            
        else
            @log.info "Slave listening."
            @slave.server.listen opts.listen
    
    #----------
    
    _sendHandoff: ->
            
    _acceptHandoff: ->