require('shelljs/global')
Q = require('q')
Q.longStackSupport = true
os = require('os')
fs = require('fs')
path = require('path')

module.exports = (robot) ->
  throw new Error('hubot_deploy requires git') unless which('git')
  throw new Error('hubot_deploy requires egrep') unless which('egrep')

  origin_repo_url = process.env.GIT_REPO_URL
  throw new Error('Need to specify GIT_REPO_URL to use the heroku_deploy script') unless (origin_repo_url || '').trim().length

  throw new Error('I need my own private key! Please set the PRIVATE_KEY env var') unless (process.env.PRIVATE_KEY || '').trim().length
  private_key = new Buffer(process.env.PRIVATE_KEY, 'base64')

  throw new Error('I need a github host to trust, please set GITHUB_TRUSTED_HOST') unless (process.env.GITHUB_TRUSTED_HOST || '').trim().length
  github_trusted_host = new Buffer(process.env.GITHUB_TRUSTED_HOST, 'base64')

  class HubotError extends Error
    constructor: (msg) ->
      super(msg)
      @hubot_error = msg

  Deployer = (->
    logger = robot.logger
    environments = {}
    environments[match[1].toLowerCase()] = value for key, value of process.env when process.env.hasOwnProperty(key) && match = key.match(/([A-Z0-9_-]+)_ENVIRONMENT_DEPLOYMENT_URL/)

    logger.info('heroku_deploy detected environments:')
    logger.info(environments)

    tmp = os.tmpDir()
    logger.info 'tmpDir is ' + tmp
    repo_location = path.join(tmp, 'hubot_deploy_repo')
    private_key_location = path.join(tmp, 'hubot_private_key')

    trust_github = ->
      safe_exec('mkdir -p $HOME/.ssh && touch $HOME/.ssh/known_hosts').
        then(-> safe_exec('grep -q ' + github_trusted_host + ' $HOME/.ssh/known_hosts || echo "' + github_trusted_host + '" >> $HOME/.ssh/known_hosts'))

    deploy_exec = (input_cmd, error_message) ->
      cmd = "ssh-agent bash -c 'ssh-add " + private_key_location + "; " + input_cmd + "'"
      Q.nfcall(fs.writeFile, private_key_location, private_key).
        then(-> Q.nfcall(fs.chmod, private_key_location, '600')).
        then(-> safe_exec cmd, error_message)

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

      trust_github().
        then(-> deploy_exec('git clone ' + origin_repo_url + ' ' + repo_location)).
        then(->
          cd(repo_location)
          deploy_exec('git branch -a')
        ).
        then( (branches) -> throw new HubotError("Branch " + branch + " does not exist") unless branches.match(new RegExp("^\\s+remotes\/origin\/" + branch + "$", 'm'))).
        then(-> deploy_exec('git checkout ' + branch)).
        then(-> deploy_exec('git remote add ' + environment + ' ' + environments[environment])).
        then(-> deploy_exec('git push ' + environment + ' ' + branch + ':master')).
        catch((error) -> logger.error(error); throw error).
        fin(->
          cd(previous_dir)
          logger.info 'Cleaning up ' + repo_location + '...'
          rm('-rf', repo_location)
          rm(private_key_location)
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
      catch((error) -> msg.send(error.hubot_error || 'Woops! Some kind of error happened, check the logs for more details')).
      done()
