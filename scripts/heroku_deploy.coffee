module.exports = (robot) ->
  robot.error (err, msg) ->
    robot.logger.error "Deployment error!"
    robot.logger.error(err)

  robot.respond /deploy (\w+) to (\w+)/i, (msg) ->
    msg.reply 'Ok, deploying ' + msg.match[1] + ' to ' + msg.match[2]
