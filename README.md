# What is this?

Generate PDF from an EPUB repository as a Commit Hook!
Whenever your book in GitHub changes, the PDF will automatically regenerate.

# OK, so what now?

Check out the [demo website](http://pdf.oerpub.org) to see this code in action.
You can see recently built PDFs and trigger new ones to be generated.

# Make my Book!

You will need to have a repository that is an unzipped EPUB. Some examples are:

1. http://github.com/philschatz/minimal-book
2. Repositories in the [oerpub organization](https://github.com/oerpub) that end in "-book"

Add a GitHub Service Hook to generate PDFs on Commit:

1. Go to https://github.com/REPO_USER/REPO_NAME/settings/hooks (be sure to replace `REPO_USER` and `REPO_NAME` with appropriate names for your book repository)
2. Click "WebHook URLs"
3. Enter http://pdf.oerpub.org as the URL
4. Click "Update Settings"
5. Click "Test Hook"

# Ooh, let me see!

To download the dependencies:

    npm install .

Install your favorite HTML to PDF tool. Some examples:

- [wkhtmltopdf](https://code.google.com/p/wkhtmltopdf/)
- [princexml](http://princexml.com)

Install http://www.mongodb.org/downloads

And, to start it up:

    mongod &
    node bin/server.js &
    node bin/slave.js --pdfgen ${PATH_TO_PDFGEN_BINARY}

Then, point your browser to the website at [http://localhost:3001](http://localhost:3001)

Submit a job by going to [http://localhost:3001/philschatz/minimal-book/](http://localhost:3001/philschatz/minimal-book/) and clicking the "Rebuild" button.

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
- `[ ]` support Build History
