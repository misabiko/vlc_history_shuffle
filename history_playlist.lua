
local played = {} -- holds all music items form the current playlist
local store = {}	-- holds all music items from the database

-- constant for seconds in one day
local day_in_seconds = 60*60*24

 -- used in playing_changed
 -- the event gets triggered multiple times and we don't want to
 -- set the rating down multiple times
local last_played = ""

-- prefix to all logs
local prefix = "[HShuffle] "

-- path to data file
local data_file = ""

function descriptor()
  return {
    title = "History Shuffle",
    version = "1.0.1", 
    shortdesc = "Shuffle Playlist", 
    description = "Shuffles playlists based on the liking of the songs",
    author = "Stefan Steininger", 
    capabilities = { "playing-listener"}
  }
end

function activate()
	vlc.msg.info(prefix ..  "starting")

	-- init the random generator
	-- not crypto secure, but we have no crypto here :)
	math.randomseed( os.time() )

	path_separator = ""
	if string.find(vlc.config.userdatadir(), "\\") then
		vlc.msg.info(prefix .. "windows machine")
		path_separator = "\\"
	else
		vlc.msg.info(prefix .. "unix machine")
		path_separator = "/"
	end

	data_file = vlc.config.userdatadir() .. path_separator .. "better_playlist_data.csv"
	vlc.msg.info(prefix ..  "using data file " .. data_file)
    
    init_playlist()
    randomize_playlist()
    vlc.playlist.random("off")
end

function deactivate()
	vlc.msg.info(prefix ..  "deactivating.. Bye!")
end

-- -- Helpers -- --

-- loads the database and initializes the played variable with the like ratings
-- increases the rating of a song by the days since it was last updated
-- if there are new songs or changes, it adds them to the database file
function init_playlist( )
	vlc.msg.dbg(prefix .. "initializing playlist")

	-- load playlist items from file
	load_data_file()

	local time = os.time() -- current time for comparison of last played
	local playlist = vlc.playlist.get("playlist",false).children
	local changed = false -- do we have any updates for the db ?

	for i,path in pairs(playlist) do
		-- decode path and remove escaping
		path = path.item:uri()
		path = vlc.strings.decode_uri(path)

		-- check if we have the song in the database
		-- and copy the like else create a new entry
		if store[path] then
			played[path] = store[path].playcount * 0.25 + store[path].skipcount
		else
			played[path] = 0
			store[path] = {playcount=0,skipcount=0,time=time}
			changed = true
		end

		-- increase the rating after some days
		local elapsed_days = os.difftime(time, store[path].time) / day_in_seconds
		elapsed_days = math.floor(elapsed_days)
		if elapsed_days >= 1 then
			store[path].time = store[path].time + elapsed_days*day_in_seconds
			changed = true
		end
	end

	-- save changes
	if changed then
		save_data_file()
	end
end

-- randomizes the playlist based on the ratings
-- higher ratings have a higher chance to be higher up
-- in the playlist
function randomize_playlist( )
	vlc.msg.dbg(prefix ..  "randomizing playlist")
	vlc.playlist.stop() -- stop the current song, takes some time

	-- create a table with all songs
	local queue = {}

	-- add songs to queue
	for path, weight in pairs(played) do
		item = {}
		item["path"] = path
		item["weight"] = weight
		item["inserted"] = false
		table.insert(queue, item)
	end

	-- sort in ascending order
	table.sort(queue, function(a,b) return a['weight'] > b['weight'] end)

	-- clear the playlist before adding items back
	vlc.playlist.clear()
	vlc.playlist.enqueue(queue)
	
	-- wait until the current song stops playing
	-- to start the song at the beginning of the playlist
	while vlc.input.is_playing() do
	end
	vlc.playlist.play()
end

-- finds the last occurence of findString in mainString
-- and returns the index
-- otherwise nil if not found
function find_last(mainString, findString)
    local reversed = string.reverse(mainString)
    local last = string.find(reversed, findString)
    if last == nil then
        return nil
    end
    return #mainString - last + 1
end

-- -- IO operations -- --

-- Loads the data from
function load_data_file()

	-- open file
	local file,err = io.open(data_file, "r")
	store = {}
	if err then
		vlc.msg.warn(prefix .. "data file does not exist, creating...")
		file,err = io.open(data_file, "w");
		if err then
			vlc.msg.err(prefix .. "unable to open data file.. exiting")
			vlc.deactivate()
			return
		end
	else
		-- file successfully opened
		vlc.msg.info(prefix .. "data file successfully opened")
		local count = 0
		for line in file:lines() do
			-- csv layout is `path,playcount,skipcount,timestamp`
			local num_split = find_last(line, ",")
			local date = tonumber(string.sub(line, num_split+1))

			if date == nil then
				vlc.msg.warn(prefix .. "date nil: " .. line .. " => " .. string.sub(line, 1, num_split-1))
			end
			
			-- remove date and last comma
			line = string.sub(line, 0, num_split-1)
			num_split = find_last(line, ",")
			local skipcount = tonumber(string.sub(line, num_split+1))
			line = string.sub(line, 0, num_split-1)
			num_split = find_last(line, ",")
			local playcount = tonumber(string.sub(line, num_split+1))
			local path = string.sub(line, 1, num_split-1)

			if playcount == nil then
				playcount = 0
			end
			if skipcount == nil then
				skipcount = 0
			end

			if date == nil then
				date = os.time()
			end
			if path then
				count = count + 1
				store[path] = {playcount=playcount, skipcount=skipcount, time=date}
			end
		end
		vlc.msg.info(prefix .. "processed " .. count)
	end
	io.close(file)
end

function save_data_file()
	local file,err = io.open(data_file, "w")
	if err then
		vlc.msg.err(prefix .. "Unable to open data file.. exiting")
		vlc.deactivate()
		return
	else
		for path,item in pairs(store) do
			file:write(path..",")
			file:write(store[path].playcount..",")
			file:write(store[path].skipcount..",")
			file:write(store[path].time.."\n")
		end
	end
	io.close(file)
end

-- -- Listeners -- --

-- called when the playing status changes
-- detects if playing items are skipped or ending normally
-- derates the songs accordingly
function playing_changed()

	local item = vlc.input.item()

	local time = vlc.var.get(vlc.object.input(), "time")
	local total = item:duration()
  	local path = vlc.strings.decode_uri(item:uri())

  	if last_played == path then
  		return
  	end

  	-- when time is 0, the song is the new song
	if time > 0 then
		vlc.msg.info(prefix ..  "song ended: " .. item:name())
  		last_played = path

		time = math.floor(time / 1000000)
	  	total = math.floor(total)
	  	
	  	-- when the current time == total time, 
	  	-- then the song ended normally
	  	-- if there is remaining time, the song was skipped
	  	if time < total * 0.9 then
			vlc.msg.info(prefix ..  "skipped song at " .. (math.floor(time/total*10000 + 0.5) / 100) .. "%")
			
			store[path].skipcount = store[path].skipcount + 1
	  	end
	  	
	  	-- save the song in the database with updated time
		store[path].time = os.time()
		store[path].playcount =  store[path].playcount + 1
	  	save_data_file()
	end
end

function meta_changed() end
