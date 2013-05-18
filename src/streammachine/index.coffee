_u      = require "underscore"
url     = require 'url'
http    = require "http"
nconf   = require "nconf"



module.exports = class StreamMachine
    @StandaloneMode: require "./modes/standalone"
    @MasterMode:     require "./modes/master"
    @SlaveMode:      require "./modes/slave"
                                        
