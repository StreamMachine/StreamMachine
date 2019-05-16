path    = require "path"
fs      = require "fs"
_       = require "underscore"


# RewindDumpRestore is in charge of making periodic backups of a RewindBuffer's
# data. This is important for helping a crashed process get back up to
# speed quickly. The `settings` should define the directory to write
# dump files into and the frequency in seconds with which dumps should
# occur.

module.exports = class RewindDumpRestore extends require('events').EventEmitter
    constructor: (@master,@settings) ->
        @_streams       = {}
        @_queue         = []
        @_working       = false
        @_shouldLoad    = false

        @log = @master.log.child(module:"rewind_dump_restore")

        # -- make sure directory is valid -- #

        @_path = fs.realpathSync( path.resolve( process.cwd(), @settings.dir ) )

        if (s = fs.statSync(@_path))?.isDirectory()
            # good
        else
            @log.error "RewindDumpRestore path (#{@_path}) is invalid."
            return false

        # -- create agents for each stream -- #

        for s,obj of @master.streams
            @_streams[ s ] = new Dumper s, obj.rewind, @_path

            obj.once "destroy", =>
                delete @_streams[s]

        # watch for new streams
        @master.on "new_stream", (stream) =>
            @log.debug "RewindDumpRestore got new stream: #{stream.key}"
            @_streams[stream.key] = new Dumper stream.key, stream.rewind, @_path

        # -- set our interval -- #

        if (@settings.frequency||-1) > 0
            @log.debug "RewindDumpRestore initialized with interval of #{ @settings.frequency } seconds."
            @_int = setInterval =>
                @_triggerDumps()
            , @settings.frequency*1000


    #----------

    load: (cb) ->
        @_shouldLoad = true

        load_q = ( d for k,d of @_streams )

        results = success:0, errors:0

        _load = =>
            if d = load_q.shift()
                d._tryLoad (err,stats) =>
                    if err
                        @log.error "Load for #{ d.key } errored: #{err}", stream:d.key
                        results.errors += 1
                    else
                        results.success += 1

                    _load()
            else
                # done
                @log.info "RewindDumpRestore load complete.", success:results.success, errors:results.errors
                cb? null, results

        _load()

    #----------

    _triggerDumps: (cb) ->
        @log.silly "Queuing Rewind dumps"
        @_queue.push ( d for k,d of @_streams )...

        @_dump cb if !@_working

    #----------

    _dump: (cb) ->
        @_working = true

        if d = @_queue.shift()
            d._dump (err,file,timing) =>
                if err
                    if d.stream
                        @log.error "Dump for #{d.key} errored: #{err}", stream:d.stream.key
                    else
                        @log.error "Dump for #{d.key} errored (with no stream): #{err}"
                else
                    @log.debug "Dump for #{d.key} succeeded in #{ timing }ms."

                # for tests...
                @emit "debug", "dump", d.key, err, file:file, timing:timing

                @_dump cb

        else
            @_working = false
            cb?()

    #----------

    class Dumper extends require('events').EventEmitter
        constructor: (@key,@rewind,@_path) ->
            @_i             = null
            @_active        = false
            @_loaded        = null
            @_tried_load    = false

            @_filepath = path.join(@_path,"#{@rewind._rkey}.dump")

        #----------

        _tryLoad: (cb) ->
            # try loading our filepath. catch the error if it is not found
            rs = fs.createReadStream @_filepath

            rs.once "error", (err) =>
                @_setLoaded false

                if err.code == "ENOENT"
                    # not an error. just doesn't exist
                    return cb null

                cb err

            rs.once "open", =>
                @rewind.loadBuffer rs, (err,stats) =>
                    @_setLoaded true
                    cb null, stats

        #----------

        _setLoaded: (status) ->
            @_loaded        = status
            @_tried_load    = true
            @emit "loaded", status

        #----------

        once_loaded: (cb) ->
            if @_tried_load
                cb?()
            else
                @once "loaded", cb

        #----------

        _dump: (cb) ->
            if @_active
                cb new Error "RewindDumper failed: Already active for #{ @rewind._rkey }"
                return false

            if @rewind.isLoading()
                cb new Error "RewindDumper: Cannot dump while rewind buffer is loading."
                return false

            @_active = true
            start_ts = _.now()

            cb = _.once cb

            # -- open our output file -- #

            # To make sure we don't crash mid-write, we want to write to a temp file
            # and then get renamed to our actual filepath location.

            w = fs.createWriteStream "#{@_filepath}.new"

            w.once "open", =>
                @rewind.dumpBuffer (err,writer) =>
                    writer.pipe(w)

                    w.once "close", =>
                        if w.bytesWritten == 0
                            err = null
                            af = _.after 2, =>
                                end_ts = _.now()
                                @_active = false
                                cb err, null, end_ts - start_ts

                            fs.unlink "#{@_filepath}.new", (e) =>
                                err = e if e
                                af()

                            # we also want to unlink any existing dump file
                            fs.unlink @_filepath, (e) =>
                                err = e if e && e.code != "ENOENT"
                                af()

                        else
                            fs.rename "#{@_filepath}.new", @_filepath, (err) =>
                                if err
                                    cb err
                                    return false

                                end_ts = _.now()
                                @_active = false
                                cb null, @_filepath, end_ts - start_ts

            w.on "error", (err) =>
                cb err
