# Based on https://github.com/Skomski/node-pagerduty
request = require 'request'

class PagerDuty
  module.exports = PagerDuty

  constructor: ({@serviceKey}) ->
    return

  create: ({description, incidentKey, details, callback}) ->
    @_request arguments[0] extends eventType: 'trigger'

  acknowledge: ({incidentKey, details, description, callback}) ->
    @_request arguments[0] extends eventType: 'acknowledge'

  resolve: ({incidentKey, details, description, callback}) ->
    @_request arguments[0] extends eventType: 'resolve'

  _request: ({description, incidentKey, eventType, details, callback}) ->
    incidentKey ||= null
    details     ||= {}
    callback    ||= ->

    json =
      service_key: @serviceKey
      event_type: eventType
      description: description
      details: details

    json.incident_key = incidentKey

    request
      method: 'POST'
      uri: 'https://events.pagerduty.com/generic/2010-04-15/create_event.json'
      json: json
    , (err, response, body) ->
      if err or response.statusCode != 200
        callback err || new Error(body.errors[0])
      else
        callback null, body
