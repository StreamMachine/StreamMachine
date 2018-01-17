_       = require "underscore"
URL     = require "url"
winston = require "winston"
tz      = require "timezone"
nconf   = require "nconf"
elasticsearch = require "elasticsearch"

BatchedQueue    = require "../util/batched_queue"
IdxWriter       = require "./idx_writer"
ESTemplates     = require "./es_templates"

debug = require("debug")("sm:analytics")

# This module is responsible for:

# * Listen for session_start and listen interactions
# * Watch for sessions that are no longer active.  Finalize them, attaching
#   stats and duration, and throwing out sessions that did not meet minimum
#   requirements
# * Answer questions about current number of listeners at any given time
# * Produce old-style w3c output for listener stats

module.exports = class Analytics
    constructor: (@opts,cb) ->
        # get es url
        @_uri = URL.parse @opts.config.es_uri

        # get reference to the log
        @log = @opts.log

        # get session finalize timeout seconds
        @_timeout_sec = Number(@opts.config.finalize_secs)

        # is redis?
        if @opts.redis
            # get redist client reference
            @redis = @opts.redis.client

        # get full es url  and prefix
        es_uri = "http://#{@_uri.hostname}:#{@_uri.port||9200}"
        @idx_prefix = @_uri.pathname.substr(1)

        @log.debug "Connecting to Elasticsearch at #{es_uri} with prefix of #{@idx_prefix}"
        debug "Connecting to ES at #{es_uri}, prefix #{@idx_prefix}"

        # setup api version variable
        apiVersion = '1.7'
        if (typeof @opts.config.es_api_version != 'undefined')
            apiVersion = @opts.config.es_api_version.toString()

        # this.es = new elastic search client
        @es = new elasticsearch.Client
            host:           es_uri
            apiVersion:     apiVersion
            requestTimeout: @opts.config.request_timeout || 30000

        # this.idx_batch = new BatchedQueue
        @idx_batch  = new BatchedQueue
            batch:      @opts.config.index_batch
            latency:    @opts.config.index_latency

        # this.idx_writer = new IdxWriter passing in this.es
        @idx_writer = new IdxWriter @es, @log.child(submodule:"idx_writer")
        @idx_writer.on "error", (err) =>
            @log.error err

        # pipe to the idx writer any batch operations
        @idx_batch.pipe(@idx_writer)

        # track open sessions
        @sessions = {}

        @local = tz(require "timezone/zones")(nconf.get("timezone")||"UTC")

        # -- Load our Templates -- #

        # this.loadTemplates() - loads templates into es, then calls the callback
        @_loadTemplates (err) =>
            if err
                console.error err
                cb? err
            else
                # do something...
                debug "Hitting cb after loading templates"
                cb? null, @

        # -- are there any sessions that should be finalized? -- #

        # when was our last finalized session?
        #last_session = @influx.query "SELECT max(time) from sessions", (err,res) =>
        #    console.log "last session is ", err, res

        # what sessions have we seen since then?

        # -- Redis Session Sweep -- #

        if @redis
            @log.info "Analytics setting up Redis session sweeper"

            setInterval =>
                # look for sessions that should be written (score less than now)
                @redis.zrangebyscore "session-timeouts", 0, Math.floor( Number(new Date) / 1000), (err,sessions) =>
                    return @log.error "Error fetching sessions to finalize: #{err}" if err

                    _sFunc = =>
                        if s = sessions.shift()
                            @_triggerSession s
                            _sFunc()

                    _sFunc()

            , 5*1000

    #----------

    _loadTemplates: (cb) ->
        errors = []

        debug "Loading #{Object.keys(ESTemplates).length} ES templates"

        _loaded = _.after Object.keys(ESTemplates).length, =>
            if errors.length > 0
                debug "Failed to load one or more ES templates: #{errors.join(" | ")}"
                cb new Error "Failed to load index templates: #{ errors.join(" | ") }"
            else
                debug "ES templates loaded successfully."
                cb null

        for t,obj of ESTemplates
            debug "Loading ES mapping for #{@idx_prefix}-#{t}"
            @log.info "Loading Elasticsearch mappings for #{@idx_prefix}-#{t}"
            tmplt = _.extend {}, obj, template:"#{@idx_prefix}-#{t}-*"
            @es.indices.putTemplate name:"#{@idx_prefix}-#{t}-template", body:tmplt, (err) =>
                errors.push err if err
                _loaded()

    #----------

    #----------

    _log: (obj,cb) ->
        session_id = null

        if !obj.client?.session_id
            cb? new Error "Object does not contain a session ID"
            return false

        # write one index per day of data
        index_date = tz(obj.time,"%F")

        time = new Date( obj.time )

        # clean up IPv4 IP addresses stuck in IPv6
        if obj.client?.ip
            obj.client.ip = obj.client.ip.replace /^::ffff:/, ""

        @_indicesForTimeRange "listens", time, (err,idx) =>
            switch obj.type
                when "session_start"
                    @idx_batch.write index:idx[0], type:"start", body:
                        time:       new Date(obj.time)
                        session_id: obj.client.session_id
                        stream:     obj.stream_group || obj.stream
                        client:     obj.client

                    cb? null

                    # -- start tracking the session -- #

                when "listen"
                    # do we know of other duration for this session?
                    @_getStashedDurationFor obj.client.session_id, obj.duration, (err,dur) =>
                        @idx_batch.write index:idx[0], type:"listen", body:
                            session_id:         obj.client.session_id
                            time:               new Date(obj.time)
                            kbytes:             obj.kbytes
                            duration:           obj.duration
                            session_duration:   dur
                            stream:             obj.stream
                            client:             obj.client
                            offsetSeconds:      obj.offsetSeconds
                            contentTime:        obj.contentTime

                        cb? null

            # -- update our timer -- #

            @_updateSessionTimerFor obj.client.session_id, (err) =>

    #----------

    # Given a session id and duration, add the given duration to any
    # existing cached duration and return the accumulated number
    _getStashedDurationFor: (session,duration,cb) ->
        if @redis
            # use redis stash
            key = "duration-#{session}"
            @redis.incrby key, Math.round(duration), (err,res) =>
                cb err, res

            # set a TTL on our key, so that it doesn't stay indefinitely
            @redis.pexpire key, 5*60*1000, (err) =>
                @log.error "Failed to set Redis TTL for #{key}: #{err}" if err

        else
            # use memory stash
            s = @_ensureMemorySession session
            s.duration += duration
            cb null, s.duration

    #----------

    _updateSessionTimerFor: (session,cb) ->
        if @_timeout_sec <= 0
            # timeouts are disabled
            return cb null

        if @redis
            # this will set the score, or update it if the session is
            # already in the set
            timeout_at = (Number(new Date) / 1000) + @_timeout_sec

            @redis.zadd "session-timeouts", timeout_at, session, (err) =>
                cb err

        else
            s = @_ensureMemorySession session

            clearTimeout s.timeout if s.timeout

            s.timeout = setTimeout =>
                @_triggerSession session
            , @_timeout_sec * 1000

            cb null

    #----------

    _scrubSessionFor: (session,cb) ->
        if @redis
            @redis.zrem "session-timeouts", session, (err) =>
                return cb err if err

                @redis.del "duration-#{session}", (err) =>
                    cb err

        else
           s = @_ensureMemorySession session
           clearTimeout s.timeout if s.timeout
           delete @sessions[session]

           cb null


    #----------

    _ensureMemorySession: (session) ->
        @sessions[ session ] ||=
            duration:0, last_seen_at:Number(new Date()), timeout:null

    #----------

    _triggerSession: (session) ->
        @_scrubSessionFor session, (err) =>
            return @log.error "Error cleaning session cache: #{err}" if err

            @_finalizeSession session, (err,obj) =>
                return @log.error "Error assembling session: #{err}" if err

                if obj
                    @_storeSession obj, (err) =>
                        @log.error "Error writing session: #{err}" if err

    #----------

    _finalizeSession: (id,cb) ->
        @log.silly "Finalizing session for #{ id }"

        # This is a little ugly. We need to take several steps:
        # 1) Have we ever finalized this session id?
        # 2) Look up the session_start for the session_id
        # 3) Compute the session's sent kbytes, sent duration, and elapsed duration
        # 4) Write a session object

        session = {}

        # -- Get Started -- #

        @_selectPreviousSession id, (err,ts) =>
            if err
                @log.error err
                return cb? err

            @_selectSessionStart id, (err,start) =>
                if err
                    @log.error err
                    return cb err

                if !start
                    @log.debug "Attempt to finalize invalid session. No start event for #{id}."
                    return cb null, false

                @_selectListenTotals id, ts, (err,totals) =>
                    if err
                        @log.error err
                        return cb? err

                    if !totals
                        # Session did not have any recorded listen events.  Toss it.
                        return cb null, false

                    # -- build session -- #

                    session =
                        session_id: id
                        output:     start.output
                        stream:     start.stream
                        time:       totals.last_listen
                        start_time: ts || start.time
                        client:     start.client
                        kbytes:     totals.kbytes
                        duration:   totals.duration
                        connected:  ( Number(totals.last_listen) - Number(ts||start.time) ) / 1000

                    cb null, session

    #----------

    _storeSession: (session,cb) ->
        # write one index per day of data
        index_date = tz(session.time,"%F")

        @es.index index:"#{@idx_prefix}-sessions-#{index_date}", type:"session", body:session, (err) =>
            cb err

    #----------

    _selectSessionStart: (id,cb) ->
        # -- Look up user information from session_start -- #

        body =
            query:
                constant_score:
                    filter:
                        term:
                            "session_id":id
            sort:
                time:{order:"desc"}
            size:1

        # session start is allowed to be anywhere in the last 72 hours
        # FIXME: Is this reasonable? What do we want to do with long sessions?
        @_indicesForTimeRange "listens", new Date(), "-72 hours", (err,indices) =>
            @es.search type:"start", body:body, index:indices, ignoreUnavailable:true, (err,res) =>
                return cb new Error "Error querying session start for #{id}: #{err}" if err

                if res.hits.hits.length > 0
                    cb null, _.extend {}, res.hits.hits[0]._source, time:new Date(res.hits.hits[0]._source.time)
                else
                    cb null, null

    #----------

    _selectPreviousSession: (id,cb) ->
        # -- Have we ever finalized this session id? -- #

        body =
            query:
                constant_score:
                    filter:
                        term:
                            "session_id":id
            sort:
                time:{order:"desc"}
            size:1


        @_indicesForTimeRange "sessions", new Date(), "-72 hours", (err,indices) =>
            @es.search type:"session", body:body, index:indices, ignoreUnavailable:true, (err,res) =>
                return cb new Error "Error querying for old session #{id}: #{err}" if err

                if res.hits.hits.length == 0
                    cb null, null
                else
                    cb null, new Date(res.hits.hits[0]._source.time)

    #----------

    _selectListenTotals: (id,ts,cb) ->
        # -- Query total duration and kbytes sent -- #

        filter =
            if ts
                "and":
                    filters:[
                        { range:{ time:{ gt:ts } } },
                        { term:{session_id:id} }
                    ]
            else
               term:{session_id:id}

        body =
            query:
                constant_score:
                    filter:filter
            aggs:
                duration:
                    sum:{ field:"duration" }
                kbytes:
                    sum:{ field:"kbytes" }
                last_listen:
                    max:{ field:"time" }

        @_indicesForTimeRange "listens", new Date(), ts||"-72 hours", (err,indices) =>
            @es.search type:"listen", index:indices, body:body, ignoreUnavailable:true, (err,res) =>
                return cb new Error "Error querying listens to finalize session #{id}: #{err}" if err

                if res.hits.total > 0
                    cb null,
                        requests:       res.hits.total
                        duration:       res.aggregations.duration.value
                        kbytes:         res.aggregations.kbytes.value
                        last_listen:    new Date(res.aggregations.last_listen.value)
                else
                    cb null, null

    #----------

    _indicesForTimeRange: (idx,start,end,cb) ->
        if _.isFunction(end)
            cb = end
            end = null

        start = @local(start)

        if _.isString(end) && end[0] == "-"
            end = @local(start,end)

        indices = []
        if end
            end = @local(end)

            s = start
            while true
                s = @local(s,"-1 day")
                break if s < end
                indices.push "#{@idx_prefix}-#{idx}-#{ @local(s,"%F") }"

        indices.unshift "#{@idx_prefix}-#{idx}-#{ @local(start,"%F") }"
        cb null, _.uniq(indices)

    #----------

    countListeners: (cb) ->
        # -- Query recent listeners -- #

        body =
            query:
                constant_score:
                    filter:
                        range:
                            time:
                                gt:"now-15m"
            size:0
            aggs:
                listeners_by_minute:
                    date_histogram:
                        field:      "time"
                        interval:   "minute"
                    aggs:
                        duration:
                            sum:{ field:"duration" }
                        sessions:
                            cardinality:{ field:"session_id" }
                        streams:
                            terms:{ field:"stream", size:5 }

        @_indicesForTimeRange "listens", new Date(), "-15 minutes", (err,indices) =>
            @es.search index:indices, type:"listen", body:body, ignoreUnavailable:true, (err,res) =>
                return cb new Error "Failed to query listeners: #{err}" if err

                times = []

                for obj in res.aggregations.listeners_by_minute.buckets
                    streams = {}
                    for sobj in obj.streams.buckets
                        streams[ sobj.key ] = sobj.doc_count

                    times.unshift
                        time:               @local(new Date(obj.key),"%F %T%^z")
                        requests:           obj.doc_count
                        avg_listeners:      Math.round( obj.duration.value / 60 )
                        sessions:           obj.sessions.value
                        requests_by_stream: streams

                cb null, times

    #----------

    class @LogTransport extends winston.Transport
        name: "analytics"

        constructor: (@a) ->
            super level:"interaction"

        log: (level,msg,meta,cb) ->
            if level == "interaction"
                @a._log meta
                cb?()

    #----------
