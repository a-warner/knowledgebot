require('shelljs/global')
Q = require('Q')
Q.longStackSupport = true
os = require('os')

module.exports = (robot) ->
  throw new Error('hubot_deploy requires git') unless which('git')
  throw new Error('hubot_deploy requires egrep') unless which('egrep')

  origin_repo_url = process.env.GIT_REPO_URL
  throw new Error('Need to specify GIT_REPO_URL to use the heroku_deploy script') unless (origin_repo_url || '').trim().length

  Deployer = (->
    logger = robot.logger
    environments = {}
    environments[match[1].toLowerCase()] = value for key, value of process.env when process.env.hasOwnProperty(key) && match = key.match(/([A-Z0-9_-]+)_ENVIRONMENT_DEPLOYMENT_URL/)

    logger.info('heroku_deploy detected environments:')
    logger.info(environments)

    safe_exec = (cmd, error_message) ->
      deferred = Q.defer()

      logger.info 'Running command: ' + cmd
      execution = exec cmd, (status, output) ->
        if status == 0
          deferred.resolve(output)
        else
          message = error_message || "Error running " + cmd + "\n, output is:\n" + output
          deferred.reject(new Error(message))

      execution.stdout.on 'data', (data) -> logger.info(data)
      deferred.promise

    deploy = (branch, environment) ->
      previous_dir = pwd()
      tmp = os.tmpDir()
      logger.info 'tmpDir is ' + tmp
      repo_location = tmp + 'hubot_deploy_repo'

      safe_exec('git clone ' + origin_repo_url + ' ' + repo_location).
        then(->
          cd(repo_location)
          safe_exec('git branch --list --remote | egrep -q "^\\s+origin/' + branch + '$"', 'Branch ' + branch + ' does not exist')
        ).
        then(-> safe_exec('git checkout ' + branch)).
        then(-> safe_exec('git remote add ' + environment + ' ' + environments[environment])).
        then(-> safe_exec('git push ' + environment + ' ' + branch + ':master')).
        catch((error) -> logger.error(error); throw error).
        fin(->
          cd(previous_dir)
          logger.info 'Cleaning up ' + repo_location + '...'
          rm('-rf', repo_location)
          logger.info 'done'
        )


    return {
      environment_names: -> Object.keys(environments),
      environment_exists: (env) -> env of environments,
      deploy: deploy
    }
  )()

  robot.error (err, msg) ->
    robot.logger.error "Deployment error!"
    robot.logger.error(err)

  robot.respond /what (deploy\s)?environments exist\??/i, (msg) ->
    msg.reply 'I can deploy to the following environments: ' + Deployer.environment_names().join(', ')

  robot.respond /deploy ([a-z0-9_\-]+\s)?to (\w+)/i, (msg) ->
    branch = if (msg.match[1] || '').trim().length then msg.match[1].trim() else 'master'
    environment = msg.match[2].toLowerCase()

    return msg.reply('No environment ' + environment) unless Deployer.environment_exists(environment)

    msg.reply 'Ok, deploying ' + branch + ' to ' + environment + '...'

    Deployer.deploy(branch, environment).
      then(-> msg.send('...done! ' + branch + ' has been deployed')).
      catch((error) -> msg.send('Woops! Some kind of error happened, check the logs for more details')).
      done()
