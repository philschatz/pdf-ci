spawn       = require('child_process').spawn
express     = require('express')
path        = require('path')
Q           = require('q') # Promise library
_           = require('underscore')
url         = require('url')
EventEmitter = require('events').EventEmitter
mongojs = require('mongojs')

fs            = require('./fs-helpers')
EpubAssembler = require('./epub-assembler')
MongoFsHelper = require('./mongo-fs-helper')

# Add the path to the PDF gen
args = require('./cli')
argv = args
.options('local',
  boolean   : true
  describe  : 'Run locally (do not clone/pull from remote sources)'
).options('debug',
  boolean   : true
  describe  : 'Add debug logging and styling in the PDF'
).options('g',
  alias     : 'pdfgen'
  demand    : true
  describe  : 'Path to executable that converts HTML to PDF (PrinceXML)'
).argv


mongoFsHelper = new MongoFsHelper(argv.mongodb)


# Set up the mongo connection
db = mongojs(argv.mongodb, ['tasks'])

# Enable easy-to-read stack traces
#Q.longStackSupport = true
# Silently fail instead of taking down the webserver
Q.onerror = (err) -> console.error(err)

DATA_PATH = argv.data


#### Spawns ####
env =
  env: process.env
env.env['PDF_BIN'] = argv.pdfgen


cloneOrPull = (repoUser, repoName, logStream) ->

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
      p = spawnPullCommits(repoUser, repoName, logStream)
    else
      p = spawnCloneRepo(repoUser, repoName, logStream)
    p.fail (err) -> deferred.reject(err)
    p.done (val) -> deferred.resolve(val)

  return deferred.promise


spawnHelper = (logStream, cmd, args=[], options={}) ->
  stdio = [ 'pipe', logStream, logStream ]
  options = _.extend {stdio:stdio}, options
  child = spawn(cmd, args, options)

  deferred = Q.defer()
  child.on 'exit', (code) ->
    return deferred.reject('Returned nonzero error code') if 0 != code
    deferred.resolve()
  return deferred.promise

spawnCloneRepo = (repoUser, repoName, logStream) ->
  url = "https://github.com/#{repoUser}/#{repoName}.git"
  destPath = path.join(DATA_PATH, repoUser, repoName)

  return Q.ninvoke(logStream, 'write', 'Cloning Repository\n')
  .then () ->
    return spawnHelper(logStream, 'git', [ 'clone', '--verbose', url, destPath ])


spawnPullCommits = (repoUser, repoName, logStream) ->
  cwd = path.join(DATA_PATH, repoUser, repoName)

  return Q.ninvoke(logStream, 'write', 'Pulling remote updates\n')
  .then () ->
    return spawnHelper(logStream, 'git', [ 'pull' ], {cwd:cwd})


class FileAssembler extends EpubAssembler
  constructor: (@rootPath, @logStream) ->
    @DEBUG = argv.debug

  readFile: (filePath) ->
    return @log({msg:'Reading file', path:filePath})
    .then () =>
      return fs.readFile(path.join(@rootPath, decodeURIComponent(filePath)))



class PdfGenerator

  pdfCommand: () -> argv.pdfgen
  pdfArgs: () -> [ '--input=xhtml', '--verbose', '--output=-', '-' ]


  # Spawn the PDF command and prints logs to @logStream and PDF to @outStream.
  # Returns a promise that resolves once the PDF is written.
  build: (html, rootPath, outStream, logStream) ->
    deferred = Q.defer()

    env =
      cwd: rootPath
      stdio: [
        'pipe', 'pipe', logStream
      ]
    child = spawn(@pdfCommand(), @pdfArgs(), env)
    pendingChunks = 0
    hasEnded = false

    child.stdin.write html, 'utf-8', () ->
      child.stdin.end()

    child.stdout.on 'data', (buf) ->
      pendingChunks += 1
      outStream.write buf, (err) ->
        return deferred.reject(err) if err
        pendingChunks -= 1

        if 0 == pendingChunks and hasEnded
          outStream.end () ->
            deferred.resolve()

    child.stdout.on 'end', () ->
      hasEnded = true
      if 0 == pendingChunks
        outStream.end () ->
          deferred.resolve()


    child.on 'exit', (code) ->
      return deferred.reject('PDF generation failed') if 0 != code

    return deferred.promise


# rootPath = path.join(DATA_PATH, 'philschatz/minimal-book')
# logStream = process.stderr
# outStream = process.stdout

# x = new FileAssembler(rootPath, logStream)
# y = new PdfGenerator()

# z = x.assemble()
# .then (html) ->
#   return y.build(html, rootPath, outStream, logStream)
#   .done () -> console.log('DONE!')

# z.fail((err) -> console.error(err))
# z.done((val) -> console.error('promise-DONE', val))
# return




# Return a promise that resolves to the md5 hash of the built PDF
buildPdf = (repoUser, repoName, rootPath, logStream) ->
  return mongoFsHelper.createWriteSink(repoUser, repoName)
  .then (outStream) ->

    assembler = new FileAssembler(rootPath, logStream)
    pdfGenerator = new PdfGenerator()

    assemble = () ->
      assembler.assemble()
      .then (html) ->
        return pdfGenerator.build(html, rootPath, outStream, logStream)
        .then () -> return outStream.md5

    # If running locally do not clone/pull
    if argv.local
      logStream.write('Warning: Slave Running locally (no clone/pull)\n')
      return assemble()
    else
      return cloneOrPull(repoUser, repoName, logStream)
      .then () ->
        return assemble()


delayedRunLoop = () -> setTimeout(runLoop, 500)

runLoop = () ->

  db.tasks.find({status: 'WAITING'}).limit 1, (err, tasks) ->
    if err
      console.error(err)
      delayedRunLoop()
    if 0 == tasks.length
      return delayedRunLoop()

    taskInfo = tasks[0]

    console.log("Starting #{taskInfo.repoUser}/#{taskInfo.repoName}")


    db.tasks.update taskInfo, {$set:{status:'PENDING'}}, (err, val) ->
      return delayedRunLoop() if err

      # Open up the Log file
      logStream = fs.createWriteStream(path.join(DATA_PATH, taskInfo.repoUser, "#{taskInfo.repoName}.log"))
      rootPath = path.join(DATA_PATH, taskInfo.repoUser, taskInfo.repoName)

      # Update async whenever data is sent to the log
      logStream.on 'data', (buf) ->
        now = new Date()
        query2 = _.extend {}, query, {$lt: {updated: now}}
        db.tasks.update query2, {set: {updated: now}}

      promise = buildPdf(taskInfo.repoUser, taskInfo.repoName, rootPath, logStream)

      query =
        repoUser: taskInfo.repoUser
        repoName: taskInfo.repoName
        build: taskInfo.build

      promise.fail (err) ->
        db.tasks.update query, {$set:{status:'FAILED', updated:new Date(), err:err}}, (err, value) ->

      promise.done (md5) ->
        db.tasks.update query, {$set:{status:'COMPLETED', updated:new Date(),lastBuiltSha:md5}}, (err, value) ->
        delayedRunLoop()

      return

runLoop()
