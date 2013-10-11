
_             = require('underscore')
Q             = require('q')
jsdom         = require('jsdom')
URI           = require('URIjs')
jQueryFactory = require('./jquery-module')


module.exports = class Assembler
  readFile: (filePath) -> throw new Error('BUG: Subclass must implement this method')

  log: (msg) -> throw new Error('BUG: Subclass must implement this method')


  # Given an HTML (or XML) string, return a Promise of a jQuery object
  _buildJQuery: (uri, xml) ->
    deferred = Q.defer()
    #jsdom.env html, [ "file://#{JQUERY_PATH}" ], (err, window) ->
    jsdom.env
      html: xml
      # src: [ "//<![CDATA[\n#{JQUERY_CODE}\n//]]>" ]
      # scripts: [ "http://code.jquery.com/jquery.js" ] # [ "file://#{JQUERY_PATH}" ]
      # scripts: [ "#{argv.u}/jquery.js" ]
      done: (err, window) =>
        return deferred.reject(err) if err

        # Attach jQuery to the window
        jQueryFactory(window)

        if window.jQuery
          @log({msg: 'jQuery built for file', path: uri.toString()})
          deferred.resolve(window.jQuery)
        else
          deferred.reject('Problem loading jQuery...')
    return deferred.promise

  _readUri: (uri) -> return @readFile(uri.toString())

  # Concatenate all the HTML files in an EPUB together
  # returns a promise that resolves to a buffer
  assemble: () ->

    # 1. Read the META-INF/container.xml file
    # 2. Read the first OPF file
    # 3. Read the ToC Navigation file (relative to the OPF file)
    # 4. Read each HTML file linked to from the ToC file (relative to the ToC file)

    # Check that a mimetype file exists
    return @log('Checking if mimetype file exists')
    .then () =>
      return @_readUri(new URI('mimetype'))
      .then (mimeTypeStr) =>
        # Fail if the mimetype file is invalid
        if 'application/epub+zip' != mimeTypeStr.toString().trim()
          return Q.defer().reject('Invalid mimetype file')

        # 1. Read the META-INF/container.xml file
        containerUri = new URI('META-INF/container.xml')
        return @_readUri(containerUri)
        .then (containerXml) =>
          return @_buildJQuery(containerUri, containerXml)
          .then ($) =>
            # 2. Read the first OPF file
            $opf = $('container > rootfiles > rootfile[media-type="application/oebps-package+xml"]').first()
            opfPath = $opf.attr('full-path')
            opfUri = new URI(opfPath)
            return @_readUri(opfUri)
            .then (opfXml) =>
              # Find the absolute path to the ToC navigation file
              return @_buildJQuery(opfUri, opfXml)
              .then ($) =>
                $navItem = $('package > manifest > item[properties^="nav"]')
                navPath = $navItem.attr('href')

                navUri = new URI(navPath)
                # Make sure navUri is absolute because it is used later to load HTML files
                navUri = navUri.absoluteTo(opfUri)
                return @_buildFromToc(navUri)

  # Given a ToC Navigation HTML file generate a single large HTML file
  _buildFromToc: (navUri) ->
    allHtmlFileOrder = []
    allHtml = {}

    # 3. Read the ToC Navigation file (relative to the OPF file)
    return @log('Reading ToC Navigation file')
    .then () =>
      return @_readUri(navUri)
      .then (navHtml) =>
        return @_buildJQuery(navUri, navHtml)
        .then ($) =>
          # 4. Read each HTML file linked to from the ToC file (relative to the ToC file)
          $toc = $('nav')

          anchorPromises = _.map $toc.find('a'), (a) =>
            $a = $(a)
            href = $a.attr('href')

            fileUri = new URI(href)
            fileUri = fileUri.absoluteTo(navUri)

            # Remember the order of files so they can be concatenated again
            allHtmlFileOrder.push(fileUri.toString())

            return @_readUri(fileUri)
            .then (html) =>
              return @_buildJQuery(fileUri, html)
              .then ($) =>
                allHtml[fileUri.toString()] = $('body')[0].innerHTML

          # Concatenate all the HTML once they have all been parsed
          return Q.all(anchorPromises)
          .then () =>
            return @log({msg:'Combining HTML files', count:allHtmlFileOrder.length})
            .then () =>

              htmls = []
              for key in allHtmlFileOrder
                htmls.push(allHtml[key])
              htmlFragment = htmls.join('\n')
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

              @log({msg:'Combined HTML files', size:html.length})
              .then () =>
              return html



# Example Assembler
# -----------------
#    class SimpleAssembler extends EpubAssembler
#      constructor: (@rootPath) ->
#
#      log: (msg) ->
#        console.log(msg)
#        return Q.delay(1)
#
#      readFile: (filePath) ->
#        return @log({msg:'Reading file', path:filePath})
#        .then () =>
#          return fsReadFile(path.join(@rootPath, decodeURIComponent(filePath)))
