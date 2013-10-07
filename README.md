# What is this?

Generate PDF from an EPUB repository as a Commit Hook!

# Ooh, let me see!

To download the dependencies

    npm install .

Install your favorite HTML to PDF tool. Some examples:

- [wkhtmltopdf](https://code.google.com/p/wkhtmltopdf/)
- [princexml](http://princexml.com)

And, to start it up (all one line)

    node bin/server.js --pdfgen ${PATH_TO_PDFGEN_BINARY}

Then, point your browser to the website at http://localhost:3001/

## "Ok, so what now?"

Submit a job by going to http://localhost:3001/philschatz/minimal-book/ and clicking the "Rebuild" button.
