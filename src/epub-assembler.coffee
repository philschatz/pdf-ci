_             = require('underscore')
Q             = require('q')
jsdom         = require('jsdom')
URI           = require('URIjs')
jQueryFactory = require('./jquery-module')



# Invalid first characters (see http://www.w3.org/TR/REC-xml/#NT-NameStartChar)
INVALID_FIRST_CHAR = ///[^
    A-Z
    a-z
    _
    \u00C0-\u00D6
    \u00D8-\u00F6
    \u00F8-\u02FF
    \u0370-\u037D
    \u037F-\u1FFF
    \u200C-\u200D
    \u2070-\u218F
    \u2C00-\u2FEF
    \u3001-\uD7FF
    \uF900-\uFDCF
    \uFDF0-\uFFFD
  ]///g

# Invalid subsequent characters (same as before but allow 0-9, hyphen, period, and a few others)
INVALID_SUBSEQUENT_CHARS = ///[^
    \-
    \.
    \u00B7
    \u0300-\u036F
    \u203F-\u2040
    0-9
    # INVALID_FIRST_CHAR follows below
    A-Za-z_\u00C0-\u00D6\u00D8-\u00F6\u00F8-\u02FF\u0370-\u037D\u037F-\u1FFF\u200C-\u200D\u2070-\u218F\u2C00-\u2FEF\u3001-\uD7FF\uF900-\uFDCF\uFDF0-\uFFFD
  ]///g

FILLER_CHAR = '_'


sanitizeHref = (fileUri, id) ->

  str = fileUri.toString()
  str += "-#{id}" if id # Add in the id if pointing to part of a piece of content

  # Sanitize the 1st char and then all characters (1st char is more restrictive)
  str[0] = str[0].replace(INVALID_FIRST_CHAR, FILLER_CHAR)
  str = str.replace(INVALID_SUBSEQUENT_CHARS, FILLER_CHAR)
  return str


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

            # href may contain a `#some-id` in the URL
            [href, elementId] = href.split('#')

            fileUri = new URI(href)
            fileUri = fileUri.absoluteTo(navUri)

            # Remember the order of files so they can be concatenated again
            allHtmlFileOrder.push(fileUri.toString())

            return @_readUri(fileUri)
            .then (html) =>
              return @_buildJQuery(fileUri, html)
              .then ($) =>
                # Rewrite all `<img src="...">` attributes to be relative to the root of the repo
                $('img[src]:not([src^=http])').each (i, img) ->
                  $img = $(img)
                  src = $img.attr('src')
                  src = new URI(src)
                  src = src.absoluteTo(fileUri)
                  $img.attr('src', src.toString())

                # Canonicalize all `id` attributes to contain the path to the HTML file they are in
                $('body *[id]').each (i, el) ->
                  $el = $(el)
                  id = $el.attr('id')

                  # Log and skip if `id` is empty
                  if not id
                    # console.log('Skipping empty id')
                    return

                  $el.attr('id', sanitizeHref(fileUri, id))

                # Canonicalize all `href` attributes to contain the path to the HTML file they are in
                $('a[href]:not([href^=http])').each (i, el) ->
                  $el = $(el)
                  [hrefPath, id] = $el.attr('href').split('#')

                  # Convert the path to be absolute
                  if hrefPath
                    if hrefPath[0] == '/'
                      #console.error('BUG: href starts with slash', fileUri.toString(), hrefPath)
                      hrefPath = hrefPath.slice(1) # Remove the leading slash

                    hrefUri = new URI(hrefPath)
                    hrefUri = hrefUri.absoluteTo(fileUri)
                  else
                    hrefUri = fileUri

                  $el.attr('href', "##{sanitizeHref(hrefUri, id)}")

                # The ToC navigation file may point to a specific element
                if elementId
                  $el = $("##{elementId}")
                  # Log if no element was found
                  console.error('BUG: Could not find id', fileUri.toString(), elementId)
                else
                  $el = $('body')

                allHtml[fileUri.toString()] = $el.html()

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
