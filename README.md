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

Then, point your browser to the website at [http://localhost:3001/]()

## Ok, so what now?

Submit a job by going to [http://localhost:3001/philschatz/minimal-book/]() and clicking the "Rebuild" button.

## Cool! How can I help out? (TODO list)

- `[X]` Trigger from a GET/POST
- `[X]` Concatenate all the HTML files
- `[X]` Generate a PDF
- `[X]` GET the PDF via a URL
- `[X]` Store multiple promises in memory
- `[X]` Store console output and progress
- `[X]` Show status webpage
- `[X]` read EPUB files (META-INF/container.xml, OPF file, ToC HTML)
- `[X]` run `git clone` or `git pull` from command line
- `[X]` write `POST` route for GitHub Service Hooks
- `[X]` distinguish commit from branch or other hooks
- `[X]` add a Status Image to include in GitHub README
- `[X]` store PDFs on file system
- `[X]` store tasks in database (MongoDB)
- `[X]` create slave task
