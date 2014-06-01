module.exports = (robot) ->
  origin_repo_url = process.env.GIT_REPO_URL
  throw new Error('Need to specify GIT_REPO_URL to use the heroku_deploy script') unless (origin_repo_url || '').trim().length

  environments = {}
  environments[match[1].toLowerCase()] = value for key, value of process.env when process.env.hasOwnProperty(key) && match = key.match(/([A-Z0-9_-]+)_ENVIRONMENT_DEPLOYMENT_URL/)

  robot.logger.info('heroku_deploy detected environments:')
  robot.logger.info(environments)

  robot.error (err, msg) ->
    robot.logger.error "Deployment error!"
    robot.logger.error(err)

  robot.respond /what deploy environments exist\??/i, (msg) ->
    msg.reply 'I can deploy to the following environments: ' + Object.keys(environments).join(', ')

  robot.respond /deploy ([a-z0-9_\-]+\s)?to (\w+)/i, (msg) ->
    branch = if (msg.match[1] || '').trim().length then msg.match[1].trim() else 'master'
    environment = msg.match[2].toLowerCase()

    return msg.reply('No environment ' + environment) unless (environment of environments)

    msg.reply 'Ok, deploying ' + branch + ' to ' + environment
