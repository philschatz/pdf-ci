# Wrap File system calls to interact with them as promises
fs = require('fs')
Q  = require('q')



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

queuedReadFile = ->
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


module.exports =
  # unmodified methods that are used
  exists: fs.exists
  readFileSync: fs.readFileSync
  writeFileSync: fs.writeFileSync
  createWriteStream: fs.createWriteStream

  # Modified methods that are used
  readFile: () -> Q.nfapply(queuedReadFile,  arguments)
