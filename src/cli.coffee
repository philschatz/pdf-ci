# Cli for the mock express server

path = require 'path'
optimist = require 'optimist'
server = require './server'

# Handle command line options

argv = optimist
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
  .options('u',
    alias     : 'url'
    default   : ''
    describe  : 'Url to be used for the realm in openID'
  )
  .options('p',
    alias     : 'port'
    default   : 3001
    describe  : 'Port'
  )
  .options('r',
    alias     : 'root'
    default   : path.join(__dirname)
    describe  : 'Application root folder'
  )
  .options('w',
    alias     : 'phantomjs'
    default   : ''
    describe  : 'Link to PhantomJS binary'
  )
  .options('g',
    alias     : 'pdfgen'
    default   : ''
    describe  : 'Binary that converts a HTML+CSS file into a PDF'
  )
  .options('x',
    alias     : 'debug-user'
    boolean   : true
    describe  : 'Set this flag if you do not want to have to authenticate'
  )
  .options('test',
    boolean   : true
    describe  : 'Set server to work with the rspec integration tests'
  )
  .argv

# If h/help is set print the generated help message and exit.
if argv.h
  optimist.showHelp()
  process.exit()

server(argv)
