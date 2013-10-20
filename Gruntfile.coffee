module.exports = (grunt) ->

  fs = require('fs')
  pkg = require('./package.json')

  # Project configuration.
  grunt.initConfig
    pkg: pkg

    # Release a new version and push upstream
    bump:
      options:
        commit: true
        push: true
        pushTo: ''
        # Files to bump the version number of
        files: ['package.json', 'bower.json']


  # Dependencies
  # ============
  for name of pkg.dependencies when name.substring(0, 6) is 'grunt-'
    grunt.loadNpmTasks(name)
  for name of pkg.devDependencies when name.substring(0, 6) is 'grunt-'
    if grunt.file.exists("./node_modules/#{name}")
      grunt.loadNpmTasks(name)

  # Tasks
  # =====

  # Dist
  # -----
  grunt.registerTask 'release', [
    'bump'
  ]

  grunt.registerTask 'release-minor', [
    'bump:minor'
  ]

  # Default
  # -----
  grunt.registerTask 'default', [
  ]
