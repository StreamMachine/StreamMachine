MasterIO    = $src "master/master_io"
SlaveIO     = $src "slave/slave_io"
Logger      = $src "logger"

_       = require "underscore"
http    = require "http"

debug = require("debug")("sm:tests:master_slave_io")

log = new Logger stdout:false

class FakeMaster extends require("events").EventEmitter
    constructor: ->

    config: ->
        streams:"ABC123"

    vitals: (key,cb) ->
        cb?(null,key)
        key

class FakeSlave extends require("events").EventEmitter
    constructor: ->

    configureStreams: (streams) ->
        @emit "streams", streams

    _streamStatus: (cb) ->
        r = "YAY"
        cb?(null,r)
        r

describe "Master/Slave IO", ->
    m_server    = null
    m_port      = null

    before (done) ->
        # create our server and listen on a random port
        m_server = http.createServer()
        m_server.listen 0, ->
            m_port = m_server.address().port
            done()

    fm = new FakeMaster
    fs = new FakeSlave

    master      = null
    slave       = null

    describe "Master Startup", ->
        it "creates an IO object", (done) ->
            master = new MasterIO fm, log.child(component:"master"), password:"testing"
            done()

        it "accepts a server to listen on", (done) ->
            master.listen(m_server)
            done()

    describe "Slave Startup", ->
        it "creates an IO object and connects", (done) ->
            slave = new SlaveIO fs, log.child(component:"slave"), master:"ws://localhost:#{m_port}?password=testing"

            err_f = (err) -> throw err

            slave.once "error", err_f

            slave.once_connected (err,io) ->
                throw err if err
                slave.removeListener "error", err_f

                expect(io.connected).to.be.true
                expect(slave.connected).to.be.true

                done()

        it "registers the slave in master", (done) ->
            m_keys = Object.keys(master.slaves)

            expect(m_keys).to.have.length 1
            expect(m_keys[0]).to.eql slave.id

            done()

    describe "RPC", ->
        it "passes a config broadcast to the Slave as streams", (done) ->
            fs.once "streams", (streams) ->
                expect(streams).to.eql fm.config().streams
                done()

            fm.emit "config_update"

        it "can roundtrip a slave status request", (done) ->
            master.slaves[ slave.id ].status (err,status) ->
                throw err if err
                expect(status).to.eql fs._streamStatus()
                done()

        it "can roundtrip a vitals request from slave to master", (done) ->
            k = "MYKEY"
            slave.vitals k, (err,v) ->
                throw err if err
                expect(v).to.eql k
                done()

        it "broadcasts audio data from master to slave", (done) ->
            k = "AUDIO"
            chunk = { ts:new Date(), duration:0.1, data:Buffer.alloc(100)}

            slave.on "audio:#{k}", (rchunk) ->
                expect(rchunk.ts).to.eql chunk.ts
                expect(rchunk.data).to.be.instanceof Buffer
                debug "Audio chunk arrived as #{rchunk.data.length}.", rchunk.data
                expect(rchunk.data.length).to.be.eql chunk.data.length
                done()

            debug "Broadcasting audio chunk of #{chunk.data.length}.", chunk
            master.broadcastAudio k, chunk

    describe "Disconnects", ->
        it "can notice on master when a slave disconnects", (done) ->
            master.once "disconnect", (id) ->
                expect(Object.keys(master.slaves)).to.have.length 0
                expect(id).to.eql slave.id
                done()

            slave.disconnect()
