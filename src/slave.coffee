spawn       = require('child_process').spawn
express     = require('express')
path        = require('path')
fs          = require('fs') # Just to load the HTML files
Q           = require('q') # Promise library
_           = require('underscore')
url         = require('url')
EventEmitter = require('events').EventEmitter
mongojs = require('mongojs')

EpubAssembler = require('./epub-assembler')
MongoFsHelper = require('./mongo-fs-helper')


MONGO_CONNECTION_URL = '127.0.0.1:27017/mydb'
mongoFsHelper = new MongoFsHelper(MONGO_CONNECTION_URL)


# Set up the mongo connection
db = mongojs(MONGO_CONNECTION_URL, ['tasks'])

# Error if required args are not included
argv = process.argv
argv.pdfgen = argv[2]

# Enable easy-to-read stack traces
#Q.longStackSupport = true
# Silently fail instead of taking down the webserver
Q.onerror = (err) -> console.error(err)

DATA_PATH = path.join(__dirname, '..', 'data')


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





fsReadFile  = () -> Q.nfapply(fs.readFile,  arguments)


class FileAssembler extends EpubAssembler
  constructor: (@rootPath, @logStream) ->

  log: (msg) ->
    return Q.ninvoke(@logStream, 'write', "#{JSON.stringify(msg)}\n")

  readFile: (filePath) ->
    return @log({msg:'Reading file', path:filePath})
    .then () =>
      return fsReadFile(path.join(@rootPath, decodeURIComponent(filePath)))



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

    return cloneOrPull(repoUser, repoName, logStream)
    .then () ->
      assembler.assemble()
      .then (html) ->
        return pdfGenerator.build(html, rootPath, outStream, logStream)
        .then () -> return outStream.md5


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
