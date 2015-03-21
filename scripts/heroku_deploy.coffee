# Description:
#   Deploy git repositories to heroku.
#
# Dependencies:
#   Auth
#
# Configuration:
#   PRIVATE_KEY - base64 encoded private key that has access to both github
#     and heroku
#   MY_APP_NAME_HEROKU_APP - MY_APP is the logical name of the heroku app to deploy to.
#   May be repeated N times for any number of heroku apps.
#   Value is a JSON.stringified object with the following required keys:
#     domain: the name of the domain to deploy to
#     origin_repo_url: the github origin remote
#     deployment_url: the heroku remote to deploy to
#     environment: the environment name, use production to protect against non-master deploys and clobbering
#   GITHUB_TRUSTED_HOST - base64 encoded line from ~/.ssh/known_hosts for github.com
#   HEROKU_TRUSTED_HOST - base64 encoded line from ~/.ssh/known_hosts for heroku.com
#
# Commands:
#   hubot deploy <branch> to <domain> - deploy to domain. Branch name defaults to "master" if not specified
#   hubot deploy <branch> to <domain> clobber - deploy to domain and clobber (force push)
#   hubot what domains exist? - print out domains hubot can deploy to
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

    throw new Error('I need my own private key! Please set the PRIVATE_KEY env var') unless (process.env.PRIVATE_KEY || '').trim().length
    @private_key = new Buffer(process.env.PRIVATE_KEY, 'base64')

    throw new Error('I need a github host to trust, please set GITHUB_TRUSTED_HOST') unless (process.env.GITHUB_TRUSTED_HOST || '').trim().length
    @github_trusted_host = new Buffer(process.env.GITHUB_TRUSTED_HOST, 'base64')

    throw new Error('I need a heroku host to trust, please set HEROKU_TRUSTED_HOST') unless (process.env.HEROKU_TRUSTED_HOST || '').trim().length
    @heroku_trusted_host = new Buffer(process.env.HEROKU_TRUSTED_HOST, 'base64')

    @apps = {}
    for key, value of process.env when process.env.hasOwnProperty(key) && /.+_HEROKU_APP$/.test(key)
      app = new HerokuApp(key, JSON.parse(value))
      throw new Error("#{app.domain} is configured twice!") if app.domain of @apps
      @apps[app.domain] = app

    logger.info('heroku_deploy detected apps:')
    logger.info(@apps)

    @app_name = process.env.APP_NAME
    if @app_name && process.env.PAPERTRAIL_API_TOKEN
      @log_addon_url = "https://addons-sso.heroku.com/apps/#{@app_name}/addons/papertrail"

class HerokuApp
  constructor: (key, options) ->
    {@environment, @origin_repo_url, @deployment_url, @domain} = options
    for expected_key in ['environment', 'origin_repo_url', 'deployment_url', 'domain']
      throw new Error("Expected key \"#{expected_key}\" to be in #{key}") unless (options[expected_key] || '').trim().length
      this[expected_key] = options[expected_key]

class HubotError extends Error
  constructor: (msg) ->
    super(msg)
    @hubot_error = msg

class Deployer
  constructor: (logger, config) ->
    @logger = logger
    @config = config
    @deployment_lock = {}

    @tmp = os.tmpDir()
    @logger.info 'tmpDir is ' + @tmp

    private_key_location = path.join(@tmp, 'hubot_private_key')
    @shell = new Shell(logger, private_key_location)
    process.on 'exit', => @shell.cleanup()

    @setup = Q.nfcall(fs.writeFile, private_key_location, @config.private_key).
              then(=> Q.nfcall(fs.chmod, private_key_location, '600')).
              then(=> @trust(@config.github_trusted_host).then(=> @trust(@config.heroku_trusted_host)))

  trust: (host) ->
    @run('mkdir -p $HOME/.ssh && touch $HOME/.ssh/known_hosts').
      then(=> @run('grep -q \"' + host + '\" $HOME/.ssh/known_hosts || echo "' + host + '" >> $HOME/.ssh/known_hosts'))

  deploying: (domain) -> @deployment_lock[domain]

  run: -> @shell.run.apply(@shell, arguments)

  deploy: (branch, domain, clobber) ->
    @setup.then(=>
      throw new Error("Currently deploying #{domain}") if @deploying(domain)

      deployment = new Deployment(
        app: @config.apps[domain],
        branch: branch,
        clobber: clobber,
        tmp: @tmp,
        shell: @shell,
        logger: @logger
      )

      @deployment_lock[domain] = deployment
      deployment.deploy()
    ).fin(=> delete @deployment_lock[domain])

  app_domain_names: -> Object.keys(@config.apps)
  app_for: (requested_domain) ->
    app for domain, app of @config.apps when domain.indexOf(requested_domain) == 0

class Deployment
  constructor: (options) ->
    {@branch, @app, @clobber, @tmp, @shell, @logger} = options
    @domain = @app.domain

    @repo_location = path.join(@tmp, @app.domain, 'hubot_deploy_repo')

  deploy: ->
    GitRepo.clone(@logger, @shell, @app.origin_repo_url, @repo_location).
      then((git_repo) =>
        @repo = git_repo
        @repo.branch_exists(@branch)
      ).
      then((branch_exists) => throw new HubotError("Branch #{@branch} does not exist") unless branch_exists).
      then(=> @repo.add_remote(@domain, @app.deployment_url)).
      then(=> @repo.checkout(@branch)).
      then(=>
        unless @clobber
          @repo.merge("#{@domain}/master").
            catch(=> (error) throw new HubotError("Hmm, looks like #{@branch} didn't merge cleanly with #{@domain}/master, you could try clobbering.."))
      ).
      then(=> @repo.branch_up_to_date(@domain, @branch, 'master')).
      then((branch_up_to_date) =>
        if branch_up_to_date
          throw new HubotError("It looks like #{@domain} is all up-to-date with #{@branch} already")
      ).
      then(=>
        flags = if @clobber then ['--force'] else []
        @repo.push(@domain, @branch, 'master', flags)
      ).
      catch((error) => @logger.error(error); throw error).
      fin(=>
        @repo.cleanup() if @repo
        @logger.info "done deploying #{@branch} to #{@app.domain}"
      )

class Shell
  constructor: (logger, private_key_location) ->
    @logger = logger
    @private_key_location = private_key_location

  run: (input_cmd, error_message) ->
    escaped = input_cmd.replace(/"/g, "\\\"")
    cmd = "CMD=\"#{escaped}\" ssh-agent bash -c 'ssh-add #{@private_key_location}; eval $CMD'"
    @safe_exec cmd, error_message

  cleanup: -> rm(@private_key_location)

  safe_exec: (cmd, error_message) ->
    deferred = Q.defer()

    @logger.info "Running command: #{cmd}"
    execution = exec cmd, (status, output) ->
      if status == 0
        deferred.resolve(output)
      else
        message = error_message || "Error running #{cmd}\n, output is:\n#{output}"
        deferred.reject(new Error(message))

    execution.stdout.on 'data', (data) => @logger.info(data)
    execution.stderr.on 'data', (data) => @logger.info(data) if (data || '').trim().length
    deferred.promise

class GitRepo
  constructor: (logger, shell, repo_dir) ->
    @logger = logger
    @shell = shell
    @repo_dir = repo_dir

  @clone: (logger, shell, repo_url, location) ->
    shell.run("git clone #{repo_url} #{location}").
      then(-> shell.run('git config --get user.name || git config user.name "Hu Bot"')).
      then(-> shell.run('git config --get user.email || git config user.email "hubot@example.org"')).
      then(-> new GitRepo(logger, shell, location))

  run: ->
    previous_directory = pwd()
    cd(@repo_dir)
    @shell.run.apply(@shell, arguments).fin(-> cd(previous_directory))

  branch_exists: (branch, include_remote = true) ->
    regexp = new RegExp("^[\\s*]+(remotes\/origin\/)?#{branch}$", 'm')
    @run("git branch#{if include_remote then ' -a' else ''}").then((branches) -> !!branches.match(regexp))

  add_remote: (remote_name, url) ->
    @run("git remote add #{remote_name} #{url}").
      then(=> @run("git fetch #{remote_name}"))

  checkout: (branch) ->
    @branch_exists(branch, !'include_remote').then (branch_exists) =>
      if branch_exists
        @run("git checkout #{branch}")
      else
        @run("git checkout -b #{branch} origin/#{branch}")

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

  robot.respond /what (deploy\s)?domains exist\??/i, (msg) ->
    msg.reply 'I can deploy to the following domains: ' + deployer.app_domain_names().join(', ')

  robot.respond /(?:deploy|put|throw|launch) ([a-z0-9_\-]+\s)?(?:to|on) (\S+)(\s+(?:and\s+)?clobber)?/i, (msg) ->
    branch = if (msg.match[1] || '').trim().length then msg.match[1].trim() else 'master'
    domain = msg.match[2].toLowerCase()
    clobber = (msg.match[3] || '').trim().length

    apps = deployer.app_for(domain)
    return msg.reply('No domain ' + domain) unless apps.length
    return msg.reply("#{domain} matched multiple domains (#{apps.map((a) -> a.domain).join(', ')})") if apps.length > 1

    app = apps[0]
    domain = app.domain
    required_role = domain + ' deployer'

    return msg.reply("Whoops, you're not allowed to deploy to " + domain + ' (you need to be a ' + required_role + ')') unless robot.auth.hasRole(msg.message.user, required_role)
    return msg.reply("I'm deploying something to #{domain} right now! Give me a gosh darn minute, please") if deployer.deploying(domain)

    if app.environment == 'production'
      if clobber
        msg.reply "Ahhhh, I can't clobber production!"
        msg.send "/me runs away"
        return
      unless branch == 'master'
        msg.reply "Sorry, I can only deploy master to a production environment"
        return

    msg.send "It's clobbering time!!" if clobber
    msg.reply 'Ok, deploying ' + branch + ' to ' + domain + '...'

    deployer.deploy(branch, domain, clobber).
      then(-> msg.reply("...done! #{branch} has been deployed to #{domain}")).
      catch((error) ->
        log_addon_msg = ''
        if config.log_addon_url
          log_addon_msg = ": #{config.log_addon_url}"

        msg.reply(error.hubot_error || "Woops! Some kind of error happened, check the logs for more details#{log_addon_msg}")
      ).done()
