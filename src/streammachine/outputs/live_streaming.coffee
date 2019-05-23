_   = require "underscore"
tz  = require "timezone"
uuid = require "node-uuid"

BaseOutput = require "./base"

PTS_TAG = Buffer.from(Number("0x#{s}") for s in """
    49 44 33 04 00 00 00 00 00 3F 50 52 49 56 00 00 00 35 00 00 63 6F 6D
    2E 61 70 70 6C 65 2E 73 74 72 65 61 6D 69 6E 67 2E 74 72 61 6E 73 70
    6F 72 74 53 74 72 65 61 6D 54 69 6D 65 73 74 61 6D 70 00 00 00 00 00
    00 00 00 00
    """.split(/\s+/))

module.exports = class LiveStreaming extends BaseOutput
    constructor: (@stream,@opts) ->

        super "live_streaming"

        @stream.listen @,
            live_segment:   @opts.req.param("seg")
            pumpOnly:       true
        , (err,playHead,info) =>
            if err
                @opts.res.status(404).end "Segment not found."
                return false

            # write our PTS tag
            tag = null
            if info.pts
                tag = Buffer.from(PTS_TAG)
                # node 0.10 doesn't know how to write ints over 32-bit, so
                # we do some gymnastics to get around it
                if info.pts > Math.pow(2,32)-1
                    tag[0x44] = 0x01
                    tag.writeUInt32BE(info.pts-(Math.pow(2,32)-1),0x45)
                else
                    tag.writeUInt32BE(info.pts,0x45)

            headers =
                "Content-Type":
                    if @stream.opts.format == "mp3"         then "audio/mpeg"
                    else if @stream.opts.format == "aac"    then "audio/aac"
                    else "unknown"
                "Connection":           "close"
                "Content-Length":       info.length + tag?.length||0

            # write out our headers
            @opts.res.writeHead 200, headers

            @opts.res.write tag if tag

            # send our pump buffer to the client
            playHead.pipe(@opts.res)

            @opts.res.on "finish", =>
                playHead.disconnect()

            @opts.res.on "close",    => playHead.disconnect()
            @opts.res.on "end",      => playHead.disconnect()

    #----------

    prepForHandoff: (cb) ->
        # we don't do handoffs, so send skip = true
        cb true

    #----------

    class @Index extends BaseOutput
        constructor: (@stream,@opts) ->
            super "live_streaming"

            session_info = if @client.session_id && @client.pass_session
               "?session_id=#{@client.session_id}"

            # HACK: This is needed to get ua information on segments until we
            # can fix client ua for AppleCoreMedia
            if @opts.req.param("ua")
                session_info = if session_info then "#{session_info}&ua=#{@opts.req.param("ua")}" else "?ua=#{@opts.req.param("ua")}"

            if !@stream.hls
                @opts.res.status(500).end "No data."
                return

            # which index should we give them?
            outFunc = (err,writer) =>
                if writer
                    @opts.res.writeHead 200,
                        "Content-type":     "application/vnd.apple.mpegurl"
                        "Content-length":   writer.length()

                    writer.pipe(@opts.res)

                else
                   @opts.res.status(500).end "No data."

            if @opts.req.hls_limit
                @stream.hls.short_index session_info, outFunc
            else
                @stream.hls.index session_info, outFunc

    #----------

    class @GroupIndex extends BaseOutput
        constructor: (@group,@opts) ->

            super "live_streaming"

            @opts.res.writeHead 200,
                "Content-type": "application/vnd.apple.mpegurl"

            # who do we ask for the session id?
            @group.startSession @client, (err) =>
                @opts.res.write """
                #EXTM3U

                """

                for key,s of @group.streams
                    url = "/#{s.key}.m3u8"
                    session_bits = []

                    if @client.pass_session
                        session_bits.push "session_id=#{@client.session_id}"

                    if @opts.req.param("ua")
                        session_bits.push "ua=#{@opts.req.param("ua")}"

                    if session_bits.length > 0
                        url = "#{url}?#{session_bits.join("&")}"

                    @opts.res.write """
                    #EXT-X-STREAM-INF:BANDWIDTH=#{s.opts.bandwidth},CODECS="#{s.opts.codec}"
                    #{url}\n
                    """

                @opts.res.end()
