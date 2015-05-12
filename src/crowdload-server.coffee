### 
# Crowdload orchestrating server

###

'use strict'


Fs           = require 'fs'
FsExtra      = require 'fs-extra'
Async        = require 'async'
Express      = require 'express'
RawBody      = require 'raw-body'
Nedb         = require 'nedb'
Moment       = require 'moment'
Crypto       = require 'crypto'
UUID         = require 'uuid'
Multiparty    = require 'multiparty'
Winston      = require 'winston'
ChildProcess = require 'child_process'
Request      = require 'superagent'
config       = require __dirname + '/../config.json'
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
	files: new Nedb(filename: "#{__dirname}/../crowdload.nedb", autoload: true)
}

###
# Port for the application
###
PORT = 2000

###
# BASE_URL
###
BASE_URL = config.BASE_URL

###
# Directory to store the files in
###
SAVE_DIR = "#{__dirname}/../files-retrieved"
err = FsExtra.mkdirsSync SAVE_DIR
if err
	LOG.error "Couldn't create save file"
	LOG.error err
	process.exit 10

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
#

_getRemote = (req) ->
	# req.connection.remoteAddress
	return req.header 'X-Forwarded-For'

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
		meta = meta.replace '{{{CURRENT_DATE}}}', Moment().format('YYYYMMDDHHmmss')
		meta = meta.replace /{{{BASE_URL}}}/g, BASE_URL
		return cb meta

_getUserScriptCode = (cb) ->
	ChildProcess.exec 'coffee -pbc templates/Crowdload.user.coffee', (err, script) ->
		script = script.replace('{{{BASE_URL}}}', BASE_URL)
		return cb script

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
	_getUserScriptCode (script) ->
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
# Reset a URI
###
app.post '/queue/reset', (req, res, next) ->
	uri = req.query.uri
	md5 = req.query.md5
	full = req.query.full in ['1', 'true']

	query = null
	if not uri and not md5
		res.status 400
		return res.send "Must set either 'uri' or 'md5' param for /queue/reset"
	else if uri
		query = {_id: uri}
	else if md5
		query = {'entries.md5': md5}

	patch = {'$set': {'status': STATUS.QUEUED}}
	if full
		LOG.warn "FULLY resetting documents matching #{query}"
		patch['$unset'] = {'entries': 1}
	LOG.warn "Resetting documents matching #{query}"
	DB.files.update query, patch, {multi: true}, (err, nrUpdated) ->
		if err
			return res.send err
		else
			return res.send "Updated #{nrUpdated} documents"

###
# Dequeue a URI
###
app.post '/queue/pop', (req, res, next) ->
	userName = req.query.userName
	if not userName
		return next "Must set 'userName' URI query parameter for /queue/pop"
	_find_next_link = () ->
			if @status is STATUS.QUEUED and not @entries
				return true
			else if @status in [STATUS.QUEUED, STATUS.FAILED] and @entries and @entries.length > 0
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
			LOG.debug "Giving URI <#{doc._id}> to user '#{userName}' [#{_getRemote(req)}]"
			patch = '$set': {status: STATUS.ACCEPTED}
			DB.files.update {_id: doc._id}, patch, (err) ->
				if err
					res.status 400
					next err
				else
					res.status 200
					res.send doc._id

###
# History
###

app.get '/history', (req, res, next) ->
	DB.files.find({'entries':{'$exists': 1}}).sort({'entries.date': -1}).limit(10).exec (err, docs) ->
		console.log docs
		res.send docs

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
	if not files.file or not files.file.length
		problems.push 'No file payload'
	return problems

_parseEntry = (req, fields, files) ->
	obj = {}
	for fieldName in ['user', 'date', 'status']
		obj[fieldName] = fields[fieldName][0]
	obj.date = new Date(obj.date)
	obj.status = parseInt fields.status
	obj.ip = _getRemote(req)
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
			form = new Multiparty.Form()
			form.parse req, (err, fields, files) ->
				if err
					LOG.error "Unparseable form in request"
					return next "Unparseable form in request"
				problems = _validateForm(fields, files)
				if problems.length > 0
					return DB.files.update {_id: uri}, {'$set': {'status': STATUS.FAILED}}, (err, nrUpdated) ->
						res.status 400
						res.end()

				entry = _parseEntry(req, fields, files)

				# Calculate MD5, store file in SAVE_DIR
				if entry.status isnt 200 or not files.file[0]
					DB.files.update {_id: uri}, {'$set': {'status': STATUS.FAILED}}, (err, nrUpdated) ->
						res.status 400
						res.end()
				hash = Crypto.createHash 'md5'
				inFileName = files.file[0].path

				Fs.readFile inFileName, (err, data) ->
					if err
						LOG.error "Error retrieving temp file #{inFileName}. HD Full?"
						LOG.error err
						res.status 500
						return next err
					hash.update(data)
					md5 = hash.digest('hex')
					entry.md5 = md5

					outFileName = "#{SAVE_DIR}/#{md5}"
					Fs.writeFile outFileName, data, (err) ->
						if err
							LOG.error "Error writing file #{outFileName}."
							LOG.error err
							res.status 500
							return next err

						LOG.debug "About to store entry", entry
						patch = {'$set': {}}
						patch['$push'] = {entries: entry}
						patch['$set'].status = STATUS.FINISHED
						DB.files.update {_id: uri}, patch, (err, nrUpdated) ->
							if err
								res.status 400
								res.end()
							else
								res.status 200
								res.end()


###
# Run the server
###
LOG.info "Starting Server on port #{PORT}"
app.listen PORT

# ALT: test/test.coffee
