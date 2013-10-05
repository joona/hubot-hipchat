{Adapter, TextMessage, EnterMessage, LeaveMessage, User} = require "../../hubot"
HTTPS = require "https"
{inspect} = require "util"
Connector = require "./connector"
promise = require "./promises"
querystring = require "querystring"
_  = require("underscore")

class HipChat extends Adapter

  constructor: (robot) ->
    super robot
    @logger = robot.logger

    @robot.Response.prototype.html = (strings...) ->
      @robot.adapter.html @envelope, strings...

  topic: (envelope, strings...) ->
    params =
      room_id: @roomIdFromJid(envelope.room)
      topic: strings.join(" / ")
      from: @robot.brain.userForId(@options.jid).name

    @post "rooms/topic", params, (err, data) ->

  html: (envelope, strings...) ->
    params =
      room_id: @roomIdFromJid(envelope.room)
      message: strings.join("")
      from: @robot.brain.userForId(@options.jid).name
      message_format: "html"
      color: "green"

    @post "rooms/message", params, (err, data) ->

  send: (envelope, strings...) ->
    {user, room} = envelope
    reply_to = room or user.jid

    for str in strings
      @connector.message reply_to, str

  reply: (envelope, strings...) ->
    mention = ""
    mention = "@#{envelope.user.mention_name} " if envelope.user
    @send envelope, "#{mention}#{str}" for str in strings

  run: ->
    @options =
      jid:        process.env.HUBOT_HIPCHAT_JID
      password:   process.env.HUBOT_HIPCHAT_PASSWORD
      token:      process.env.HUBOT_HIPCHAT_TOKEN or null
      rooms:      process.env.HUBOT_HIPCHAT_ROOMS or "All"
      host:       process.env.HUBOT_HIPCHAT_HOST or null
      autojoin:   process.env.HUBOT_HIPCHAT_JOIN_ROOMS_ON_INVITE isnt "false"
    @logger.debug "HipChat adapter options: #{JSON.stringify @options}"

    # create Connector object
    connector = new Connector
      jid: @options.jid
      password: @options.password
      host: @options.host
      logger: @logger
    host = if @options.host then @options.host else "hipchat.com"
    @logger.info "Connecting HipChat adapter..."

    init = promise()

    connector.onConnect =>
      @logger.info "Connected to #{host} as @#{connector.mention_name}"

      # Provide our name to Hubot
      @robot.name = connector.mention_name

      # Tell Hubot we're connected so it can load scripts
      @emit "connected"

      # Fetch user info
      connector.getRoster (err, users, stanza) =>
        return init.reject err if err
        init.resolve users

      init
        .done (users) =>
          @users = users

          # Save users to brain
          for user in users
            user.id = user.jid

          @robot.brain.on "loaded", =>
            for user in @users
              @robot.brain.data.users[user.id] = user
            @robot.brain.save

          # Join requested rooms
          if @options.rooms is "All" or @options.rooms is "@All"
            connector.getRooms (err, rooms, stanza) =>
              @rooms = rooms
              if rooms
                for room in rooms
                  @logger.info "Joining #{room.jid}"
                  connector.join room.jid
              else
                @logger.error "Can't list rooms: #{errmsg err}"
          # Join all rooms
          else
            for room_jid in @options.rooms.split ","
              @logger.info "Joining #{room_jid}"
              connector.join room_jid
        .fail (err) =>
          @logger.error "Can't list users: #{errmsg err}" if err

      connector.onMessage (room, from_user_name, message) =>
        # reformat leading @mention name to be like "name: message" which is
        # what hubot expects
        mention_name = connector.mention_name
        regex = new RegExp "^@#{mention_name}\\b", "i"
        message = message.replace regex, "#{mention_name}: "

        user = @robot.brain.userForName(from_user_name) or new User(from_user_name)

        textMessage = new TextMessage user, message
        textMessage.room = room;

        @receive textMessage

      connector.onPrivateMessage (from_user_jid, message) =>
        # remove leading @mention name if present and format the message like
        # "name: message" which is what hubot expects
        mention_name = connector.mention_name
        regex = new RegExp "^@#{mention_name}\\b", "i"
        message = "#{mention_name}: #{message.replace regex, ""}"

        user = @robot.brain.userForId(from_user_jid) or new User(from_user_jid)

        textMessage = new TextMessage user, message
        textMessage.room = null

        @receive textMessage

      changePresence = (PresenceMessage, user_jid, room_jid) =>
        # buffer presence events until the roster fetch completes
        # to ensure user data is properly loaded
        init.done =>
          user = @robot.brain.userForId(user_jid) or new User(user_jid)
          if user
            user.room = room_jid
            @receive new PresenceMessage(user)

      connector.onEnter (user_jid, room_jid) =>
        changePresence EnterMessage, user_jid, room_jid

      connector.onLeave (user_jid, room_jid) ->
        changePresence LeaveMessage, user_jid, room_jid

      connector.onDisconnect =>
        @logger.info "Disconnected from #{host}"

      connector.onError =>
        @logger.error [].slice.call(arguments).map(inspect).join(", ")

      connector.onInvite (room_jid, from_jid, message) =>
        action = if @options.autojoin then "joining" else "ignoring"
        @logger.info "Got invite to #{room_jid} from #{from_jid} - #{action}"
        connector.join room_jid if @options.autojoin

    connector.connect()

    @connector = connector

  roomIdFromJid: (jid) ->
    room = _.find @rooms, (room) ->
      room.jid == jid
    room?.id

  # Convenience HTTP Methods for posting on behalf of the token'd user
  get: (path, callback) ->
    @request "GET", path, null, callback

  post: (path, body, callback) ->
    @request "POST", path, body, callback

  request: (method, path, body, callback) ->
    host = @options.host or "api.hipchat.com"
    headers = "Host": host

    unless @options.token
      return callback "No API token provided to Hubot", null

    path = "/v1/" + path + "?auth_token=#{@options.token}"

    options =
      agent  : false
      host   : host
      port   : 443
      path   : path
      method : method
      headers: headers

    body = querystring.stringify body if !_.isString(body)



    if method is "POST"
      headers["Content-Type"] = "application/x-www-form-urlencoded"
      options.headers["Content-Length"] = body.length

    @logger.debug "Request:", options, body

    request = HTTPS.request options, (response) =>
      data = ""
      response.on "data", (chunk) ->
        data += chunk
      response.on "end", =>
        if response.statusCode >= 400
          @logger.error "HipChat API error: #{response.statusCode}"
        try
          callback null, JSON.parse(data)
        catch err
          callback null, data or { }
      response.on "error", (err) ->
        callback err, null

    if method is "POST"
      request.end(body, "binary")
    else
      request.end()

    request.on "error", (err) =>
      @logger.error err
      @logger.error err.stack if err.stack
      callback err

errmsg = (err) ->
  err + (if err.stack then '\n' + err.stack else '')

exports.use = (robot) ->
  new HipChat robot
