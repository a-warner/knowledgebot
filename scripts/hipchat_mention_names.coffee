Hubot = require('hubot')

oldUserForName = Hubot.Brain.prototype.userForName

Hubot.Brain.prototype.userForName = (name) ->
  if oldNameLookupResult = oldUserForName.call(this, name)
    return oldNameLookupResult

  result = null
  lowerName = name.toLowerCase()
  for k of (@data.users or { })
    userName = @data.users[k]['mention_name']
    if userName? and userName.toLowerCase() is lowerName
      result = @data.users[k]
  result

module.exports = ->
