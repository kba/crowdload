### 
# Crowdload orchestrating server

###

'use strict'

Async      = require 'async'
Express    = require 'express'
BodyParser = require 'body-parser'
SocketIO   = require 'socket.io'
RawBody    = require 'raw-body'
Nedb       = require 'nedb'
MediaTyper = require 'media-typer'

db =  {
	files: new Nedb(filename: './crowdload.nedb', autoload: true)
}

STATUS = {
	'QUEUED'
	'ACCEPTED'
	'FINISHED'
}

app = Express()

app.use (req, res, next) ->
	RawBody req, (err, string) ->
		if (err)
			return next(err)
		req.text = string
		next()

# app.use(BodyParser.json())

app.post '/queue', (req, res, next) ->
	newURI = req.query.uri
	doc = {
		'_id': newURI
		'added': new Date()
		'status': STATUS.QUEUED
	}
	db.files.insert doc, (err) ->
		if err
			res.status 400
			next err
		else
			res.status 201
			res.end()

app.put '/upload', (req, res, next) ->
	uri = req.query.uri
	db.files.find {_id: uri}, (err, doc) ->
		if err
			res.status 400
			next err
		else if not doc
			res.status 404
			next err
		else
			base64 = req.text.toString('base64')
			patch = {
				'$set': {
					base64: base64
					status: STATUS.FINISHED
				}
			}
			db.files.update {_id: uri}, patch, (err, nrUpdated) ->
				if err
					res.status 400
					res.end()
				else
					res.status 200
					console.log nrUpdated
					res.end()

app.get '/queue', (req, res, next) ->
	newURI = req.query.uri
	db.files.find {}, (err, docs) ->
		if err
			res.status 400
			next err
		else
			res.status 200
			res.send docs

app.get '/queue/pop', (req, res, next) ->
	db.files.findOne {status: STATUS.QUEUED}, (err, doc) ->
		if err
			res.status 400
			next err
		else if not doc
			res.status 404
			next err
		else
			patch = {
				'$set':{
					status:STATUS.ACCEPTED
				}
			}
			db.files.update {_id: doc._id}, patch, (err, nrUpdated) ->
				if err
					res.status 400
					next err
				else
					res.status 200
					res.send doc._id

app.listen 2000

# ALT: test/test.coffee
