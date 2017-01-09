// ==UserScript==
// @name        Crowdload Userscript
// @namespace   http://infolis.github.io
// @description browser part of crowdload
// @require     https://cdnjs.cloudflare.com/ajax/libs/zepto/1.1.4/zepto.js
// @include     http://www-test.bib.uni-mannheim.de/infolis/*
// @version     2
// @grant       GM_xmlhttpRequest
// @grant       GM_getValue
// @grant       GM_setValue
// @grant       GM_log
// ==/UserScript==

"use strict";
var $ = Zepto

// Base URL of the orchestrator
var CROWDLOAD_BASE = "http://www-test.bib.uni-mannheim.de/infolis/crowdload";

// How many seconds to wait between requests
var sleepTime = 30;

// STOPPED -> IDLE -> DOWNLOADING -> UPLOADING -> IDLE
var state = 'STOPPED'
var downloadIntervalID = null;
var timer = null;
var timeToNext = -1;

function incFilesCounter() {
  var nrFiles = GM_getValue("nr_Files") || 0;
  GM_setValue('nr_Files', nrFiles + 1);
}

function incBytes(d) {
  var bytes = GM_getValue("bytes") || 0;
  GM_setValue('bytes', bytes + d);
}


function _requestNewURI(cb) {
  console.log("Request a new URI to download");
  GM_xmlhttpRequest({
    url: CROWDLOAD_BASE + "/queue/pop",
    method: "POST",
    onload: function(e) {
      if (e.status === 200) {
        console.log("Received new URI: " + e.response);
        cb(null, e.response);
      } else {
        console.log(e);
        cb("Wrong statuscode");
      }
    }
  });
}

function humanReadableSize(bytes) {
  return (bytes / 1024.0).toFixed(2) + " kB";
}

function _uploadPDF(pdfURL, pdfData, cb) {
  console.log("Uploading PDF " + pdfURL);
  GM_xmlhttpRequest({
    url: CROWDLOAD_BASE + "/upload?uri=" + encodeURIComponent(pdfURL),
    method: "PUT",
    data: pdfData,
    upload: {
      onprogress: function(e) {
        var progress = 100.0 * e.loaded / e.total;
        $("#upload .bytesUploaded").html(humanReadableSize(e.loaded));
        $("#upload .totalSize").html(humanReadableSize(e.total));
        document.querySelector("#upload .progress-bar").style.width = progress + "%";
      },
    },
    onload: function(e) {
      console.log("Finished Uploading");
      cb(null, e);
    }
  });
}

function _downloadPDF(pdfURL, cb) {
  console.log("Downloading PDF");
  GM_xmlhttpRequest({
    url: pdfURL,
    method: "GET",
    onload: function(e) {
      console.log("Finished downloading PDF");
      console.log(e);
      if (e.status === 200) {
        console.log("PDF Download successful");
        cb(null, e.response);
      } else {
        console.log(e);
        window.alert("Error Downloading PDF");
      }
    },
    onprogress: function(e) {
      var progress = 100.0 * e.loaded / e.total;
      $("#download .bytesDownloaded").html(humanReadableSize(e.loaded));
      $("#download .totalSize").html(humanReadableSize(e.total));
      document.querySelector("#download .progress-bar").style.width = progress + "%";
    }
  });
}

function render() {

  // Update server stats
  GM_xmlhttpRequest({
    url: CROWDLOAD_BASE + "/queue",
    method: "GET",
    onload: function(e) {
      var data = JSON.parse(e.response);
      for (var k in data) {
        $(".server-status .status-" + k).html(data[k])
      }
    },
  });

  // Update client stats
  $(".client-time-remaining").html(timeToNext);
  $(".client-state").html(state);
  $(".client-files-retrieved").html(GM_getValue('nr_Files'));
  $(".client-bytes-retrieved").html(GM_getValue('bytes'));

  // Do nothing if stopped
  if (state !== 'STOPPED') {
    // Count down while idle and download when appropriate
    if (state === 'IDLE') {
      if (timeToNext > 0) {
        timeToNext -= 1;
      }
      if (timeToNext === 0) {
        timeToNext = -1;
        downloadNext();
      }
    // Reset timeToNext while Downloading
    } else if (state === 'DOWNLOADING') {
      timeToNext = sleepTime;
    }
  }
}

function resetUI() { 
  $("#no-userscript").hide();
  $(".userscript").show();
  if (state === 'STOPPED') {
    $(".btn.stop").hide();
    $(".btn.start").show();
  } else {
    $(".btn.stop").show();
    $(".btn.start").hide();
  }

  $(".uri").html("--");
  $(".bytesDownloaded").html("--");
  $(".bytesUploaded").html("--");
  $(".bytesTotal").html("--");
  $(".progress-bar").css("width", 0);

}

function start() {
  var userName = window.prompt("Bitte Vornamen angeben:");
  state = 'IDLE';
  resetUI();
  timeToNext = 0;
}

function stop() {
  state = 'STOPPED';
  resetUI();
  timeToNext = -1;
}

function downloadNext() {
  state = 'DOWNLOADING';
  _requestNewURI(function(err, newURI) {
    if (err) {
      console.log(err);
      alert("Error requesting new URI from server. ");
    } else {
      $(".uri").html(newURI);
      _downloadPDF(newURI, function(err, pdfData) {
        if (err) {
          console.log(err);
          alert("Error downloading PDF " + newURI);
        } else {
          _uploadPDF(newURI, pdfData, function(err) {
            console.log('called yay');
            if (err) {
              console.log(err);
              alert("Error uploading PDF " + newURI);
              state = "STOPPED";
            } else {
              incFilesCounter();
              incBytes(pdfData.length);
              state = 'IDLE';
            }
          });
        }
      });
    }
  });
}

resetUI()
// Click handlers
$(".btn.start").click(function() { start(); });
$(".btn.stop").click(function() { stop(); });
setInterval(render, 1000);
// requestNewURI(downloadPDF);

