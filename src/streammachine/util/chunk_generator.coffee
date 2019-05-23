_ = require "underscore"

debug = require("debug")("sm:util:chunk_generator")

# Generate fake audio chunks for testing

module.exports = class ChunkGenerator extends require("stream").Readable
    constructor: (@start_ts,@chunk_duration) ->
        @_count_f   = 0
        @_count_b   = 1

        super objectMode:true

    skip_forward: (count,cb) ->
        @_count_f += count
        cb?()

    skip_backward: (count,cb) ->
        @_count_b += count
        cb?()

    ts: ->
        forward:    new Date( Number(@start_ts) + (@_count_f) * @chunk_duration )
        backward:   new Date( Number(@start_ts) + (@_count_b) * @chunk_duration )

    forward: (count,cb) ->
        af = _.after count, =>
            @_count_f += count
            @emit "readable"
            debug "Forward emit #{count} chunks. Finished at #{ new Date( Number(@start_ts) + (@_count_f) * @chunk_duration ) }"
            cb?()

        _(count).times (c) =>
            chunk =
                ts:         new Date( Number(@start_ts) + (@_count_f+c) * @chunk_duration )
                duration:   @chunk_duration
                data:       Buffer.alloc(0)

            @push chunk
            af()

    backward: (count,cb) ->
        af = _.after count, =>
            @_count_b += count
            @emit "readable"
            debug "Backward emit #{count} chunks. Finished at #{ new Date( Number(@start_ts) + (@_count_b) * @chunk_duration ) }"
            cb?()

        _(count).times (c) =>
            chunk =
                ts:         new Date( Number(@start_ts) - (@_count_b+c) * @chunk_duration )
                duration:   @chunk_duration
                data:       Buffer.alloc(0)

            @push chunk
            af()

    end: ->
        @push null

    _read: (size) ->
        # do nothing?
