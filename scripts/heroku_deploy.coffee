module.exports = (robot) ->
  robot.error (err, msg) ->
    robot.logger.error "Deployment error!"
    robot.logger.error(err)

  robot.respond /deploy ([a-z0-9_\-]+\s)?to (\w+)/i, (msg) ->
    branch = if (msg.match[1] || '').trim().length then msg.match[1].trim() else 'master'
    msg.reply 'Ok, deploying ' + branch + ' to ' + msg.match[2]
