# Set export objects for node and coffee to a function that generates a sfw server.
module.exports = exports = (argv) ->

  SVG_TO_PNG_DPI = 12

  #### Dependencies ####
  # anything not in the standard library is included in the repo, or
  # can be installed with an:
  #     npm install
  spawn       = require('child_process').spawn
  express     = require('express')
  path        = require('path')
  Q           = require('q') # Promise library
  _           = require('underscore')
  jsdom       = require('jsdom')
  URI         = require('URIjs')
  url         = require('url')
  EventEmitter = require('events').EventEmitter
  mongojs = require('mongojs')

  fs          = require('./fs-helpers') # Async `fs.*` calls wrapped as promises
  MongoFsHelper = require('./mongo-fs-helper')

  # jsdom only seems to like REMOTE urls to scripts (like jQuery)
  # So, instead, we manually attach jQuery to the window
  jQueryFactory = require('./jquery-module')


  CONNECTION_URL = '127.0.0.1:27017/mydb'
  mongoFsHelper = new MongoFsHelper(CONNECTION_URL)


  # Set up the mongo connection
  db = mongojs(CONNECTION_URL, ['tasks'])

  # Error if required args are not included
  REQUIRED_ARGS = [ 'pdfgen' ]
  REQUIRED_ARGS.forEach (arg) ->
    if not argv[arg]
      console.error "Required command line argument missing: #{arg}"
      throw new Error "Required command line argument missing"


  # Enable easy-to-read stack traces
  #Q.longStackSupport = true
  # Silently fail instead of taking down the webserver
  Q.onerror = (err) -> console.error(err)

  DATA_PATH = path.join(__dirname, '..', 'data')
  JQUERY_PATH = path.join(__dirname, '..', 'bower_components/jquery/jquery.js')
  JQUERY_CODE = fs.readFileSync(JQUERY_PATH, 'utf-8')


  BADGE_STATUS_FAILED   = fs.readFileSync(path.join(__dirname, '..', 'static', 'images', 'status-failed.png'))
  BADGE_STATUS_COMPLETE = fs.readFileSync(path.join(__dirname, '..', 'static', 'images', 'status-complete.png'))
  BADGE_STATUS_PENDING  = fs.readFileSync(path.join(__dirname, '..', 'static', 'images', 'status-pending.png'))

  class Task
    constructor: (@repoUser, @repoName, @buildId) ->

      @query =
        repoUser: @repoUser
        repoName: @repoName
        build:    @buildId

    attachPromise: (@promise) ->
      @promise.done (pdf) =>
        fs.writeFileSync(path.join(DATA_PATH, "#{@repoUser}/#{@repoName}.pdf"), pdf)
        db.tasks.update @query,
          $set:
            status: 'COMPLETED'
            lastCompletedBuild: @buildId
            stopped: new Date()
            updated: new Date()

      @promise.fail (err) =>
        # For NodeJS errors convert them to JSON
        if err.path
          err = {msg: err.message, errno:err.errno, path:err.path, code:err.code}

        db.tasks.update @query,
          $push: {history: err}
          $set:
            status: 'FAILED'
            stopped: new Date()
            updated: new Date()

      @promise.progress (message) =>
        @notify(message)

    notify: (message) ->
      db.tasks.update @query,
        $push: {history: message}
        $set:
          status: 'PENDING'
          updated: new Date()




  # Create the main application object, app.
  app = express.createServer()

  # defaultargs.coffee exports a function that takes the argv object that is passed in and then does its
  # best to supply sane defaults for any arguments that are missing.
  argv = require('./defaultargs')(argv)

  #### Express configuration ####
  # Set up all the standard express server options
  app.configure( ->
    app.set('view options', layout: false)
    app.use(express.cookieParser())
    app.use(express.bodyParser())
    app.use(express.methodOverride())
    app.use(express.session({ secret: 'notsecret'}))
    app.use(app.router)
    app.use(express.static(path.join(__dirname, '..', 'static')))
    app.use(express.static(path.join(__dirname, '..')))
  )

  ##### Set up standard environments. #####
  # In dev mode turn on console.log debugging as well as showing the stack on err.
  app.configure('development', ->
    app.use(express.errorHandler({ dumpExceptions: true, showStack: true }))
    argv.debug = console? and true
  )

  # Show all of the options a server is using.
  console.log argv if argv.debug

  # Swallow errors when in production.
  app.configure('production', ->
    app.use(express.errorHandler())
  )

  buildPdf = (repoUser, repoName) ->

    # Add a document to the db
    query =
      repoUser: repoUser
      repoName: repoName
    updateDoc =
      $set:
        created: new Date()
        updated: new Date()
        status:  'WAITING'
      $inc: {build: 1}

    findArgs =
      findAndModify: 'tasks'
      query:  query
      update: updateDoc
      fields: {build: 1} # Only return the build number
      new:    true # return the updated Doc
      upsert: true

    return Q.ninvoke(db.tasks, 'findAndModify', findArgs)
    .then (updatedResp) ->
      # For some reason updatedResp is an array with the object in [0] and documented response as the 2nd argument
      return updatedResp[0].value?.build
      # buildId = updatedResp[1].value.build # Used to get the build id

  #### Routes ####

  # app.get '/:repoUser/:repoName', (req, res, next) ->
  #   res.redirect("/#{req.param('repoUser')}/#{req.param('repoName')}/")

  app.get '/recent', (req, res) ->
    db.tasks.find().limit(10).sort {updated:-1}, (err, tasks) ->
      if err
        res.status(500).send(err)
      else
        tasks = _.map tasks, (task) -> _.omit(task, ['_id', 'history'])
        res.send(tasks)


  app.get '/:repoUser/:repoName/', (req, res, next) ->
    res.header('Content-Type', 'text/html')

    # Read the file here so I don't have to restart for development
    INDEX_FILE = fs.readFileSync(path.join(__dirname, '..', 'static', 'index.html'))

    res.send(INDEX_FILE)

  app.get '/:repoUser/:repoName/status', (req, res) ->
    repoUser = req.param('repoUser')
    repoName = req.param('repoName')

    db.tasks.find {repoUser:repoUser, repoName:repoName}, (err, tasks) ->
      if err
        res.status(500).send(err)
      else if tasks.length
        task = _.extend {}, tasks[0]

        # FIXME: clear the log file when the task is set to 'WAITING' instead
        if 'WAITING' == task.status
          task.history = []
          return res.send(task)

        # Read the log to attach to history
        filePath = path.join(DATA_PATH, repoUser, "#{repoName}.log")
        fs.exists filePath, (fileExists) ->
          if fileExists
            promise = fs.readFile(filePath)
            promise.fail (err) ->
              if 'PENDING' == task.status
                task.history = []
              else
                task.history = ['(No Log Found for this build)']
              res.send(task)

            promise.done (buf) ->
              task.history = buf.toString().trim().split('\n') # Remove the trailing newline
              res.send(task)
          else
            # Log file not found. either return empty (it will be filled by the slave)
            # or put in an error message saying it is missing
            if 'PENDING' == task.status
              task.history = []
            else
              task.history = ['(No Log Found for this build)']
            res.send(task)

      else
        res.status(404).send('NOT FOUND. Try adding a commit Hook first.')

  app.get '/:repoUser/:repoName.png', (req, res) ->
    repoUser = req.param('repoUser')
    repoName = req.param('repoName')

    res.header('Content-Type', 'image/png')

    # TODO: Until we get a SSL Certificate send the 'COMPLETED' badge because GitHub caches images that do not start with https://
    return res.send(BADGE_STATUS_COMPLETE)

  app.get '/:repoUser/:repoName/pdf', (req, res) ->
    repoUser = req.param('repoUser')
    repoName = req.param('repoName')

    db.tasks.find {repoUser:repoUser, repoName:repoName}, (err, tasks) ->
      if err
        res.status(500).send(err)
      else if tasks.length
        sha = tasks[0].lastBuiltSha

        # A PDF has never been successfully generated
        return res.status(404).send() if not sha

        # Read the file (if it exists) from GridFS
        # TODO: Use a stream (not sure how to stream response in express)
        mongoFsHelper.readFile(repoUser, repoName)
        # A PDF has been built before but it is not in the GridFS
        .fail((err) -> res.status(500).send(err))
        .done (buf) ->
          # A PDF has been found, send it.
          res.header('Content-Type', 'application/pdf')
          res.send(buf)

      else
        res.redirect("/#{repoUser}/#{repoName}/")


  app.get '/:repoUser/:repoName/submit', (req, res, next) ->
    # payload = req.param('payload')

    repoUser = req.param('repoUser')
    repoName = req.param('repoName')

    promise = buildPdf(repoUser, repoName)
    promise.fail((err) -> console.error('Problem submitting task', err))
    # Send OK
    res.send('OK')


  # GitHub entrypoint
  app.post '/', (req, res, next) ->
    payload = req.body.payload # param('payload')

    return res.send('IGNORED') if not payload

    payload = JSON.parse(payload)
    return res.send('IGNORED') if payload.created or payload.deleted

    # `payload.ref` is of the form `refs/heads/master`
    refInfo = payload.ref.split('/')

    return res.send('IGNORED') if refInfo[0] != 'refs' or refInfo[1] != 'heads'

    # Ignore anything but the `master` branch

    branchName = refInfo[2]
    return res.send('IGNORED') if branchName != payload.repository?.master_branch

    repoUser = payload.repository.owner.name
    repoName = payload.repository.name


    task = buildPdf(repoUser, repoName)
    # Send OK
    res.send('OK')

  #### Start the server ####

  app.listen(argv.p, argv.o if argv.o)
  # When server is listening emit a ready event.
  app.emit "ready"
  console.log("Server listening in mode: #{app.settings.env}")

  # Return app when called, so that it can be watched for events and shutdown with .close() externally.
  app
