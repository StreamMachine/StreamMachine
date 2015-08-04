Prometheus  = require "prometheus-client"
express     = require "express"

module.exports = class PrometheusMaster
    constructor: (@master) ->
        @client = new Prometheus()

        # -- Register our Metrics -- #

        @connected_sources = @client.newGauge
            namespace:  "streammachine",
            subsystem:  "master"
            name:       "stream_sources"
            help:       "Number of sources connected for this stream."

        @source_latency = @client.newGauge
            namespace:  "streammachine",
            subsystem:  "master"
            name:       "stream_source_latency"
            help:       "How many milliseconds is the source chunk ts behind our clock time?"

        @connected_slaves = @client.newGauge
            namespace:  "streammachine",
            subsystem:  "master"
            name:       "slaves"
            help:       "Number of slaves that are connected."

        # -- Set our source loop -- #

        @_sourceInt = setInterval =>
            _process = (stream,idx,source) =>
                latency =
                    if source.last_ts
                        Number(new Date()) - Number(source.last_ts)
                    else
                        -1

                @source_latency.set stream:stream, index:idx, latency

            for k,stream of @master.streams
                _process(stream.key,idx,source) for source,idx in stream.sources
                @connected_sources.set stream:stream.key, stream.sources.length

            for k,sg of @master.stream_groups
                _process(sg._stream.key,idx,source) for source,idx in sg._stream.sources
                @connected_sources.set stream:sg._stream.key, sg._stream.sources.length

        , 1000

        @_slaveInt = setInterval =>
            @connected_slaves.set {}, Object.keys(@master.slaves?.slaves||{}).length
        , 1000

        # -- Attach metrics to the API -- #

        @app = express()
        @app.get "/", @client.metricsFunc()
