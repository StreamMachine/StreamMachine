_u = require "underscore"

module.exports = class Source extends require("events").EventEmitter
        
    #----------
    
    constructor: ->
        @uuid = null
        @streamKey = null
        @_vitals = null
            
    #----------
    
    _new_parser: ->
        new (require "../parsers/#{@stream.opts.format}")
    
    #----------
    
    setUUID: (uuid) ->
        @uuid = uuid
    
    #----------
        
    getStreamKey: (cb) ->
        if @streamKey
            cb? @streamKey
        else
            @once "vitals", => cb? @_vitals.streamKey
            
    #----------
    
    _setVitals: (vitals) ->
        @_vitals = vitals
        @emit "vitals", @_vitals
        
    vitals: (cb) ->
        if @_vitals
            cb? @_vitals
        else
            @once "vitals", => cb? @_vitals
        