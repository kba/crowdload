### 
# Crowdload orchestrating server

###

'use strict'


Fs       = require 'fs'
Async    = require 'async'
Express  = require 'express'
RawBody  = require 'raw-body'
Nedb     = require 'nedb'
Moment   = require 'moment'
UUID     = require 'uuid'
{ Form } = require 'multiparty'
Winston  = require 'winston'
ChildProcess = require 'child_process'
# Compression = require 'compression'

LOG = new (Winston.Logger) {
	transports: [
		new Winston.transports.DailyRotateFile {
			filename: 'crowdload.log'
			level: 'silly'
			datePattern: '.yyyy-MM-dd'
			json: on
			prettyPrint: true
			depth: 2
		}
	]
}

###
# The database(s)
###
DB =  {
	files: new Nedb(filename: './crowdload.nedb', autoload: true)
}

###
# Port for the application
###
PORT = 2000

###
# Directory to store the files in
###
SAVE_DIR = './files-retrieved'

###
# The status of the download
###
STATUS = {
	###
	# The default
	###
	'QUEUED'
	###
	# URI has been requested but not uploaded fast enough
	###
	'TIMED_OUT'
	###
	# URI has been requested by a user, don't give it out again for now
	###
	'ACCEPTED'
	###
	# URI has been retrieved successfully
	###
	'FINISHED'
	###
	# URI has been retrieved non-successful
	###
	'FAILED'
}

app = Express()

###
# Middleware that stores the whole request body in `req.text`
###
# app.use (req, res, next) ->
#     RawBody req, (err, string) ->
#         if (err)
#             return next(err)
#         req.text = string
#         next()

app.use(Express.static('public'))
app.set('views', './templates')
app.set('view engine', 'jade')
# app.use(Compression())

# app.use(BodyParser.json())

###
==========~~~~~~~---- --- -- -  -   -    -

 web interface

==========~~~~~~~---- --- -- -  -   -    -
###

app.get '/', (req, res, next) ->
		res.render 'index', {
			statuses: Object.keys(STATUS)
		}

_getUserScriptMeta = (cb) ->
	Fs.readFile 'templates/Crowdload.meta.js', {encoding:'utf-8'}, (err, meta) ->
		meta = meta.replace 'CURRENT_DATE', Moment().format('YYYYMMDDhhmmss')
		meta = meta.replace /BASE_URL/g, 'http://www-test.bib.uni-mannheim.de/infolis/crowdload'
		meta = meta.replace /^/g, '// '
		meta = meta.replace /\n/g, '\n// '
		return cb meta

###
# User script metadata
###
app.get '/Crowdload.meta.js', (req, res, next) ->
	_getUserScriptMeta (meta) ->
		res.send meta
###
# User script source code
###
app.get '/Crowdload.user.js', (req, res, next) ->
	# childprocess spawnsync
	ChildProcess.exec 'coffee -pbc templates/Crowdload.user.coffee', (err, script) ->
		_getUserScriptMeta (meta) ->
			res.header 'Content-Type', 'text/javascript'
			res.send meta + '\n' + script

###
==========~~~~~~~---- --- -- -  -   -    -

 api

==========~~~~~~~---- --- -- -  -   -    -
###

###
# Add a URI to the queue
###
app.post '/queue', (req, res, next) ->
	uri = req.query.uri
	if not uri
		res.status 400
		return res.send "Must provide 'uri' query parameter"
	doc = {
		'_id': uri
		'added': new Date()
		'status': STATUS.QUEUED
	}
	DB.files.insert doc, (err) ->
		if err
			if err.errorType is 'uniqueViolated'
				return next "URI #{uri} already in queue"
			return next err
		else
			res.status 201
			LOG.debug "Queued uri <#{uri}>"
			return res.send "Queued uri #{uri}"

###
# Dequeue a URI
###
app.post '/queue/pop', (req, res, next) ->
	userName = req.query.userName
	if not userName
		return next "Must set 'userName' URI query parameter for /queue/pop"
	_find_next_link = () ->
			if @status is STATUS.QUEUED
				return true
			if @status is STATUS.FAILED and @entries and @entries.length > 0
				for entry in @entries
					if entry.user isnt userName
						return true
			return false
	DB.files.find {'$where': _find_next_link}, (err, docs) ->
		doc = docs[Math.floor(Math.random()*docs.length)]
		if err
			res.status 400
			LOG.error err
			next err
		else if not doc
			res.status 404
			res.send 'No more URIs to fetch (for you)'
		else
			LOG.debug "Giving URI <#{doc._id}> to user '#{userName}' [#{req.connection.remoteAddress}]"
			patch = '$set': {status: STATUS.ACCEPTED}
			DB.files.update {_id: doc._id}, patch, (err) ->
				if err
					res.status 400
					next err
				else
					res.status 200
					res.send doc._id


###
# Get leaderboard :)
###

app.get '/leaderboard', (req, res, next) ->
	userNames = {}
	DB.files.find {status:STATUS.FINISHED, 'entries.user':{'$exists':1}}, {entries:1, size:1}, (err, docs) ->
		if err
			console.log err
			return next err
		for doc in docs
			for entry in doc.entries
				if entry.status is 200
					userNames[entry.user] or= { files: 0, bytes: 0 }
					userNames[entry.user].files += 1
					userNames[entry.user].bytes += entry.size
		return res.send userNames
		


###
# Get statistics about the queue
###
app.get '/queue', (req, res, next) ->
	counts = {}
	Async.each Object.keys(STATUS), (status, cb) ->
		DB.files.count {status: status}, (err, count) ->
			if err
				LOG.error err
			counts[status] = count
			cb()
	, (err) -> 
		res.send counts

_validateForm = (fields, files) ->
	problems = []
	for req in ['user', 'date', 'status']
		if req not of fields or fields[req].length == 0
			problems.push "Missing required '#{req}' form field"
	if fields.status and parseInt(fields.status[0]) >= 400
			for req in ['reason']
				if req not of fields
					problems.push "Missing depending required '#{req}' form field"
	return problems

_parseEntry = (req, fields, files) ->
	obj = {}
	for fieldName in ['user', 'date', 'status']
		obj[fieldName] = fields[fieldName][0]
	obj.date = new Date(obj.date)
	obj.status = parseInt fields.status
	obj.ip = req.connection.remoteAddress
	obj.size = files.file[0].size
	return obj

###
# Upload the contents of a URI
###
app.put '/upload', (req, res, next) ->
	uri = req.query.uri
	if not uri
		res.status 400
		return res.send "Must provide 'uri' query parameter"
	DB.files.findOne {_id: uri}, (err, doc) ->
		if err
			res.status 400
			LOG.error err
			next err
		else if not doc
			res.status 404
			next "Unknown URI <#{uri}> ."
		else
			form = new Form()
			form.parse req, (err, fields, files) ->
				if err
					LOG.error "Unparseable form in request"
					return next "Unparseable form in request"
				problems = _validateForm(fields, files)
				if problems.length > 0
					res.status 400
					return next problems
				entry = _parseEntry(req, fields, files)
				patch = {'$set': {}}
				patch['$push'] = {entries: entry}
				patch['$set'].status = if entry.status == 200 then STATUS.FINISHED else STATUS.FAILED
				console.log files
				LOG.debug "About to store entry", entry
				DB.files.update {_id: uri}, patch, (err, nrUpdated) ->
					if err
						res.status 400
						res.end()
					else
						res.status 200
						console.log nrUpdated
						res.end()

###
# Run the server
###
LOG.info "Starting Server on port #{PORT}"
app.listen PORT

# ALT: test/test.coffee
