strtok = require('strtok2')
assert = require("assert")

module.exports = class MP3 extends require("stream").Writable
    ID3V1_LENGTH = 128
    ID3V2_HEADER_LENGTH = 10
    MPEG_HEADER_LENGTH = 4

    FIRST_BYTE = new strtok.BufferType(1)

    # Mp3 parsing logic borrowed from node-lame: https://github.com/TooTallNate/node-lame

    MPEG_HEADER             = new strtok.BufferType(MPEG_HEADER_LENGTH)
    REST_OF_ID3V2_HEADER    = new strtok.BufferType(ID3V2_HEADER_LENGTH - MPEG_HEADER_LENGTH)
    REST_OF_ID3V1           = new strtok.BufferType(ID3V1_LENGTH - MPEG_HEADER_LENGTH)

    LAYER1_ID              = 3
    LAYER2_ID              = 2
    LAYER3_ID              = 1
    MPEG1_ID               = 3
    MPEG2_ID               = 2
    MPEG25_ID              = 0
    MODE_MONO              = 3
    MODE_DUAL              = 2
    MODE_JOINT             = 1
    MODE_STEREO            = 0

    MPEG_NAME              = [ "MPEG2.5", null, "MPEG2", "MPEG1" ]
    LAYER_NAME             = [ null, "Layer3", "Layer2", "Layer1" ]
    MODE_NAME              = [ "Stereo", "J-Stereo", "Dual", "Mono" ]

    SAMPLING_RATES         = [ 44100, 48000, 32000, 0 ]

    BITRATE_MPEG1_LAYER1   = [ 0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448 ]
    BITRATE_MPEG1_LAYER2   = [ 0, 32, 48, 56, 64,  80, 96,   112, 128, 160, 192, 224, 256, 320, 384 ]
    BITRATE_MPEG1_LAYER3   = [ 0, 32, 40, 48, 56,  64, 80,   96, 112, 128, 160, 192, 224, 256, 320 ]
    BITRATE_MPEG2_LAYER1   = [ 0, 32, 48, 56, 64,  80, 96,   112, 128, 144, 160, 176, 192, 224, 256 ]
    BITRATE_MPEG2_LAYER2A3 = [ 0, 8,  16, 24, 32,  40, 48,   56, 64, 80, 96, 112, 128, 144, 160 ]

    BITRATE_MAP = [
        [ null, BITRATE_MPEG2_LAYER2A3, BITRATE_MPEG2_LAYER2A3, BITRATE_MPEG2_LAYER1 ], # MPEG2.5
        null,
        [ null, BITRATE_MPEG2_LAYER2A3, BITRATE_MPEG2_LAYER2A3, BITRATE_MPEG2_LAYER1 ], # MPEG2
        [ null, BITRATE_MPEG1_LAYER3, BITRATE_MPEG1_LAYER2, BITRATE_MPEG1_LAYER1 ]
    ]

    constructor: ->
        super

        # create an internal stream to pass to strtok
        @istream = new (require("events").EventEmitter)

        @outbuf = []

        @_flushing = false

        # set up status
        @frameSize = -1
        @beginning = true
        @gotFF = false
        @gotID3 = 0
        @byteTwo = null

        @frameHeader    = null
        @frameHeaderBuf = null

        @id3v2 = null
        @_parsingId3v1 = false
        @_parsingId3v2 = false
        @_finishingId3v2 = false
        @_id3v2_1 = null
        @_id3v2_2 = null

        @_id3v1_1 = null

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
                # we need to examine each byte until we get a FF or ID3
                return FIRST_BYTE

            # -- ID3v1 tag -- #

            if @_parsingId3v1
                # our first byte is in @_id3v1_1
                id3 = @parseId3V1(Buffer.concat([@_id3v1_1,v]))
                _emitAndMaybeEnd "id3v1", id3

                @_id3v1_1 = null
                @_parsingId3v1 = false

                return MPEG_HEADER

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
                # buffer should be four bytes
                tag = v.toString 'ascii', 0, 3

                if tag == 'ID3'
                    # parse ID3v2 tag
                    _emitAndMaybeEnd "debug", "got an ID3"
                    @_parsingId3v2 = true
                    @id3v2 = versionMajor:v[3]
                    @_id3v2_1 = v

                    return REST_OF_ID3V2_HEADER

                else if tag == 'TAG'
                    # parse ID3v1 tag
                    _emitAndMaybeEnd "debug", "got a TAG"

                    @_id3v1_1 = v
                    @_parsingId3v1 = true

                    # grab 125 bytes
                    return REST_OF_ID3V1
                else
                    try
                        h = @parseFrame(v)
                    catch e
                        # uh oh...  bad news
                        _emitAndMaybeEnd "debug", "invalid header... ", v, tag, @frameHeader
                        @frameHeader = null
                        return FIRST_BYTE

                    @frameHeader    = h
                    @frameHeaderBuf = v
                    _emitAndMaybeEnd "header", v, h
                    @frameSize = @frameHeader.frameSize

                    if @frameSize == 1
                        # problem...  just start over
                        _emitAndMaybeEnd "debug", "Invalid frame header: ", h
                        return FIRST_BYTE
                    else
                        return new strtok.BufferType(@frameSize - MPEG_HEADER_LENGTH);

            # -- first header -- #

            if @gotFF and @byteTwo
                buf = Buffer.alloc(4)
                buf[0] = 0xFF
                buf[1] = @byteTwo
                buf[2] = v[0]
                buf[3] = v[1]

                try
                    h = @parseFrame(buf)

                catch e
                    # invalid header...  chuck everything and try again
                    _emitAndMaybeEnd "debug", "chucking invalid try at header: ", buf
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

                @frameSize = @frameHeader.frameSize

                if @frameSize == 1
                    # problem...  just start over
                    _emitAndMaybeEnd "debug", "Invalid frame header: ", h

                    return FIRST_BYTE
                else
                    _emitAndMaybeEnd "debug", "On-tracking with frame of: ", @frameSize - MPEG_HEADER_LENGTH
                    return new strtok.BufferType(@frameSize - MPEG_HEADER_LENGTH);

            if @gotFF
                if v[0]>>4 >= 0xE
                    @byteTwo = v[0]

                    # need two more bytes
                    return new strtok.BufferType(2)
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
            return MPEG_HEADER

    #----------

    _write: (chunk,encoding,cb) ->
        if @_flushing
            throw new Error "MP3 write while flushing."

        @istream.emit "data", chunk
        cb?()

    #----------

    parseId3V1: (id3v1) ->
        id3 = {}

        _stripNull = (buf) ->
            idx = buf.toJSON().indexOf(0)
            buf.toString "ascii", 0, if idx == -1 then buf.length else idx

        # TAG: 3 bytes
        # title: 30 bytes
        id3.title = _stripNull id3v1.slice(3,33)

        # artist: 30 bytes
        id3.artist = _stripNull id3v1.slice(33,63)

        # album: 30 bytes
        id3.album = _stripNull id3v1.slice(63,93)

        # year: 4 bytes
        id3.year = _stripNull id3v1.slice(93,97)

        # comment: 28 - 30 bytes

        if id3v1[125] == 0
            id3.comment = _stripNull id3v1.slice(97,125)
            id3.track = id3v1.readUInt8(126)
        else
            id3.track = null
            id3.comment = _stripNull id3v1.slice(97,127)

        # genre: 1 byte
        id3.genre = id3v1.readUInt8(127)

        id3

    #----------

    parseFrame: (b) ->
        assert.ok Buffer.isBuffer(b)

        # -- first twelve bits must be FF[EF] -- #

        assert.ok ( b[0] == 0xFF && (b[1] >> 4) >= 0xE ), "Buffer does not start with FF[EF]"

        header32 = b.readUInt32BE(0)

        # -- mpeg id -- #

        r =
            mpegID:             (header32 >> 19) & 3
            layerID:            (header32 >> 17) & 3
            crc16used:          (header32 & 0x00010000) == 0
            bitrateIndex:       (header32 >> 12) & 0xF
            samplingRateIndex:  (header32 >> 10) & 3

            padding:            (header32 & 0x00000200) != 0
            privateBitSet:      (header32 & 0x00000100) != 0
            mode:               (header32 >> 6) & 3
            modeExtension:      (header32 >> 4) & 3
            copyrighted:        (header32 & 0x00000008) != 0
            original:           (header32 & 0x00000004) == 0
            emphasis:           header32 & 3

            # placeholders for mem allocation
            channels:           0
            bitrateKBPS:        0
            mpegName:           ""
            layerName:          ""
            modeName:           ""
            samplingRateHz:     0
            samplesPerFrame:    0
            bytesPerSlot:       0
            frameSizeRaw:       0
            frameSize:          0
            frames_per_sec:     0
            stream_key:         ""

        # now fill in the derived values...

        r.channels          = if r.mode == MODE_MONO then 1 else 2
        r.bitrateKBPS       = BITRATE_MAP[ r.mpegID ][ r.layerID ][ r.bitrateIndex ]
        r.mpegName          = MPEG_NAME[ r.mpegID ]
        r.layerName         = LAYER_NAME[ r.layerID ]
        r.modeName          = MODE_NAME[ r.mode ]
        r.samplingRateHz    = SAMPLING_RATES[r.samplingRateIndex]

        if r.mpegID == MPEG2_ID
          r.samplingRateHz  >>= 1 # 16,22,48 kHz
        else if r.mpegID == MPEG25_ID
          r.samplingRateHz  >>= 2 # 8,11,24 kHz

        if r.layerID == LAYER1_ID
            # layer 1: always 384 samples/frame and 4byte-slots
            r.samplesPerFrame   = 384;
            r.bytesPerSlot      = 4;
            r.frameSizeRaw      = (12 * (r.bitrateKBPS*1000) / (r.samplingRateHz*10) + (r.padding ? 1 : 0)) * 4;

        else
            # layer 2: always 1152 samples/frame
            # layer 3: MPEG1: 1152 samples/frame, MPEG2/2.5: 576 samples/frame
            r.samplesPerFrame   = if (r.mpegID == MPEG1_ID) || (r.layerID == LAYER2_ID) then 1152 else 576
            r.bytesPerSlot      = 1
            r.frameSizeRaw      = (r.samplesPerFrame / 8) * (r.bitrateKBPS*1000) / r.samplingRateHz + (if r.padding then 1 else 0)

        # Make the frameSize be the proper floor'd byte length
        r.frameSize = ~~r.frameSizeRaw

        if (!r.frameSize)
            throw new Error('bad size: ' + r.frameSize)

        # -- compute StreamMachine-specific header bits -- #

        r.frames_per_sec    = r.samplingRateHz / r.samplesPerFrame
        r.duration          = (1 / r.frames_per_sec) * 1000
        r.stream_key        = ['mp3',r.samplingRateHz,r.bitrateKBPS,(if r.modeName in ["Stereo","J-Stereo"] then "s" else "m")].join("-")

        r
