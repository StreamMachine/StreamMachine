PasswordHash = require "password-hash"

module.exports = class Users
    constructor: ->
        @_user_lookup = (user,password,cb) =>
            cb? "Cannot look up users without a valid store loaded."

        @_user_store = (user,password,cb) =>
            cb? "Cannot store users without a valid store loaded."
            
        @_user_list = (cb) =>
            cb? "Cannot list users without a valid store loaded."

    list: (cb) ->
        @_user_list cb
        
    validate: (user,password,cb) ->
        @_user_lookup user, password, cb
        
    store: (user,password,cb) ->
        @_user_store user, password, cb
    
    #-----------
        
    class @Local extends Users
        constructor: (@admin) ->
            super
            
            if @admin.master.redis?
                # we're using redis for users

                @_user_list = (cb) =>
                    @admin.master.redis.once_connected (redis) =>
                        redis.hkeys "users", cb

                @_user_lookup = (user,password,cb) =>
                    @admin.master.redis.once_connected (redis) =>
                        redis.hget "users", user, (err,val) =>
                            if err
                                cb? err
                                return false
                            
                            # see if the hashed passwords match
                            if PasswordHash.verify(password,val)
                                # good to go
                                cb? null, true
                                
                            else
                                cb? null, false
                                
                @_user_store = (user,password,cb) =>
                    @admin.master.redis.once_connected (redis) =>
                        console.log "in user_store for ", user, password
                        if password
                            # store the user
                            hashed = PasswordHash.generate password
                            
                            console.log "hashed pass is ", hashed
                        
                            redis.hset "users", user, hashed, (err,result) =>
                                if err
                                    cb? err
                                    return false
                                
                                cb? null, true
                                
                        else
                            # delete the user
                            redis.hdel "users", user, (err) =>
                                if err
                                    cb? err
                                    return false
                                
                                cb? null, true
                
            else
                # we need to pull users out of the config file
                nconf = require "nconf"
                
                @_user_list = (cb) =>
                    users = nconf.get("users")
                    cb? null, Object.keys(users)
                
                @_user_lookup = (user,password,cb) =>
                    if hash = nconf.get("users:#{user}")
                        cb? null, PasswordHash.verify(password,hash)
                    else
                        cb? "User not found."
            
                @_user_store = (user,password,cb) =>
                    cb? "Cannot store passwords when not using Redis."
            