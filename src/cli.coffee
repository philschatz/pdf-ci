# Cli for the express server

path = require 'path'
optimist = require 'optimist'
server = require './server'

# Handle command line options

args = optimist
  .usage('Usage: $0')
  .options('h',
    alias     : 'help'
    boolean   : true
    describe  : 'Show this help info and exit'
  )
  .options('o',
    alias     : 'host'
    default   : ''
    describe  : 'Host to accept connections on, false == any'
  )
  .options('p',
    alias     : 'port'
    default   : 3001
    describe  : 'Port'
  )
  .options('d',
    alias     : 'data'
    default   : path.join(__dirname, 'data')
    describe  : 'Path to writable data directory'
  )
  .options('m',
    alias     : 'mongodb'
    default   : '127.0.0.1:27017/local'
    describe  : 'Connection string for MongoDB (note "mongo://" is missing)'
  )

# If h/help is set print the generated help message and exit.
if args.argv.h
  optimist.showHelp()
  process.exit()

module.exports = args
