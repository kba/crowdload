'use strict'

###
# Client application states
# State transitions
#
# STOPPED -> IDLE -> DOWNLOADING -> UPLOADING -> FINISHED_UPLOADING --.
#              ^                                                      |
#              '------------------------------------------------------'
# or
#
# ERROR
#
###
STATE = {'STOPPED', 'IDLE', 'DOWNLOADING', 'UPLOADING', 'FINISHED_UPLOADING', 'ERROR'}

###
# Base URL of the orchestrator
###
CROWDLOAD_BASE = 'http://infolis.gesis.org/crowdload'

###
# How many milliseconds to wait between requests
###
INTERVAL_WAIT_MS = 30 * 1000

###
# Update the application every 50ms
###
INTERVAL_CLIENT_UPDATE_MS = 50

###
# jQuery-like selector
###
$ = Zepto

###
# helper functions
###
humanReadableSize = (bytes) ->
	units = "B kB MB GB".split ' '
	unit = 0
	for idx in [0 ... units.length]
		if bytes < 1024 or idx is units.length - 1
			return "#{bytes.toFixed(2)} #{units[idx]}"
		bytes /= 1024


humanReadableSeconds = (seconds) ->
	(seconds / 1000.0).toFixed(2) + ' s'

randomDelay = () ->
	Math.round Math.random() * (40 * 1000)

###
# Store data locally in browser
###
class GM_Storage
	@incFilesCount : -> return localStorage.setItem 'nr_Files', GM_Storage.getFilesCount() + 1
	@incBytes      : (d) -> return localStorage.setItem 'bytes', GM_Storage.getBytes() + d
	@getBytes      : -> return parseInt(localStorage.getItem('bytes') or 0)
	@getFilesCount : -> return parseInt(localStorage.getItem('nr_Files') or 0)
	@getLastURI    : -> return localStorage.getItem 'last_uri' or '--'
	@setLastURI    : (uri) -> return localStorage.setItem 'last_uri', uri
	@getUserName   : -> return localStorage.getItem('userName')
	@setUserName   : (name) -> return localStorage.setItem('userName', name)
	@clear         : -> localStorage.clear()

###
# Update the user interface, draw global stats, local stats, timeToNext, app state
###
class UI

	constructor : (app) ->
		self = this
		self.app = app
		# Click handlers
		$('.btn.start').click () -> self.app.start()
		$('.btn.stop').click () -> self.app.stop()
		$('.btn.refresh-stats').click () -> self.app.updateServerStats()
		$('.btn.clear-history').click () -> self.app.updateServerStats()
		$('.btn.clear-client-stats').click () -> 
			GM_Storage.clear()
			self.update()
		@reset()
	
	updateServerStats : (cb) ->
		for k,v of @app.serverStats
			$('.server-status .status-' + k).html v

		$('#leaderboard tbody').empty()
		sortedBoard = ([k,v] for k,v of @app.leaderboard).sort (a,b) -> b[1].files - a[1].files
		for row in sortedBoard
			$('#leaderboard tbody').append """
			<tr>
				<th>#{row[0]}</th>
				<td>#{row[1].files}</td>
			</tr>
			"""

		$('#history tbody').empty()
		for entry in @app.history
			$('#history tbody').append """
				<tr>
					<td>
						<a href='#{entry._id}'>#{entry._id}</a>
					</td>
					<td class='alert-#{if entry.status is 'FINISHED' then 'success' else 'danger'}'>
						#{entry.status}
					</td>
					<td>
						#{entry.entries[0].user}
					</td>
					<td>
						#{entry.entries[0].date}
					</td>
				</tr>
			"""

	update : ->
		if @app.state == STATE.STOPPED
			$('.btn.stop').hide()
			$('.btn.start').show()
		else
			$('.btn.stop').show()
			$('.btn.start').hide()
		# Update client stats
		$('.client-user-name').html @getUserName()
		$('.client-time-remaining').html humanReadableSeconds @app.timeToNext
		$('.client-state').html @app.state
		$('.client-files-retrieved').html GM_Storage.getFilesCount()
		$('.client-bytes-retrieved').html humanReadableSize GM_Storage.getBytes()

	###
	# Reset the User Interface, show the parts that are hidden for non-Userscript,
	# draw defaults for all fields
	###
	reset : ->
		$('#no-userscript').hide()
		$('.userscript').show()
		@resetProgress()

	resetProgress : ->
		$('.progress-bar').css 'width', 0
		$('.uri').html '--'
		$('.loaded').html '--'
		$('.bytes').html '--'
		$('.total').html '--'

	setProgress : (which, e) ->
		$("##{which} .loaded").html humanReadableSize(e.loaded)
		$("##{which} .total").html humanReadableSize(e.total)
		progress = 100.0 * e.loaded / e.total
		document.querySelector("##{which} .progress-bar").style.width = progress + '%'

	setLastURI : (uri) ->
		$('.uri').html uri
		GM_Storage.setLastURI uri

	getUserName : () ->
		name = GM_Storage.getUserName()
		if name
			return name
		else
			name = window.prompt('What\'s your name:')
			GM_Storage.setUserName(name)


class App

	constructor : () ->
		self = this
		@ui = new UI(this)
		@timeToNext = -1
		@lastUpdate = new Date() - INTERVAL_CLIENT_UPDATE_MS
		@state = STATE.STOPPED
		@updateServerStats()
		@update()

	changeState : (state) ->
		@state = state
		@ui.update()

	###
	# Request a new URI to down- and upload
	###
	requestURI : (cb) ->
		console.log 'Request a new URI to download'
		GM_xmlhttpRequest
			url: CROWDLOAD_BASE + "/queue/pop?userName=#{GM_Storage.getUserName()}"
			method: 'POST'
			onload: (e) ->
				if e.status == 200
					console.log 'Received new URI: ' + e.response
					cb null, e.response
				else
					# console.log e
					cb "Wrong statuscode [#{e.response}]"
				return
		return

	###
	# Upload a successfully downloaded file
	###
	uploadFile : (uri, form, success, length, cb) ->
		self = this
		console.log 'Uploading PDF ' + uri
		GM_xmlhttpRequest
			url: CROWDLOAD_BASE + '/upload?uri=' + encodeURIComponent(uri)
			method: 'PUT'
			data: form
			upload:
				onprogress: (e) ->
					return self.ui.setProgress 'Upload', e
				onload: (e) ->
					console.log "Finished Uploading #{uri}"
					if (e.status >= 400)
						return cb e.response
					else
						return cb null, e

	downloadFile : (uri, cb) ->
		self = this
		console.log "Downloading PDF #{uri}"
		form = new FormData()
		form.append("user", self.ui.getUserName())
		success = false
		GM_xmlhttpRequest
			url: uri
			method: 'GET'
			onprogress: (e) ->
				return self.ui.setProgress 'Download', e
			onload: (e) ->
				console.log 'Finished downloading PDF'
				form.append("date", new Date())
				form.append("status", e.status)
				if e.status == 200
					console.log 'PDF Download successful'
					form.append("file", new Blob([e.response], {type: e.responseHeaders['Content-Type']}))
					###
					###
					# form.append("file", [e.responseText])
					success = true
				else
					form.append("reason", e.responseText)
				return cb null, form, success, e.response.length

	###
	#
	###
	update : () ->
		now = new Date()
		elapsed = now - @lastUpdate

		# Stop the application on error
		if @state is STATE.ERROR
			clearInterval @updateIntervalID
			throw new Error("ERROR")
			window.alert('ERROR')

		# Do nothing if stopped
		if @state != STATE.STOPPED
			# Count down while idle and download when appropriate
			if @state == STATE.IDLE
				if @timeToNext > 0
					@timeToNext -= elapsed
					if @timeToNext < 0 then @timeToNext = 0
				if @timeToNext == 0
					@timeToNext = -1
					@downloadNext()
			else if @state == STATE.FINISHED_UPLOADING
				@timeToNext = INTERVAL_WAIT_MS + randomDelay()
				@changeState STATE.IDLE
				@ui.resetProgress()

		@lastUpdate = now
		@ui.update()

	###
	# Update server stats
	###
	updateServerStats : (cb) ->
		self = this
		GM_xmlhttpRequest
			url: CROWDLOAD_BASE + '/queue'
			method: 'GET'
			onload: (e) ->
				self.serverStats = JSON.parse(e.response)
				GM_xmlhttpRequest
					url: CROWDLOAD_BASE + "/leaderboard"
					method: 'GET'
					onload: (e2) ->
						self.leaderboard = JSON.parse(e2.response)
						GM_xmlhttpRequest
							url: CROWDLOAD_BASE + "/history"
							method: 'GET'
							onload: (e3) ->
								self.history = JSON.parse e3.response
								self.ui.updateServerStats()

	start : ->
		@changeState STATE.IDLE
		@updateIntervalID = setInterval this.update.bind(this), INTERVAL_CLIENT_UPDATE_MS
		@timeToNext = 0
		@update()

	stop : ->
		@changeState STATE.STOPPED
		@timeToNext = -1
		@update()

	_throwError : (msg, err) ->
		console.log msg
		console.log err
		window.alert "#{msg}: #{err}"
		@changeState STATE.ERROR

	###
	# Request a URI, download it
	###
	downloadNext : ->
		self = this
		self.changeState STATE.DOWNLOADING
		@requestURI (err, uri) ->
			return self._throwError("No URI retrieved:", err) if err
			self.ui.setLastURI uri
			self.downloadFile uri, (err, form, success, length) ->
				self.changeState STATE.UPLOADING
				self.uploadFile uri, form, success, length, (err) ->
					if err
						console.log err
						alert 'Error uploading PDF ' + uri
						self.changeState STATE.ERROR
					else
						if success
							GM_Storage.incFilesCount()
							GM_Storage.incBytes length
						self.changeState STATE.FINISHED_UPLOADING
						self.updateServerStats()
					return
				return
			return
		return

###
# Start the app
###

new App()
