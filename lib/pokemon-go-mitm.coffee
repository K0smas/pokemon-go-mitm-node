###
  Pokemon Go (c) MITM node proxy
  by Michael Strassburger <codepoet@cpan.org>
###

Proxy = require 'http-mitm-proxy'
POGOProtos = require 'pokemongo-protobuf'
changeCase = require 'change-case'
fs = require 'fs'
_ = require 'lodash'

class PokemonGoMITM
  responseEnvelope: 'POGOProtos.Networking.Envelopes.ResponseEnvelope'
  requestEnvelope: 'POGOProtos.Networking.Envelopes.RequestEnvelope'

  requestHandlers: {}
  responseHandlers: {}
  requestEnvelopeHandlers: []
  responseEnvelopeHandlers: []

  requestInjectQueue: []

  constructor: (options) ->
    @port = options.port or 8081
    @debug = options.debug or false
    @setupProxy()

  setupProxy: ->
    proxy = Proxy()
    proxy.use Proxy.gunzip
    proxy.onRequest @handleProxyRequest
    proxy.onError @handleProxyError
    proxy.listen port: @port
    console.log "[+++] PokemonGo MITM Proxy listening on #{@port}"
    console.log "[!] Make sure to have the CA cert .http-mitm-proxy/certs/ca.pem installed on your device"

  handleProxyRequest: (ctx, callback) =>
    # don't interfer with anything not going to the Pokemon API
    return callback() unless ctx.clientToProxyRequest.headers.host is "pgorelease.nianticlabs.com"

    @log "[+++] Request to #{ctx.clientToProxyRequest.url}"

    ### Client Reuqest Handling ###
    requested = [] 
    ctx.onRequestData (ctx, buffer, callback) =>
      try
        data = POGOProtos.parse buffer, @requestEnvelope
      catch e
          @log "[-] Parsing protobuf of RequestEnvelope failed.."
          ctx.proxyToServerRequest.write buffer
          return callback null, buffer

      originalData = _.cloneDeep data

      for handler in @requestEnvelopeHandlers
        data = handler(data, url: ctx.clientToProxyRequest.url) or data

      for id,request of data.requests
        protoId = changeCase.pascalCase request.request_type
      
        # Queue the ProtoId for the response handling
        requested.push "POGOProtos.Networking.Responses.#{protoId}Response"
        
        proto = "POGOProtos.Networking.Requests.Messages.#{protoId}Message"
        unless proto in POGOProtos.info()
          @log "[-] Request handler for #{protoId} isn't implemented yet.."
          continue

        try
          decoded = if request.request_message
            POGOProtos.parse request.request_message, proto
          else {}
        catch e
          @log "[-] Parsing protobuf of #{protoId} failed.."
          continue
        
        # TODO
        if overwrite = @handleRequest protoId, decoded
          unless _.isEqual overwrite, decoded
            @log "[!] Overwriting "+protoId
            request.request_message = POGOProtos.serialize overwrite, proto

      # TODO
      # for request in @requestInjectQueue
      #   @log "[+] Injecting request to #{request.action}"

      #   requested.push "POGOProtos.Networking.Responses.#{request.action}Response"
      #   data.requests.push
      #     request_type: changeCase.constantCase request.action
      #     request_message: POGOProtos.serialize request.data, "POGOProtos.Networking.Requests.Messages.#{request.action}Message"

      # @requestInjectQueue = []

      unless _.isEqual originalData, data
        @log "[+] Recoding RequestEnvelope"
        @log data
        buffer = POGOProtos.serialize data, @requestEnvelope
        @log POGOProtos.parse buffer, @requestEnvelope

      @log "[+] Waiting for response..."
      
      callback null, buffer

    ### Server Response Handling ###
    responseChunks = []
    ctx.onResponseData (ctx, chunk, callback) =>
      responseChunks.push chunk
      callback()

    ctx.onResponseEnd (ctx, callback) =>
      buffer = Buffer.concat responseChunks
      try
        data = POGOProtos.parse buffer, @responseEnvelope
      catch e
          @log "[-] Parsing protobuf of ResponseEnvelope failed: #{e}"
          ctx.proxyToClientResponse.end buffer
          return callback()

      originalData = _.cloneDeep data

      for handler in @responseEnvelopeHandlers
        data = handler(data, {}) or data

      for id,response of data.returns
        proto = requested[id]
        if proto in POGOProtos.info()
          decoded = POGOProtos.parse response, proto
          
          protoId = proto.split(/\./).pop().split(/Response/)[0]

          if overwrite = @handleResponse protoId, decoded
            unless _.isEqual overwrite, decoded
              @log "[!] Overwriting "+protoId
              data.returns[id] = POGOProtos.serialize overwrite, proto

        else
          @log "[-] Response handler for #{requested[id]} isn't implemented yet.."

      # Overwrite the response in case a hook hit the fan
      unless _.isEqual originalData, data
        buffer = POGOProtos.serialize data, @responseEnvelope

      ctx.proxyToClientResponse.end buffer
      callback false

    callback()

  handleProxyError: (ctx, err, errorKind) =>
    url = if ctx and ctx.clientToProxyRequest then ctx.clientToProxyRequest.url else ''
    @log '[-] ' + errorKind + ' on ' + url + ':', err

  handleRequest: (action, data) ->
    @log "[+] Request for action #{action}: "
    @log data if data

    handlers = [].concat @requestHandlers[action] or [], @requestHandlers['*'] or []
    for handler in handlers
      data = handler(data, action) or data

      return data

    false

  handleResponse: (action, data) ->
    @log "[+] Response for action #{action}"
    @log data if data

    handlers = [].concat @responseHandlers[action] or [], @responseHandlers['*'] or []
    for handler in handlers
      data = handler(data, action) or data

      return data

    false

  injectRequest: (action, data) ->
    unless "POGOProtos.Networking.Requests.Messages.#{action}Message" in POGOProtos.info()
      @log "[-] Can't inject request #{action} - proto not implemented"
      return

    @requestInjectQueue.push
      action: action
      data: data

  setResponseHandler: (action, cb) ->
    @addResponseHandler action, cb
    this

  addResponseHandler: (action, cb) ->
    @responseHandlers[action] ?= []
    @responseHandlers[action].push(cb)
    this

  setRequestHandler: (action, cb) ->
    @addRequestHandler action, cb
    this

  addRequestHandler: (action, cb) ->
    @requestHandlers[action] ?= []
    @requestHandlers[action].push(cb)
    this

  addRequestEnvelopeHandler: (cb, name=undefined) ->
    @requestEnvelopeHandlers.push cb
    this

  addResponseEnvelopeHandler: (cb, name=undefined) ->
    @responseEnvelopeHandlers.push cb
    this

  log: (text) ->
    console.log text if @debug

module.exports = PokemonGoMITM
