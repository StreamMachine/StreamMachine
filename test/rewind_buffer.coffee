RewindBuffer    = $src "rewind_buffer"
FileSource      = $src "sources/file"
Logger          = $src "logger"

mp3_a = $file "mp3/mp3-44100-64-s.mp3"
mp3_b = $file "mp3/mp3-44100-128-s.mp3"

#----------

class MockRewinder
    constructor: ->
        @buffer = []

    _insert: (chunk) ->
        @buffer.push chunk

#----------

describe "Rewind Buffer", ->
    rewind      = null
    source_a    = null
    source_b    = null

    logger = new Logger {}

    before (done) ->
        rewind = new RewindBuffer seconds:60, burst:30
        rewind.log = logger

        done()

    before (done) ->
        source_a = new FileSource format:"mp3", filePath:mp3_a, do_not_emit:true
        source_b = new FileSource format:"mp3", filePath:mp3_b, do_not_emit:true
        done()

    it "starts with a bufferedSecs of NaN", (done) ->
        expect( rewind.bufferedSecs() ).to.eql NaN
        done()

    describe "on source...", ->
        it "accepts a source", (done) ->
            rewind._rConnectSource source_a, ->
                expect(rewind._rsource).to.eql source_a
                done()

        it "reads emit duration", (done) ->
            expect(rewind._rsecsPerChunk).to.eql source_a.emitDuration
            done()

        it "sets streamKey", (done) ->
            expect(rewind._rstreamKey).to.eql source_a.streamKey
            done()

    describe "on data...", ->
        events = rshift:0, rpush:0
        before (done) ->
            rewind.on "rshift", (b) -> events.rshift += 1
            rewind.on "rpush", (b) -> events.rpush += 1

            # now emit one chunk...
            source_a._emitOnce()

            done()

        it "pushes one data chunk", (done) ->
            expect(events.rpush).to.eql 1
            done()

        it "gives the right buffered duration", (done) ->
            # the value is allowed to be rounded
            expect( rewind.bufferedSecs() ).to.be.within Math.floor(source_a.emitDuration), Math.ceil(source_a.emitDuration)
            done()

    describe "more data...", ->
        events = rshift:0, runshift:0, rpush:0
        before (done) ->
            rewind._rbuffer.reset()

            rewind.on "rshift",     (b) -> events.rshift += 1
            rewind.on "runshift",   (b) -> events.runshift += 1
            rewind.on "rpush",      (b) -> events.rpush += 1

            done()

        ts = Number(new Date)
        before (done) ->
            # push two minutes of data (60 samples)
            for i in [0..59]
                c_ts = new Date(ts+source_a.emitDuration*1000*i)
                source_a._emitOnce(c_ts)

            done()

        it "pushed 60 data chunks", (done) ->
            expect(events.rpush).to.eql 60
            expect(events.runshift).to.eql 0
            done()

        it "shifted off 30 data chunks", (done) ->
            expect(events.rshift).to.eql 30
            done()

        it "still knows buffered duration", (done) ->
            # the value is allowed to be rounded
            expect( rewind.bufferedSecs() ).to.be.within rewind._rsecs, rewind._rsecs + 1
            done()

        it "can find a timestamp inside the buffer", (done) ->
            # we've pushed 60 samples, but 30 have been shifted off,
            # so we'll look for one minute after the first push time
            f_ts = new Date(ts + 1*60*1000)
            rewind.timestampToOffset f_ts, (err,offset) ->
                expect(err).to.be.null
                # should be the "last" timestamp in the buffer... first on the array
                expect(offset).to.eql 29
                done()

        #it "errors if a timestamp isn't in the buffer", (done) ->
        #    f_ts = new Date(ts+2*60*1000)
        #    rewind.timestampToOffset f_ts, (err,offset) ->
        #        expect(err).to.be.instanceof Error
        #        done()

        it "can return data via pumpSeconds", (done) ->
            mock = new MockRewinder

            rewind.pumpSeconds mock, 8, false, (err,meta) ->
                throw err if err
                expect(meta.duration).to.be.within 7900, 8100
                expect(mock.buffer).to.have.length 4

                t_len = 0
                t_len += b.data.length for b in mock.buffer
                # 64Kb/sec audio, so 8 sec should be ~64KB. Unit for length is bytes
                expect(t_len).to.be.within 63000, 65000

                done()

        it "can return data via pumpSeconds (concat)", (done) ->
            mock = new MockRewinder

            rewind.pumpSeconds mock, 2, true, (err,meta) ->
                throw err if err
                expect(meta.duration).to.be.within 1900, 2100

                # buffer here is concatenated
                expect(mock.buffer).to.have.length 1

                # 64Kb/sec audio, so 2 sec should be ~16KB. Unit for length is bytes
                expect(mock.buffer[0].data.length).to.be.within 15000, 17000

                done()

        # we'll use this in the next two tests
        rewind_buf = Buffer.alloc 0

        it "can dump its rewind buffer", (done) ->
            pt = new require("stream").PassThrough()

            pt.on "readable", ->
                while b = pt.read()
                    if rewind_buf
                        rewind_buf = Buffer.concat [rewind_buf, b]
                    else
                        rewind_buf = b

            rewind.dumpBuffer (err,writer) ->
                writer.pipe(pt)
                true

            pt.on "end", ->
                done()

        it "can restore a dumped rewind buffer", (done) ->
            n_rewind = new RewindBuffer seconds:60, burst:30
            n_rewind.log = logger

            pt = new require("stream").PassThrough()

            n_rewind.loadBuffer pt, (err,obj) ->
                throw err if err

                expect(obj.seconds).to.equal rewind.bufferedSecs()
                expect(obj.length).to.equal rewind._rbuffer.length()

                done()

            pos     = 0
            chunk   = 16384

            while pos < rewind_buf.length
                b = rewind_buf.slice(pos,pos+chunk)
                pt.write b
                pos += chunk

            pt.end()
