_       = require "underscore"
express = require "express"
nconf   = require "nconf"

Logger  = require "../logger"
Master  = require "../master"

RPC     = require "ipc-rpc"

# Master Server
#
# Masters don't take client connections directly. They take incoming
# source streams and proxy them to the slaves, providing an admin
# interface and a point to consolidate logs and listener counts.

module.exports = class MasterMode extends require("./base")

    MODE: "Master"
    constructor: (@opts,cb) ->
        @log = new Logger opts.log
        @log.debug("Master Instance initialized")

        process.title = "StreamM:master"

        super

        # create a master
        @master = new Master _.extend {}, @opts, logger:@log

        # Set up a server for our admin
        @server = express()
        @server.use "/s",   @master.transport.app
        @server.use "/api", @master.api.app

        @server.use "/metrics", @master.prometheus.app if @master.prometheus

        if process.send?
            @_rpc = new RPC process, functions:
                OK: (msg,handle,cb) ->
                    cb null, "OK"

                master_port: (msg,handle,cb) =>
                    cb null, @handle?.address().port||"NONE"

                source_port: (msg,handle,cb) =>
                    cb null, @master.sourcein?.server.address()?.port||"NONE"

                streams: (streams,handle,cb) =>
                    @master.configureStreams streams, (err) =>
                        cb err, @master.config().streams

                start_handoff: (msg,handle,cb) =>
                    @_sendHandoff()
                    cb null, "OK"

        if nconf.get("handoff")
            @_handoffStart cb
        else
            @_normalStart cb

    #----------

    _handoffStart: (cb) ->
        @_acceptHandoff (err) =>
            if err
                @log.error "_handoffStart Failed! Falling back to normal start: #{err}"
                @_normalStart cb

    #----------

    _normalStart: (cb) ->
        # load any rewind buffers from disk
        @master.loadRewinds()

        @handle = @server.listen @opts.master.port
        @master.slaves.listen(@handle)
        @master.sourcein.listen()

        @log.info "Listening."

        cb? null, @

    #----------

    _sendHandoff: (rpc) ->
        @log.event "Got handoff signal from new process."

        rpc.once "config", (msg,handle,cb) =>
            # send our streams info so we make sure our configs are matched
            rpc.request "streams", @master.config().streams, (err,streams) =>
                if err
                    @log.error "Error setting streams on new process: #{err}"
                    cb "Error sending streams: #{err}"
                    return false

                @log.info "New Master confirmed stream configuration."

                # basically we leave the config request open while we send streams
                cb()

                # Send master data (includes source port handoff)
                @master.sendHandoffData rpc, (err) =>
                    @log.event "Sent master data to new process."

                    _afterSockets = _.after 2, =>
                        @log.info "Sockets transferred.  Exiting."
                        process.exit()

                    # Hand over the source port
                    @log.info "Hand off source socket."
                    rpc.request "source_socket", null, @master.sourcein.server, (err) =>
                        @log.error "Error sending source socket: #{err}" if err
                        _afterSockets()

                    @log.info "Hand off master socket."
                    rpc.request "master_handle", null, @handle, (err) =>
                        @log.error "Error sending master handle: #{err}" if err
                        _afterSockets()

    #----------

    _acceptHandoff: (cb) ->
        @log.info "Initializing handoff receptor."

        if !@_rpc
            cb new Error "Handoff called, but no RPC interface set up."
            return false

        # If we don't get HANDOFF_GO quickly, something is probably wrong.
        # Perhaps we've been asked to start via handoff when there's no process
        # out there to send us data.
        handoff_timer = setTimeout =>
            cb new Error "Handoff failed to handshake within five seconds."
        , 5000

        @_rpc.once "HANDOFF_GO", (msg,handle,cb) =>
            clearTimeout handoff_timer

            cb null, "GO"

            # watch for streams
            @master.once_configured =>
                # signal that we're ready
                @_rpc.request "config", @master.config(), (err,reply) =>
                    if err
                        @log.error "Failed to send config broadcast when starting handoff: #{err}"
                        return false

                    @log.info "Handoff initiator ACKed our config broadcast."

                    @master.loadHandoffData @_rpc, =>
                        @log.info "Handoff receiver believes all stream and source data has arrived."

                    aFunc = _.after 2, =>
                        @log.info "Source and Master handles are up."
                        cb? null, @

                    @_rpc.once "source_socket", (msg,handle,cb) =>
                        @log.info "Source socket is incoming."
                        @master.sourcein.listen handle
                        cb null
                        aFunc()

                    @_rpc.once "master_handle", (msg,handle,cb) =>
                        @log.info "Master socket is incoming."
                        @handle = @server.listen handle
                        @master.slaves?.listen @handle
                        cb null
                        aFunc()

    #----------
