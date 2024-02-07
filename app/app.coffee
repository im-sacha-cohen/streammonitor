require "coffeescript"
net = require "net"
express = require "express"
http = require "http"
child_process = require "child_process"
request = require("request")

# prepare variables
offlineSince = new Date()
onlineSince = null
silenceSince = new Date()
pid = null
child = null

# Retrieve config from environment
streamUrl = process.env.STREAM_URL
silenceThreshold = process.env.SILENCE_THRESHOLD or -20
httpPort = process.env.HTTP_PORT or 8000
radioSlug = process.env.RADIO_SLUG
apiUrl = process.env.API_URL
#checkInterval = process.env.CHECK_INTERVAL or 2000
checkInterval = 1000
lastLoopExecution = new Date()

# Config check
unless streamUrl
  console.log "Error: STREAM_URL must be set in environment"
  process.exit()
  
# Convert silenceThreshold to absolute 16-bit value
silenceThresholdLinear = 32768 * Math.exp((silenceThreshold * Math.log(10))/20)
silenceDuration = 0
# function that is periodically called to connect to the stream
checkChildProcess = () =>
  # process still runing? -> exit
  return if pid
  
  args = "curl -s " + streamUrl + " | lame --quiet --mp3input --decode -t -"
  
  child = child_process.spawn "/bin/sh", ["-c", args]
  child.on "error", (err) ->
    console.log "Error starting process: %s", err
    onlineSince = null
    offlineSince = new Date()
    pid = 0

  child.on "exit", (code) ->
    console.log "Process exited with code %d", code
    onlineSince = null
    offlineSince = new Date()
    pid = 0

  child.stdout.on "data", (data) ->
    currentTimestamp = new Date()
    
    # Vérifier si une seconde s'est écoulée depuis la dernière exécution de la boucle
    

    for i in [0..data.length/2-1]
      sample = Math.abs(data.readInt16LE i*2)
      now = new Date()
      
      if currentTimestamp - lastLoopExecution >= 500

        if sample > silenceThresholdLinear
          if silenceDuration > 0
            console.log "Stream back, log FINISHED"
            silenceDuration = 0
            url = apiUrl + "/stream-break/log/" + radioSlug
            request.get(url)

          silenceSince = new Date()
          console.log "Stream OK %d", silenceDuration

        else if sample == 0
          silenceDuration = Math.floor((now - silenceSince.getTime()) / 1000)

          if silenceDuration > 0
            console.log "Silence since %d seconds ", silenceDuration

            url = apiUrl + "/stream-break/log/" + radioSlug

            request.get(url, (error, response, body) ->
              if error
                #console.error("Erreur lors de l'exécution de la requête:", error)
              else
                #console.log("Statut de la réponse:", response.statusCode)
                #console.log("Réponse du serveur:", body)
            )

        # Mettre à jour le moment de la dernière exécution de la boucle
        lastLoopExecution = new Date()
        
          
  
  pid = child.pid
  offlineSince = null
  onlineSince = new Date()
  
  console.log "Process started, pid=%d", pid
  
  
# Returns the current status as object
getStatus = () ->
  now = new Date()
  result =
    url: streamUrl
    silenceThreshold: silenceThreshold
    status: if onlineSince then "OK" else "ERROR"
    now: now
    onlinceSince: onlineSince
    onlineDuration: if onlineSince then Math.floor((now.getTime() - onlineSince.getTime()) / 1000) else 0
    offlinceSince: offlineSince
    offlineDuration: if offlineSince then Math.floor((now.getTime() - offlineSince.getTime()) / 1000) else 0
    silenceSince: silenceSince
    silenceDuration: Math.floor((now.getTime() - silenceSince.getTime()) / 1000)
    

# Create web app
app = express()
app.set "json spaces", 2

# Root document returns entire status as JSON object
app.get "/", (req, res) ->
  res.jsonp getStatus()

# Return single field from the status object
app.get "/value/:key", (req, res) ->
  res.jsonp getStatus()[req.params.key]


# Create web server
server = http.Server(app)
server.listen 8000
console.log "Stream monitor for %s started on port %d", streamUrl, httpPort

# Start periodic check for child process
setInterval(checkChildProcess, checkInterval)