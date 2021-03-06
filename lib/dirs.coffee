dir         = require 'node-dir'
fs          = require 'fs-extra'
async       = require 'async'
colors      = require 'colors'
prompt      = require 'prompt'
Database    = require './db'
Config      = require './config'
_           = require 'lodash'

class Dirs extends Database

  addDirs: (callback) ->
    console.log '==> '.cyan.bold + 'search for and add directories to database...'

    # get base paths from db
    @dbBulkPathGet '\'MEDIA\'', (array) =>
      if array.length is 0
        console.log "No paths have been added to mediatidy. Add paths to your media files with",
          "\"mediatidy paths-update\"".red
      else
        # get files asynchronously for each 'MEDIA' path
        async.eachSeries array, ((basePath, seriesCallback) =>

          fs.exists basePath.path, (exists) =>
            if exists
              console.log basePath.path + ':', 'searching for directories...'

              # get directories for given path
              dir.subdirs basePath.path, (err, dirs) =>
                throw err if err

                @dbBulkDirsAdd dirs, (result) ->
                  console.log basePath.path + ':', result, 'directories...'
                  seriesCallback()
            else
              console.log basePath.path, 'could not be found. Consider updating media dirs...'
              seriesCallback()
        ), (err) ->
          if err
            console.log "Something broke when looking for directories...", err
          else
            callback()

  checkDirExists: (array, callback) ->
    # check that each directory path in database exists in the file system
    missingDirs = []
    arrayLength = array.length

    dirExist = (iteration) ->
      fs.exists array[iteration].path, (exists) ->
        if exists is false
          console.log 'MISSING DIR:'.yellow, array[iteration].path
          missingDirs.push array[iteration].path
        if arrayLength is iteration + 1 and missingDirs.length > 0
          console.log missingDirs.length + ' out of ' + arrayLength + ' dirs removed from database...'
          callback missingDirs
        else if arrayLength is iteration + 1 and missingDirs.length is 0
          console.log 'No dirs needed to be removed from database...'
          callback missingDirs
        else
          dirExist(iteration + 1)
    if arrayLength > 0
      dirExist(0)
    else
      console.log 'No dirs in database to check...'
      callback missingDirs

  getEmptyDirs: (array, callback) ->
    # check that each directory path in database exists in the file system
    emptyDirs = []
    arrayLength = array.length

    dirEmpty = (iteration) ->
      fs.readdir array[iteration].path, (err, files) ->
        if files.length is 0
          emptyDirs.push array[iteration].path
        if arrayLength is iteration + 1 and emptyDirs.length > 0
          callback emptyDirs
        else if arrayLength is iteration + 1 and emptyDirs.length is 0
          callback emptyDirs
        else
          dirEmpty(iteration + 1)
    if arrayLength > 0
      dirEmpty(0)
    else
      console.log 'No dirs in database to check...'
      callback()

  getKeywordMatches: (keywords, dirs, callback) ->
    matches = []
    arrayLength = dirs.length

    if arrayLength > 0
      _.forEach dirs, (dir, iteration) ->
        _.forEach keywords, (keyword) ->
          # Look for string and remove casing
          if dir.path.toUpperCase().indexOf(keyword.string.toUpperCase()) > -1
            if (_.findIndex matches, 'path': dir.path) is -1
              matches.push
                path: dir.path
                keyword: [keyword.string]
            else
              matches[_.findIndex matches, 'path': dir.path].keyword.push keyword.string
      callback matches

    else
      console.log 'No dirs in database to check...'
      callback()

  promptUserKeywordDelete: (match, callback) ->
    console.log "DELETE(?):".yellow, match.path,

    # prompt.message = "mediatidy".yellow
    prompt.delimiter = ": ".green
    prompt.properties =
      yesno:
        default: 'no'
        message: "Delete directory matching " + match.keyword + "?"
        required: true
        warning: "Must respond yes or no"
        validator: /y[es]*|n[o]?/

    # Start the prompt
    prompt.start()

    # get the simple yes or no property
    prompt.get ['yesno'], (err, result) =>
      if result.yesno.match(/yes/i)
        fs.remove match.path, =>
          console.log "DELETED:".red, match.path
          @dbDirDelete '\'' + match.path + '\'', ->
            callback()
      else
        callback()

  deleteUnwantedDirs: (callback) ->
    console.log '==> '.cyan.bold + 'delete unwanted directories by keyword'
    @dbBulkKeywordGet '\'DIR\'', (keywords) =>
      if keywords.length is 0
        console.log "No keywords have been added to mediatidy. Add keywords to remove bad directories with",
          "\"mediatidy add-keywords\"".red
        callback()
      else
        @dbBulkDirsGetAll (dirs) =>
          @getKeywordMatches keywords, dirs, (matches) =>
            if !matches
              callback()
            else if matches.length is 0
              console.log "No directories needed to be deleted..."
              callback()
            else
              # Loop over sortedDupes asynchronously
              deleteKeywordMatch = (iteration) =>
                @promptUserKeywordDelete matches[iteration], ->
                  if matches.length is iteration + 1
                    callback()
                  else
                    deleteKeywordMatch(iteration + 1)
              deleteKeywordMatch(0)

  deleteEmptyDirs: (callback) ->
    console.log '==> '.cyan.bold + 'delete directories that are empty'
    @dbBulkDirsGetAll (dirs) =>
      @getEmptyDirs dirs, (emptyDirs) =>
        # if no empty dirs then just callback
        if emptyDirs
          promptMessage = "Delete all directories that are empty?"
          @promptUserBulkDelete emptyDirs, promptMessage, ->
            callback()
        else
          callback()

  dirExists: (callback) ->
    console.log '==> '.cyan.bold + 'removing directories from database that no longer exist'

    # get all directories
    @dbBulkDirsGetAll (dirs) =>
      # check if dirs exist for a given path
      @checkDirExists dirs, (missingDirs) =>
        if missingDirs.length > 0
          # remove missing files from database
          @dbBulkDirsDelete missingDirs, ->
            console.log 'finished removing missing dirs from mediatidy database'
            callback()
        else
          callback()

  promptUserBulkDelete: (array, message, callback) ->
    if array.length > 0
      # display media files up for deletion
      arrayLength = array.length
      i = 0
      while i < arrayLength
        console.log "DELETE(?):".yellow, array[i]
        i++

      prompt.message = "mediatidy".yellow
      prompt.delimiter = ": ".green
      prompt.properties =
        yesno:
          default: 'no'
          message: message
          required: true
          warning: "Must respond yes or no"
          validator: /y[es]*|n[o]?/

      # Start the prompt
      prompt.start()

      # get the simple yes or no property
      prompt.get ['yesno'], (err, result) =>
        if result.yesno.match(/yes/i)

          fileDelete = (iteration) =>
            fs.rmdir array[iteration], =>

              console.log "DELETED:".red, array[iteration]

              if arrayLength is iteration + 1
                @dbBulkDirsDelete array, ->
                  console.log 'directories deleted and removed from database...'
                  callback()
              else
                fileDelete(iteration + 1)
          fileDelete(0)

        else
          console.log "No directories deleted..."
          callback()
    else
      console.log "No directories needed to be deleted..."
      callback()

  suite: (callback) ->
    # Runs full suite of directory cleanup commands
    async.series [
      (callback) =>
        @addDirs ->
          callback()
      (callback) =>
        @dirExists ->
          callback()
      (callback) =>
        @deleteEmptyDirs ->
          callback()
      (callback) =>
        @deleteUnwantedDirs ->
          callback()
    ], (err, results) ->
      throw err if err
      callback results

module.exports = Dirs
