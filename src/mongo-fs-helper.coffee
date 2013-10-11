mongodb = require('mongodb')
Q           = require('q') # Promise library


module.exports = class MongoGridFsHelper
  constructor: (@_mongoConnectionUrl) ->

  # Returns a promise containing the md5 hash of the file written to the GridStore
  createWriteSink: (repoUser, repoName) ->
    filePath = "#{repoUser}/#{repoName}.pdf"
    deferred = Q.defer()

    # Stores the md5 hash on this object when done writing.
    class HackWritableStream
      constructor: (@gs) ->
      write: (data, cb) -> @gs.write(data, cb)
      end: (cb) ->
        @gs.close (err, fileInfo) =>
          return deferred.reject(err) if err
          @md5 = fileInfo.md5
          cb(fileInfo)


    mongodb.MongoClient.connect @_mongoConnectionUrl, (err, db) ->
      return deferred.reject(err) if err

      gs = mongodb.GridStore(db, filePath, 'w', {content_type:'application/pdf'})
      gs.open (err, gs) ->
        return deferred.reject(err) if err
        deferred.resolve(new HackWritableStream(gs))

    return deferred.promise

  # TODO: Use this method instead of `readFile`
  createReadableStream: (repoUser, repoName) ->

    deferred = Q.defer()

    mongodb.MongoClient.connect @_mongoConnectionUrl, (err, db) ->
      return deferred.reject(err) if err

      gs = mongodb.GridStore(db, randomFilename, 'r')
      gs.open (err, gs) ->
        return deferred.reject(err) if err
        deferred.resolve(gs.stream(true)) # `true` == autoClose

    return deferred


  readFile: (repoUser, repoName) ->
    filePath = "#{repoUser}/#{repoName}.pdf"
    deferred = Q.defer()

    mongodb.MongoClient.connect @_mongoConnectionUrl, (err, db) ->
      return deferred.reject(err) if err

      gs = mongodb.GridStore(db, filePath, 'r')
      gs.open (err, gs) ->
        return deferred.reject(err) if err
        gs.read (err, buf) ->
          return deferred.reject(err) if err

          gs.close (err) ->
            deferred.resolve(buf)

    return deferred.promise
