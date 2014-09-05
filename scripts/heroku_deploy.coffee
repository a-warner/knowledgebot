# Description:
#   Deploy git repositories to heroku.
#
# Dependencies:
#   Auth
#
# Configuration:
#   PRIVATE_KEY - base64 encoded private key that has access to both github
#     and heroku
#   ENVIRONMENT_NAME_DEPLOYMENT_URL - ENVIRONMENT_NAME should be the logical
#     name of the environment, e.g. "STAGING_DEPLOYMENT_URL". Can be repeated n
#     times for unique environment names.
#   GIT_REPO_URL – the origin repo you want to deploy
#   GITHUB_TRUSTED_HOST - base64 encoded line from ~/.ssh/known_hosts for github.com
#   HEROKU_TRUSTED_HOST - base64 encoded line from ~/.ssh/known_hosts for heroku.com
#
# Commands:
#   hubot deploy <branch> to <environment> - deploy to environment. Branch name defaults to "master" if not specified
#   hubot deploy <branch> to <environment> clobber - deploy to environment and clobber (force push)
#   hubot what environments exist? - print out environments hubot can deploy to
#
# Author:
#   a-warner

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
    @shell = new Shell(logger, path.join(tmp, 'hubot_private_key'), @config.private_key)

  trust: (host) ->
    that = this
    @run('mkdir -p $HOME/.ssh && touch $HOME/.ssh/known_hosts').
      then(-> that.run('grep -q \"' + host + '\" $HOME/.ssh/known_hosts || echo "' + host + '" >> $HOME/.ssh/known_hosts'))

  error: (error) ->
    deferred = Q.defer()
    deferred.reject(error)
    deferred.promise

  deploying: -> @deployment_lock

  run: -> @shell.run.apply(@shell, arguments)

  deploy: (branch, environment, clobber) ->
    that = this

    return @error(new Error("Currently deploying")) if @deploying()
    @deployment_lock = true

    repo = null

    @trust(@config.github_trusted_host).
      then(-> that.trust(that.config.heroku_trusted_host)).
      then(-> GitRepo.clone(that.logger, that.shell, that.config.origin_repo_url, that.repo_location)).
      then((git_repo) ->
        repo = git_repo
        repo.promise.then(-> repo.branch_exists(branch))
      ).
      then((branch_exists) -> throw new HubotError("Branch #{branch} does not exist") unless branch_exists).
      then(-> repo.add_remote(environment, that.config.environments[environment])).
      then(-> repo.checkout(branch)).
      then(->
        unless clobber
          repo.merge("#{environment}/master").
            catch(-> (error) throw new HubotError("Hmm, looks like #{branch} didn't merge cleanly with #{environment}/master, you could try clobbering.."))
      ).
      then(-> repo.branch_up_to_date(environment, branch, 'master')).
      then((branch_up_to_date) ->
        if branch_up_to_date
          throw new HubotError("It looks like #{branch} is all up-to-date with #{environment} already")
      ).
      then(->
        flags = if clobber then ['--force'] else []
        repo.push(environment, branch, 'master', flags)
      ).
      catch((error) -> that.logger.error(error); throw error).
      fin(->
        repo.cleanup() if repo
        that.shell.cleanup()
        that.logger.info 'done'
        that.deployment_lock = false
      )

  environment_names: -> Object.keys(@config.environments)
  environment_exists: (env) -> env of @config.environments

class Shell
  constructor: (logger, private_key_location, private_key) ->
    @logger = logger
    @private_key_location = private_key_location
    @private_key = private_key

  run: (input_cmd, error_message) ->
    that = this
    escaped = input_cmd.replace(/"/g, "\\\"")
    cmd = "CMD=\"#{escaped}\" ssh-agent bash -c 'ssh-add #{@private_key_location}; eval $CMD'"
    Q.nfcall(fs.writeFile, @private_key_location, @private_key).
      then(-> Q.nfcall(fs.chmod, that.private_key_location, '600')).
      then(-> that.safe_exec cmd, error_message)

  cleanup: ->
    rm(@private_key_location)

  safe_exec: (cmd, error_message) ->
    deferred = Q.defer()
    that = this

    @logger.info "Running command: #{cmd}"
    execution = exec cmd, (status, output) ->
      if status == 0
        deferred.resolve(output)
      else
        message = error_message || "Error running #{cmd}\n, output is:\n#{output}"
        deferred.reject(new Error(message))

    execution.stdout.on 'data', (data) -> that.logger.info(data)
    execution.stderr.on 'data', (data) -> that.logger.info(data) if (data || '').trim().length
    deferred.promise

class GitRepo
  constructor: (logger, shell, repo_dir) ->
    @logger = logger
    @shell = shell
    @repo_dir = repo_dir
    @promise = @_setup()

  _setup: ->
    that = this
    @run('git config --get user.name || git config user.name "Hu Bot"').
      then(-> that.run('git config --get user.email || git config user.email "hubot@example.org"')).
      then(-> that)

  @clone: (logger, shell, repo_url, location) ->
    shell.run("git clone #{repo_url} #{location}").
      then(-> new GitRepo(logger, shell, location))

  run: ->
    previous_directory = pwd()
    cd(@repo_dir)
    @shell.run.apply(@shell, arguments).fin(-> cd(previous_directory))

  branch_exists: (branch) ->
    regexp = new RegExp("^\\s+remotes\/origin\/#{branch}$", 'm')
    @run('git branch -a').then((branches) -> !!branches.match(regexp))

  add_remote: (remote_name, url) ->
    that = this
    @run("git remote add #{remote_name} #{url}").
      then(-> that.run("git fetch #{remote_name}"))

  checkout: (branch) -> @run("git checkout #{branch}")

  merge: (branch) -> @run("git merge #{branch}")

  branch_up_to_date: (remote, branch, remote_branch) ->
    @push(remote, branch, remote_branch, ['--dry-run']).
      catch((error) -> error.message).
      then((output) -> !!output.match(new RegExp('^Everything up-to-date', 'm')))

  push: (remote, branch, remote_branch, flags) ->
    flag_string = flags.join(' ')

    @run("git push #{remote} #{branch}:#{remote_branch} #{flag_string}")

  cleanup: ->
    @logger.info "Cleaning up #{@repo_dir}..."
    rm('-rf', @repo_dir)

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

    required_role = environment + ' deployer'
    return msg.reply('No environment ' + environment) unless deployer.environment_exists(environment)
    return msg.reply("Whoops, you're not allowed to deploy to " + environment + ' (you need to be a ' + required_role + ')') unless robot.auth.hasRole(msg.message.user, required_role)

    if clobber
      if environment == 'production'
        msg.reply "Ahhhh, I can't clobber production!"
        msg.send "/me runs away"
        return
      else
        msg.send "It's clobbering time!!"

    msg.reply 'Ok, deploying ' + branch + ' to ' + environment + '...'

    deployer.deploy(branch, environment, clobber).
      then(-> msg.reply('...done! ' + branch + ' has been deployed')).
      catch((error) -> msg.reply(error.hubot_error || 'Woops! Some kind of error happened, check the logs for more details')).
      done()
