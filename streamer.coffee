StreamMachine   = require "./src/streammachine"
nconf           = require "nconf"

# -- do we have a config file to open? -- #

# get config from environment or command line
nconf.env().argv()

# add in config file
nconf.file( { file: nconf.get("config") || nconf.get("CONFIG") || "/etc/streammachine.conf" } )

# There are three potential modes of operation:
# 1) Standalone -- One server, handling boths streams and configuration
# 2) Master -- Central server in a master/slave setup. Does not handle any streams 
#    directly, but hands out config info to slaves and gets back logging.
# 3) Slave -- Connects to a master server for stream information.  Passes back 
#    logging data. Offers up stream connections to clients.

if nconf.get("master")
    # run as a master...
    core = new StreamMachine.MasterMode
        listen:         nconf.get("port")
        log:            nconf.get("log")
        master:         nconf.get("master")
        redis:          nconf.get("redis")
        source_port:    nconf.get("source_port")
        streams:        nconf.get("streams")
        
else if nconf.get("slave")
    # run as a slave
    core = new StreamMachine.SlaveMode
        listen:         nconf.get("port")
        log:            nconf.get("log")
        slave:          nconf.get("slave")
    
else 
    # run in standalone mode
    core = new StreamMachine.StandaloneMode
        listen:         nconf.get("port")
        log:            nconf.get("log")
        streams:        nconf.get("streams")
        source_port:    nconf.get("source_port")
        redis:          nconf.get("redis")
        