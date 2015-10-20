express = require "express"
debug = require("debug")("sm:utils:fake_transcoder")
fs = require "fs"

module.exports = class FakeTranscoder extends require("events").EventEmitter
    constructor: (@port,@files_dir) ->
        
        @app = express()
        
        @app.get "/encoding", (req,res) =>
            key = req.query["key"]
            uri = req.query["uri"]
            
            return res.status(400).end "Key and URI are required." if !key || !uri
            
            debug "Fake Transcoder request for #{key}: #{uri}"
            
            @emit "request", key:key, uri:uri
            
            try
                # FIXME: recognize extension to support aac
                s = fs.createReadStream "#{@files_dir}/#{key}.mp3"
                res.status(200)
                s.pipe(res)
                
            catch e
                res.status(500).end "Failed to open static file: #{e}"
                
        s = @app.listen @port
        
        @port = s.address().port if @port == 0
        