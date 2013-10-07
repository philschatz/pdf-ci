# **defaultargs.coffee** when called with on the argv object this
# module will create reasonable defaults for options not supplied.
path = require 'path'

module.exports = (argv) ->
  argv or= {}
  argv.o or= ''
  argv.p or= 3001
  argv.r or= path.join(__dirname)
  argv.c or= path.join(argv.r, 'client')
  argv.u or= 'http://localhost' + (':' + argv.p) unless argv.p is 80
  argv.g or= path.join(argv.r, 'pdfgen')
  argv
