strtok = require('strtok2')
assert = require("assert")

PROFILES = [
    "Null",
    "AAC Main"
    "AAC LC"
    "AAC SSR"
    "AAC LTP"
    "SBR"
    "AAC Scalable"
    "TwinVQ"
]

SAMPLE_FREQUENCIES = [
    96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350
]

CHANNEL_COUNTS = [
    0,1,2,3,4,5,6,8
]

MPEG_HEADER_LENGTH  = 4
ID3V2_HEADER_LENGTH = 10

MPEG_HEADER             = new strtok.BufferType(MPEG_HEADER_LENGTH)
REST_OF_ID3V2_HEADER    = new strtok.BufferType(ID3V2_HEADER_LENGTH - MPEG_HEADER_LENGTH)

module.exports = class AAC extends require("stream").Writable

    FIRST_BYTE = new strtok.BufferType(1)

    constructor: ->
        super

        # create an internal stream to pass to strtok
        @istream = new (require("events").EventEmitter)

        @_flushing = false

        # set up status
        @frameSize  = -1
        @beginning  = true
        @gotFF      = false
        @byteTwo    = null
        @isCRC      = false
        @gotID3     = 0

        @frameHeader    = null
        @frameHeaderBuf = null

        @id3v2              = null
        @_parsingId3v2      = false
        @_finishingId3v2    = false
        @_id3v2_1           = null
        @_id3v2_2           = null

        @once "finish", =>
            @_flushing = setTimeout =>
                @emit "end"
            , 500

        _emitAndMaybeEnd = (args...) =>
            @emit args...

            if @_flushing
                clearTimeout @_flushing
                @_flushing = setTimeout =>
                    @emit "end"
                , 500

        strtok.parse @istream, (v,cb) =>
            # -- initial request -- #

            if v == undefined
                # we need to examine each byte until we get a FF
                return FIRST_BYTE

            # -- ID3v2 tag -- #

            if @_parsingId3v2
                # we'll already have @id3v2 started with versionMajor and
                # our first byte in @_id3v2_1

                @id3v2.versionMinor = v[0]
                @id3v2.flags = v[1]

                # calculate the length
                @id3v2.length =  (v[5] & 0x7f) | (( v[4] & 0x7f ) << 7) | (( v[3] & 0x7f ) << 14) | (( v[2] & 0x7f ) << 21)

                @_parsingId3v2 = false;
                @_finishingId3v2 = true;
                @_id3v2_2 = v;

                return new strtok.BufferType @id3v2.length

            if @_finishingId3v2
                # step 3 in the ID3v2 parse...
                b = Buffer.concat([@_id3v2_1, @_id3v2_2, v])
                _emitAndMaybeEnd 'id3v2', b

                @_finishingId3v2 = false

                return FIRST_BYTE;

            # -- frame header -- #

            if @frameSize == -1 && @frameHeader
                # we're on-schedule now... we've had a valid frame.
                # buffer should be seven or nine bytes

                tag = v.toString 'ascii', 0, 3

                if tag == 'ID3'
                    # parse ID3v2 tag
                    _emitAndMaybeEnd "debug", "got an ID3"
                    @_parsingId3v2 = true
                    @id3v2 = versionMajor:v[3]
                    @_id3v2_1 = v

                    return REST_OF_ID3V2_HEADER
                else
                    try
                        h = @parseFrame(v)
                    catch e
                        # uh oh...  bad news
                        console.log "invalid header... ", v, @frameHeader
                        @frameHeader = null
                        return FIRST_BYTE

                    @frameHeader    = h
                    @frameHeaderBuf = v
                    _emitAndMaybeEnd "header", h
                    @frameSize = @frameHeader.frame_length

                    if @frameSize == 1
                        # problem...  just start over
                        console.log "Invalid frame header: ", h
                        return FIRST_BYTE
                    else
                        return new strtok.BufferType(@frameSize - v.length);

            # -- first header -- #

            if @gotFF and @byteTwo
                buf = Buffer.alloc(2+v.length)
                buf[0] = 0xFF
                buf[1] = @byteTwo
                v.copy(buf,2)

                try
                    h = @parseFrame(buf)
                catch e
                    # invalid header...  chuck everything and try again
                    console.log "chucking invalid try at header: ", buf
                    @gotFF = false
                    @byteTwo = null
                    return FIRST_BYTE

                # valid header...  we're on schedule now
                @gotFF = false
                @byteTwo = null
                @beginning = false

                @frameHeader    = h
                @frameHeaderBuf = buf
                _emitAndMaybeEnd "header", h
                @frameSize = @frameHeader.frame_length

                @isCRC = h.crc

                if @frameSize == 1
                    # problem...  just start over
                    console.log "Invalid frame header: ", h

                    return FIRST_BYTE
                else
                    #console.log "On-tracking with frame of: ", @frameSize - buf.length
                    return new strtok.BufferType(@frameSize - buf.length);

            if @gotFF
                if v[0]>>4 == 0xF
                    @byteTwo = v[0]

                    # make sure the layer bits are zero...  still need to make
                    # sure we're on a valid header

                    if (v[0] & 6) == 0
                        # good... both zeros...

                        # we need to figure out whether we're looking for CRC.  If
                        # not, we need five more bytes for the header.  If so, we
                        # need seven more. 1 == No CRC, 0 == CRC

                        return new strtok.BufferType( if (v[0] & 1) == 1 then 5 else 7 )
                    else
                        @gotFF = false

                else
                    @gotFF = false

            if @frameSize == -1 && !@gotFF
                if v[0] == 0xFF
                    # possible start of frame header. need next byte to know more
                    @gotFF = true
                    return FIRST_BYTE
                else if v[0] == 0x49
                    # could be the I in ID3
                    @gotID3 = 1
                    return FIRST_BYTE

                else if @gotID3 == 1 && v[0] == 0x44
                    @gotID3 = 2
                    return FIRST_BYTE

                else if @gotID3 == 2 && v[0] == 0x33
                    @gotID3 = 3
                    return FIRST_BYTE

                else if @gotID3 == 3
                    @_id3v2_1 = Buffer.from([0x49,0x44,0x33,v[0]])
                    @id3v2 = versionMajor:v[0]
                    @_parsingId3v2 = true
                    @gotID3 = 0
                    return REST_OF_ID3V2_HEADER
                else
                    # keep looking
                    return FIRST_BYTE

            # -- data frame -- #

            if @frameHeaderBuf
                frame = Buffer.alloc( @frameHeaderBuf.length + v.length )
                @frameHeaderBuf.copy(frame,0)
                v.copy(frame,@frameHeaderBuf.length)
                _emitAndMaybeEnd "frame", frame, @frameHeader

            @frameSize = -1

            # what's next depends on whether we've been seeing CRC
            return new strtok.BufferType( if @isCRC then 9 else 7 )

    #----------

    _write: (chunk,encoding,callback) ->
        @istream.emit "data", chunk
        callback?()

    #----------

    parseFrame: (b) ->
        assert.ok Buffer.isBuffer(b)
        assert.ok b.length >=7

        # -- first twelve bits must be FFF -- #

        assert.ok ( b[0] == 0xFF && (b[1] >> 4) == 0xF ), "Buffer does not start with FFF"

        # -- set up our object -- #

        header =
            crc:                !(b[1] & 0x1)
            mpeg_type:          if (b[1] & 0x8) then "MPEG2" else "MPEG4"
            profile:            (b[2] >> 6) + 1
            sample_freq:        SAMPLE_FREQUENCIES[ b[2] >> 2 & 0xF ]
            channel_config:     (b[2] & 1) << 2 | b[3] >> 6
            frame_length:       (b[3] & 0x3) << 11 | b[4] << 3 | b[5] >> 5
            buffer_fullness:    (b[5] & 0x1F) << 6 | b[6] >> 2
            number_of_frames:   (b[6] & 0x3) + 1

            profile_name:       ""
            channels:           0
            frames_per_sec:     0
            duration:           0
            stream_key:         ""

        # -- fill in remaining values -- #

        header.profile_name     = PROFILES[ header.profile ]
        header.channels         = CHANNEL_COUNTS[ header.channel_config ]
        header.frames_per_sec   = header.sample_freq / 1024
        header.duration         = ( 1 / header.frames_per_sec ) * 1000
        header.stream_key       = ['aac',header.sample_freq,header.profile,header.channels].join("-")

        header
