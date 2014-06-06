require('shelljs/global')
Q = require('q')
Q.longStackSupport = true
os = require('os')
fs = require('fs')
path = require('path')

class Config
  constructor: (logger) ->
    throw new Error('hubot_deploy requires git') unless which('git')
    throw new Error('hubot_deploy requires egrep') unless which('egrep')

    @origin_repo_url = process.env.GIT_REPO_URL
    throw new Error('Need to specify GIT_REPO_URL to use the heroku_deploy script') unless (@origin_repo_url || '').trim().length

    throw new Error('I need my own private key! Please set the PRIVATE_KEY env var') unless (process.env.PRIVATE_KEY || '').trim().length
    @private_key = new Buffer(process.env.PRIVATE_KEY, 'base64')

    throw new Error('I need a github host to trust, please set GITHUB_TRUSTED_HOST') unless (process.env.GITHUB_TRUSTED_HOST || '').trim().length
    @github_trusted_host = new Buffer(process.env.GITHUB_TRUSTED_HOST, 'base64')

    throw new Error('I need a heroku host to trust, please set HEROKU_TRUSTED_HOST') unless (process.env.HEROKU_TRUSTED_HOST || '').trim().length
    @heroku_trusted_host = new Buffer(process.env.HEROKU_TRUSTED_HOST, 'base64')

    @environments = {}
    @environments[match[1].toLowerCase()] = value for key, value of process.env when process.env.hasOwnProperty(key) && match = key.match(/([A-Z0-9_-]+)_ENVIRONMENT_DEPLOYMENT_URL/)

    logger.info('heroku_deploy detected environments:')
    logger.info(@environments)

class HubotError extends Error
  constructor: (msg) ->
    super(msg)
    @hubot_error = msg

class Deployer
  constructor: (logger, config) ->
    @logger = logger
    @config = config
    @deployment_lock = false

    tmp = os.tmpDir()
    @logger.info 'tmpDir is ' + tmp

    @repo_location = path.join(tmp, 'hubot_deploy_repo')
    @private_key_location = path.join(tmp, 'hubot_private_key')

  trust: (host) ->
    that = this
    @safe_exec('mkdir -p $HOME/.ssh && touch $HOME/.ssh/known_hosts').
      then(-> that.safe_exec('grep -q \"' + host + '\" $HOME/.ssh/known_hosts || echo "' + host + '" >> $HOME/.ssh/known_hosts'))

  deploy_exec: (input_cmd, error_message) ->
    that = this
    cmd = "ssh-agent bash -c 'ssh-add " + @private_key_location + "; " + input_cmd + "'"
    Q.nfcall(fs.writeFile, @private_key_location, @config.private_key).
      then(-> Q.nfcall(fs.chmod, that.private_key_location, '600')).
      then(-> that.safe_exec cmd, error_message)

  safe_exec: (cmd, error_message) ->
    deferred = Q.defer()
    that = this

    @logger.info 'Running command: ' + cmd
    execution = exec cmd, (status, output) ->
      if status == 0
        deferred.resolve(output)
      else
        message = error_message || "Error running " + cmd + "\n, output is:\n" + output
        deferred.reject(new Error(message))

    execution.stdout.on 'data', (data) -> that.logger.info(data)
    execution.stderr.on 'data', (data) -> that.logger.info(data) if (data || '').trim.length
    deferred.promise

  error: (error) ->
    deferred = Q.defer()
    deferred.reject(error)
    deferred.promise

  deploying: -> @deployment_lock

  deploy: (branch, environment, clobber) ->
    previous_dir = pwd()
    that = this

    return @error(new Error("Currently deploying")) if @deploying()
    @deployment_lock = true

    deployment_branch_name = 'hubot_deploy_' + branch + '_to_' + environment

    @trust(@config.github_trusted_host).
      then(-> that.trust(that.config.heroku_trusted_host)).
      then(-> that.deploy_exec('git clone ' + that.config.origin_repo_url + ' ' + that.repo_location)).
      then(->
        cd(that.repo_location)
        that.deploy_exec('git branch -a')
      ).
      then( (branches) -> throw new HubotError("Branch " + branch + " does not exist") unless branches.match(new RegExp("^\\s+remotes\/origin\/" + branch + "$", 'm'))).
      then(-> that.deploy_exec('git remote add ' + environment + ' ' + that.config.environments[environment])).
      then(-> that.deploy_exec('git fetch ' + environment)).
      then(-> that.deploy_exec('git checkout -b ' + deployment_branch_name + ' ' + environment + '/master')).
      then(->
        that.deploy_exec('git merge origin/' + branch).
          catch(-> (error) throw new HubotError('Hmm, looks like ' + branch + " didn't merge cleanly with " + environment + '/master, you could try clobbering..'))
      ).
      then(-> that.deploy_exec('git push ' + environment + ' ' + deployment_branch_name + ':master')).
      catch((error) -> that.logger.error(error); throw error).
      fin(->
        cd(previous_dir)
        that.logger.info 'Cleaning up ' + that.repo_location + '...'
        rm('-rf', that.repo_location)
        rm(that.private_key_location)
        that.logger.info 'done'
        that.deployment_lock = false
      )

  environment_names: -> Object.keys(@config.environments)
  environment_exists: (env) -> env of @config.environments

module.exports = (robot) ->
  config = new Config(robot.logger)
  deployer = new Deployer(robot.logger, config)

  robot.error (err, msg) ->
    robot.logger.error "Deployment error!"
    robot.logger.error(err)

  robot.respond /what (deploy\s)?environments exist\??/i, (msg) ->
    msg.reply 'I can deploy to the following environments: ' + deployer.environment_names().join(', ')

  robot.respond /(?:deploy|put) ([a-z0-9_\-]+\s)?(?:to|on) (\w+)(\s+(?:and\s+)?clobber)?/i, (msg) ->
    return msg.reply("I'm deploying something right now! Give me a gosh darn minute, please") if deployer.deploying()

    branch = if (msg.match[1] || '').trim().length then msg.match[1].trim() else 'master'
    environment = msg.match[2].toLowerCase()
    clobber = (msg.match[3] || '').trim().length

    return msg.reply('No environment ' + environment) unless deployer.environment_exists(environment)

    msg.send "It's clobbering time!!" if clobber
    msg.reply 'Ok, deploying ' + branch + ' to ' + environment + '...'

    deployer.deploy(branch, environment, clobber).
      then(-> msg.reply('...done! ' + branch + ' has been deployed')).
      catch((error) -> msg.reply(error.hubot_error || 'Woops! Some kind of error happened, check the logs for more details')).
      done()
