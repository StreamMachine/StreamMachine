MasterMode      = $src "modes/master"
Master          = $src "master"
MasterStream    = $src "master/stream"
Logger          = $src "logger"
FileSource      = $src "sources/file"
RewindBuffer    = $src "rewind_buffer"

mp3 = $file "mp3/mp3-44100-64-m.mp3"

nconf   = require "nconf"
_       = require "underscore"

STREAM1 =
    key:                "test1"
    source_password:    "abc123"
    root_route:         true
    seconds:            60*60*4
    format:             "mp3"

describe "Master Stream", ->
    logger = new Logger {}


    describe "Startup", ->
        stream = new MasterStream null, "test1", logger, STREAM1

        it "creates a Rewind Buffer", (done) ->
            expect(stream.rewind).to.be.an.instanceof RewindBuffer
            done()

    #----------

    describe "Typical Source Connections", ->
        stream = new MasterStream null, "test1", logger, STREAM1

        source  = new FileSource stream, mp3
        source2 = new FileSource stream, mp3

        it "activates the first source to connect", (done) ->
            expect(stream.source).to.be.null

            stream.addSource source, (err) ->
                throw err if err
                expect(stream.source).to.equal source
                done()

        it "queues the second source to connect", (done) ->
            expect(stream.sources).to.have.length 1

            stream.addSource source2, (err) ->
                throw err if err
                expect(stream.sources).to.have.length 2
                expect(stream.source).to.equal source
                expect(stream.sources[1]).to.equal source2
                done()

        it "promotes an alternative source when requested", (done) ->
            expect(stream.source).to.equal source

            stream.promoteSource source2.uuid, (err) ->
                throw err if err
                expect(stream.source).to.equal source2

                stream.promoteSource source.uuid, (err) ->
                    throw err if err
                    expect(stream.source).to.equal source
                    done()

        it "switches to the second source if the first disconnects", (done) ->
            stream.once "source", (s) ->
                expect(s).to.equal source2
                done()

            source.disconnect()

    describe "Source Connection Scenarios", ->
        mp3a = $file "mp3/tone250Hz-44100-128-m.mp3"
        mp3b = $file "mp3/tone440Hz-44100-128-m.mp3"
        mp3c = $file "mp3/tone1kHz-44100-128-m.mp3"

        stream  = null
        source1 = null
        source2 = null
        source3 = null
        uuids   = {}

        beforeEach (done) ->
            stream = new MasterStream null, "test1", logger, STREAM1
            source1 = new FileSource stream, mp3a
            source2 = new FileSource stream, mp3b
            source3 = new FileSource stream, mp3c

            uuids[source1.uuid] = "source1"
            uuids[source2.uuid] = "source2"
            uuids[source3.uuid] = "source3"

            done()

        afterEach (done) ->
            stream.removeAllListeners()
            source1.removeAllListeners()
            source2.removeAllListeners()
            source3.removeAllListeners()
            done()

        #----------

        it "doesn't get confused by simultaneous addSource calls", (done) ->
            this.timeout 6000

            stream.once "source", ->
                # listen for five data emits.  they should all come from
                # the same source uuid
                emits = []

                af = _.after 5, ->
                    # expect all data emits to be from the same source
                    expect(_(emits).uniq()).to.have.length 1

                    # expect that they came from source1
                    expect(emits[0]).to.equal "source1"

                    # expect that the stream lists source1 as its source
                    expect(stream.source).to.equal source1

                    done()

                stream.on "data", (data) ->
                    emits.push uuids[data.uuid]
                    af()

            stream.addSource source1
            stream.addSource source2

        #----------

        it "doesn't get confused by quick promoteSource calls", (done) ->
            this.timeout 6000

            stream.addSource source1, ->
                stream.addSource source2, ->
                    stream.addSource source3, ->
                        # listen for five data emits.  they should all come from
                        # the same source uuid
                        emits = []

                        af = _.after 5, ->
                            # expect all data emits to be from the same source
                            expect(_(emits).uniq()).to.have.length 1

                            # expect that source to be the same one listed
                            expect(emits[0]).to.equal stream.source.uuid

                            done()

                        stream.on "data", (data) ->
                            emits.push data.uuid
                            af()

                        stream.promoteSource source2.uuid
                        stream.promoteSource source3.uuid

        #----------

        it "falls back if a source disconnects during promotion", (done) ->
            this.timeout 5000

            stream.addSource source1, ->
                stream.addSource source2, ->
                    source2.once "connect", ->
                        stream.promoteSource source2.uuid
                        source2.disconnect()

                        # listen for five data emits.  they should all come from
                        # the same source uuid
                        emits = []

                        af = _.after 5, ->
                            expect(_(emits).uniq()).to.length 1
                            expect(emits[0]).to.equal "source1"
                            done()

                        stream.on "data", (data) ->
                            emits.push uuids[data.uuid]
                            af()

        #----------

        it "handles a source disconnecting as a source is promoted", (done) ->
            this.timeout 5000

            source1.once "connect", ->
                stream.addSource source1, ->
                    stream.addSource source2, ->
                        stream.addSource source3, ->
                            # ask for source3 to be promoted
                            stream.promoteSource source3.uuid

                            # but simultaneously let source1 disconnect
                            source1.disconnect()

                            emits = []
                            af = _.after 5, ->
                                expect(_(emits).uniq()).to.length 1
                                expect(emits[0]).to.equal "source3"
                                done()

                            stream.on "data", (data) ->
                                emits.push uuids[data.uuid]
                                af()
