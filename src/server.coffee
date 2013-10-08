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
  fs          = require('fs') # Just to load the HTML files
  Q           = require('q') # Promise library
  _           = require('underscore')
  jsdom       = require('jsdom')
  URI         = require('URIjs')
  url         = require('url')
  EventEmitter = require('events').EventEmitter

  # jsdom only seems to like REMOTE urls to scripts (like jQuery)
  # So, instead, we manually attach jQuery to the window
  jQueryFactory = require('../jquery-module')


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
    constructor: () ->
      @created = new Date()
      @history = []

    attachPromise: (@promise) ->
      @promise.done () =>
        @stopped = new Date()

      @promise.fail (err) =>
        @stopped = new Date()

      @promise.fail (err) =>
        # For NodeJS errors convert them to JSON
        if err.path
          err = {msg: err.message, errno:err.errno, path:err.path, code:err.code}
        @notify('FAILED')
        @notify(err)

      @promise.progress (message) =>
        @notify(message)

    notify: (message) ->
      # Only keep the 50 most recent messages
      #if @history.length > 50
      #  @history.splice(0,1)

      @history.push(message)

    toJSON: () ->
      status = 'UNKNOWN'
      status = 'COMPLETED' if @promise.isFulfilled()
      status = 'FAILED'    if @promise.isRejected()
      status = 'PENDING'   if not @promise.isResolved()
      return {
        created:  @created
        stopped:  @stopped
        history:  @history
        status:    status
      }

  # Stores the Promise for a PDF
  STATE = new class State
    constructor: () ->
      @state = {}

    addTask: (task, repoUser, repoName) ->
      @state["#{repoUser}/#{repoName}"] = task

    getTask: (repoUser, repoName) ->
      return @state["#{repoUser}/#{repoName}"]

    toJSON: () ->
      json = {}
      _.each @state, (task, key) ->
        value = _.omit(task, 'history')
        json[key] = value

      return json

  #### Spawns ####
  env =
    env: process.env
  env.env['PDF_BIN'] = argv.pdfgen

  errLogger = (task, isError) -> (data) ->
    lines = data.toString().split('\n')
    for line in lines
      if line.length > 1
        if isError
          task.notify("STDERR: #{line}")
          console.error("STDERR: #{line}")
        else
          task.notify(line)

  cloneOrPull = (task, repoUser, repoName) ->
    # 1. Check if the directory already exists
    # 2. If yes, pull updates
    # 3. Otherwise, clone the repo

    deferred = Q.defer()

    # return fsExists(path.join(DATA_PATH, repoUser, repoName))
    # .then (exists) ->
    #   if exists
    #     return spawnPullCommits(task, repoUser, repoName)
    #   else
    #     return spawnCloneRepo(task, repoUser, repoName)

    fs.exists path.join(DATA_PATH, repoUser, repoName), (exists) ->
      if exists
        p = spawnPullCommits(task, repoUser, repoName)
      else
        p = spawnCloneRepo(task, repoUser, repoName)
      p.fail (err) -> deferred.reject(err)
      p.done (val) -> deferred.resolve(val)

    return deferred.promise


  spawnHelper = (task, cmd, args=[], options={}) ->
    child = spawn(cmd, args, options)
    child.stderr.on 'data', errLogger(task, true)
    child.stdout.on 'data', errLogger(task, false)

    deferred = Q.defer()
    child.on 'exit', (code) ->
      return deferred.reject('Returned nonzero error code') if 0 != code
      deferred.resolve()
    return deferred.promise

  spawnCloneRepo = (task, repoUser, repoName) ->
    url = "https://github.com/#{repoUser}/#{repoName}.git"
    destPath = path.join(DATA_PATH, repoUser, repoName)

    task.notify('Cloning repo')
    return spawnHelper(task, 'git', [ 'clone', '--verbose', url, destPath ])


  spawnPullCommits = (task, repoUser, repoName) ->
    cwd = path.join(DATA_PATH, repoUser, repoName)

    task.notify('Pulling remote updates')
    return spawnHelper(task, 'git', [ 'pull' ], {cwd:cwd})


  # From: http://stackoverflow.com/questions/13192660/nodejs-error-emfile
  # Queuing reads and writes, so your nodejs script doesn't overwhelm system limits catastrophically
  maxFilesInFlight = 100 # Set this value to some number safeish for your system
  origRead = fs.readFile
  origWrite = fs.writeFile
  activeCount = 0
  pending = []
  wrapCallback = (cb) ->
    ->
      activeCount--
      cb.apply this, Array::slice.call(arguments)
      if activeCount < maxFilesInFlight and pending.length
        # console.log "Processing Pending read/write"
        pending.shift()()

  fs.readFile = ->
    args = Array::slice.call(arguments)
    if activeCount < maxFilesInFlight
      if args[1] instanceof Function
        args[1] = wrapCallback(args[1])
      else args[2] = wrapCallback(args[2])  if args[2] instanceof Function
      activeCount++
      origRead.apply fs, args
    else
      # console.log "Delaying read:", args[0]
      pending.push ->
        fs.readFile.apply fs, args


  fsReadDir   = () -> Q.nfapply(fs.readdir,   arguments)
  fsStat      = () -> Q.nfapply(fs.stat,      arguments)
  fsReadFile  = () -> Q.nfapply(fs.readFile,  arguments)

  # Given an HTML (or XML) string, return a Promise of a jQuery object
  buildJQuery = (uri, xml) ->
    deferred = Q.defer()
    #jsdom.env html, [ "file://#{JQUERY_PATH}" ], (err, window) ->
    jsdom.env
      html: xml
      # src: [ "//<![CDATA[\n#{JQUERY_CODE}\n//]]>" ]
      # scripts: [ "http://code.jquery.com/jquery.js" ] # [ "file://#{JQUERY_PATH}" ]
      # scripts: [ "#{argv.u}/jquery.js" ]
      done: (err, window) ->
        return deferred.reject(err) if err

        # Attach jQuery to the window
        jQueryFactory(window)

        if window.jQuery
          deferred.notify {msg: 'jQuery built for file', path: uri.toString()}
          deferred.resolve(window.jQuery)
        else
          deferred.reject('Problem loading jQuery...')
    return deferred.promise


  # Concatenate all the HTML files in an EPUB together
  assembleHTML = (task, repoUser, repoName) ->

    allHtmlFileOrder = []
    allHtml = {}

    # 1. Read the META-INF/container.xml file
    # 2. Read the first OPF file
    # 3. Read the ToC Navigation file (relative to the OPF file)
    # 4. Read each HTML file linked to from the ToC file (relative to the ToC file)

    root = new URI(path.join(DATA_PATH, repoUser, repoName) + '/')

    readUri = (uri) ->
      filePath = decodeURIComponent(uri.absoluteTo(root).toString())
      task.notify {msg:'Reading file', path:uri.toString()}
      fsReadFile(filePath)


    # Check that a mimetype file exists
    task.notify('Checking if mimetype file exists')
    return readUri(new URI('mimetype'))
    .then (mimeTypeStr) ->
      # Fail if the mimetype file is invalid
      if 'application/epub+zip' != mimeTypeStr.toString().trim()
        return Q.defer().reject('Invalid mimetype file')

      # 1. Read the META-INF/container.xml file
      containerUri = new URI('META-INF/container.xml')
      return readUri(containerUri)
      .then (containerXml) ->
        return buildJQuery(containerUri, containerXml)
        .then ($) ->
          # 2. Read the first OPF file
          $opf = $('container > rootfiles > rootfile[media-type="application/oebps-package+xml"]').first()
          opfPath = $opf.attr('full-path')
          opfUri = new URI(opfPath)
          return readUri(opfUri)
          .then (opfXml) ->
            # Find the absolute path to the ToC navigation file
            return buildJQuery(opfUri, opfXml)
            .then ($) ->
              $navItem = $('package > manifest > item[properties^="nav"]')
              navPath = $navItem.attr('href')

              # 3. Read the ToC Navigation file (relative to the OPF file)
              task.notify('Reading ToC Navigation file')
              navUri = new URI(navPath)
              navUri = navUri.absoluteTo(opfUri) # Make sure navUri is absolute because it is used later to load HTML files
              return readUri(navUri)
              .then (navHtml) ->
                return buildJQuery(navUri, navHtml)
                .then ($) ->
                  # 4. Read each HTML file linked to from the ToC file (relative to the ToC file)
                  $toc = $('nav')

                  anchorPromises = _.map $toc.find('a'), (a) ->
                    $a = $(a)
                    href = $a.attr('href')

                    fileUri = new URI(href)
                    fileUri = fileUri.absoluteTo(navUri)

                    # Remember the order of files so they can be concatenated again
                    allHtmlFileOrder.push(fileUri.toString())

                    return readUri(fileUri)
                    .then (html) ->
                      return buildJQuery(fileUri, html)
                      .then ($) ->
                        allHtml[fileUri.toString()] = $('body')[0].innerHTML

                  # Concatenate all the HTML once they have all been parsed
                  return Q.all(anchorPromises)
                  .then () ->
                    task.notify {msg:'Combining HTML files', count:allHtmlFileOrder.length}

                    htmls = []
                    for key in allHtmlFileOrder
                      htmls.push(allHtml[key])
                    joinedHtml = htmls.join('\n')
                    task.notify {msg:'Combined HTML files', size:joinedHtml.length}
                    return joinedHtml


  spawnGeneratePDF = (html, task, repoUser, repoName) ->
    deferred = Q.defer()

    env = {cwd:path.join(DATA_PATH, repoUser, repoName)}
    child = spawn(argv.pdfgen, [ '--input=xhtml', '--verbose', '--output=-', '-' ], env)
    chunks = []
    chunkLen = 0

    child.stderr.on 'data', errLogger(task)

    child.stdout.on 'data', (chunk) ->
      chunks.push chunk
      chunkLen += chunk.length

    child.stdin.write html, 'utf-8', () ->
      deferred.notify('Sent input to PDFGEN')
      child.stdin.end()

    child.on 'exit', (code) ->
      return deferred.reject('PDF generation failed') if 0 != code

      buf = new Buffer(chunkLen)
      pos = 0
      for chunk in chunks
        chunk.copy(buf, pos)
        pos += chunk.length
      deferred.resolve(buf)

    return deferred.promise


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
    task = new Task()
    promise = cloneOrPull(task, repoUser, repoName)
    .then () ->
      return assembleHTML(task, repoUser, repoName)
      .then (htmlFragment) ->
        html = """<?xml version='1.0' encoding='utf-8'?>
                  <!DOCTYPE html PUBLIC '-//W3C//DTD XHTML 1.1//EN' 'http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd'>
                  <html xmlns="http://www.w3.org/1999/xhtml">
                    <head>
                      <meta http-equiv="Content-Type" content="application/xhtml+xml; charset=utf-8"/>
                    </head>
                    <body>
                    #{htmlFragment}
                    </body>
                  </html>"""

        return spawnGeneratePDF(html, task, repoUser, repoName)

    task.attachPromise(promise)

    STATE.addTask(task, repoUser, repoName)
    return task

  #### Routes ####

  # app.get '/:repoUser/:repoName', (req, res, next) ->
  #   res.redirect("/#{req.param('repoUser')}/#{req.param('repoName')}/")

  app.get '/recent', (req, res) ->
    res.send(STATE.toJSON())

  app.get '/:repoUser/:repoName/', (req, res, next) ->
    res.header('Content-Type', 'text/html')

    # Read the file here so I don't have to restart for development
    INDEX_FILE = fs.readFileSync(path.join(__dirname, '..', 'static', 'index.html'))

    res.send(INDEX_FILE)

  app.get '/:repoUser/:repoName/status', (req, res) ->
    repoUser = req.param('repoUser')
    repoName = req.param('repoName')

    task = STATE.getTask(repoUser, repoName)

    return res.status(404).send('NOT FOUND. Try adding a commit Hook first.') if not task
    res.send(task.toJSON())

  app.get '/:repoUser/:repoName.png', (req, res) ->
    repoUser = req.param('repoUser')
    repoName = req.param('repoName')

    task = STATE.getTask(repoUser, repoName)

    res.header('Content-Type', 'image/png')
    return res.send(BADGE_STATUS_FAILED) if not task

    switch task.toJSON().status
      when 'COMPLETED' then res.send(BADGE_STATUS_COMPLETE)
      when 'PENDING' then res.send(BADGE_STATUS_PENDING)
      when 'FAILED'  then res.send(BADGE_STATUS_FAILED)
      else
        res.send(BADGE_STATUS_FAILED)

  app.get '/:repoUser/:repoName/pdf', (req, res) ->
    repoUser = req.param('repoUser')
    repoName = req.param('repoName')

    task = STATE.getTask(repoUser, repoName)

    return res.status(404).send('NOT FOUND. Try adding a commit Hook first.') if not task

    promise = task.promise
    if promise.isResolved()
      res.header('Content-Type', 'application/pdf')
      task.promise.done (data) ->
        res.send(data)
    else if promise.isRejected()
      res.status(400).send(task.toJSON())
    else if not promise.isFulfilled()
      res.status(202).send(task.toJSON())
    else
      throw new Error('BUG: Something fell through')


  app.get '/:repoUser/:repoName/submit', (req, res, next) ->
    # payload = req.param('payload')

    repoUser = req.param('repoUser')
    repoName = req.param('repoName')

    task = buildPdf(repoUser, repoName)
    # Send OK
    res.send(task.toJSON())


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
    res.send(task.toJSON())

  #### Start the server ####

  app.listen(argv.p, argv.o if argv.o)
  # When server is listening emit a ready event.
  app.emit "ready"
  console.log("Server listening in mode: #{app.settings.env}")

  # Return app when called, so that it can be watched for events and shutdown with .close() externally.
  app
