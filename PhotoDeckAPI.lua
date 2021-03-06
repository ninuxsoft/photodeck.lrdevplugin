local LrDate = import 'LrDate'
local LrDigest = import 'LrDigest'
local LrFileUtils = import 'LrFileUtils'
local LrHttp = import 'LrHttp'
local LrStringUtils = import 'LrStringUtils'
local LrXml = import 'LrXml'
local PhotoDeckUtils = require 'PhotoDeckUtils'
local PhotoDeckAPIXSLT = require 'PhotoDeckAPIXSLT'

local logger = import 'LrLogger'( 'PhotoDeckPublishLightroomPlugin' )
logger:enable('logfile')

local urlprefix = 'http://api.photodeck.com'
local isTable = PhotoDeckUtils.isTable
local printTable = PhotoDeckUtils.printTable

local PhotoDeckAPI = {}
local PhotoDeckAPICache = {}

-- sign API request according to docs at
-- http://www.photodeck.com/developers/get-started/
local function sign(method, uri, querystring)
  querystring = querystring or ''
  local cocoatime = LrDate.currentTime()
  -- cocoatime = cocoatime - (cocoatime % 600)
  -- Fri, 25 Jun 2010 12:39:15 +0200
  local timestamp = LrDate.timeToUserFormat(cocoatime, "%b, %d %Y %H:%M:%S -0000", true)

  local request = string.format('%s\n%s\n%s\n%s\n%s\n', method, uri,
                                querystring, PhotoDeckAPI.secret, timestamp)
  local signature = PhotoDeckAPI.key .. ':' .. LrDigest.SHA1.digest(request)
  -- logger:trace(timestamp)
  -- logger:trace(signature)
  return {
    { field = 'X-PhotoDeck-TimeStamp', value=timestamp },
    { field = 'X-PhotoDeck-Authorization', value=signature },
  }
end

local function auth_headers(method, uri, querystring)
  -- sign request
  local headers = sign(method, uri, querystring)
  -- set login cookies
  if PhotoDeckAPI.username and PhotoDeckAPI.password and not PhotoDeckAPI.loggedin then
    local authorization = 'Basic ' .. LrStringUtils.encodeBase64(PhotoDeckAPI.username ..
                                                             ':' .. PhotoDeckAPI.password)
    table.insert(headers, { field = 'Authorization',  value=authorization })
  end
  return headers
end

-- extra chars from http://tools.ietf.org/html/rfc3986#section-2.2
local function urlencode (s)
  s = string.gsub(s, "([][:/?#@!#'()*,;&=+%c])", function (c)
         return string.format("%%%02X", string.byte(c))
      end)
  s = string.gsub(s, " ", "+")
  return s
end

local function table_to_mime_multipart(data, boundary)
  assert(PhotoDeckUtils.isTable(data))
  local result = ''
  for _, v in pairs(data) do
    result = result .. '--' .. boundary .. "\n"
    result = result .. 'Content-Disposition: form-data; name="' .. v.name .. '"'
    if v.fileName then
      result = result .. ';filename="' .. v.fileName ..'"'
    end
    result = result .. "\n"
    if v.contentType then
      result = result .. "Content-Type: " .. v.contentType .. "\n"
    end
    result = result .. "\n"
    if v.filePath then
      result = result .. LrFileUtils.readFile(v.filePath) .. "\n"
    else
      result = result .. v.value .. "\n"
    end
  end
  result = result .. '--' .. boundary .. '--' .. "\n"
  -- logger:trace(string.gsub(result, "[^%w %p]+", '.'))
  return result
end

-- convert lua table to url encoded data
-- from http://www.lua.org/pil/20.3.html
local function table_to_querystring(data)
  assert(PhotoDeckUtils.isTable(data))

  local s = ""
  for k,v in pairs(data) do
    s = s .. "&" .. urlencode(k) .. "=" .. urlencode(v)
  end
  return string.sub(s, 2)     -- remove first `&'
end

local function handle_errors(response, resp_headers, onerror)
  local status = PhotoDeckUtils.filter(resp_headers, function(v) return isTable(v) and v.field == 'Status' end)[1]

  if not status or status.value > "400" then
    local statuscode
    if status then
      statuscode = string.sub(status.value, 1, 3)
    end
    if onerror and onerror[statuscode] then
      return onerror[statuscode]()
    end
    logger:error("Bad response: " .. (response or "(no response)"))
    if resp_headers then
      logger:error(PhotoDeckUtils.printLrTable(resp_headers))
    end
    -- raise this up to the user at this point?
  end
  return response
end

-- make HTTP GET request to PhotoDeck API
-- must be called within an LrTask
function PhotoDeckAPI.request(method, uri, data, onerror)
  local querystring = ''
  local body = ''
  if data then
    if method == 'GET' then
      querystring = table_to_querystring(data)
    else
      body = table_to_querystring(data)
    end
  end

  -- set up authorisation headers
  local headers = auth_headers(method, uri, querystring)
  -- build full url
  local fullurl = urlprefix .. uri
  if querystring and querystring ~= '' then
    fullurl = fullurl .. '?' .. querystring
  end

  -- call API
  local result, resp_headers
  if method == 'GET' then
    result, resp_headers = LrHttp.get(fullurl, headers)
  else
    -- override default Content-Type!
    table.insert(headers, { field = 'Content-Type',  value = 'application/x-www-form-urlencoded'})
    result, resp_headers = LrHttp.post(fullurl, body, headers, method)
  end

  result = handle_errors(result, resp_headers, onerror)

  return result, resp_headers
end

function PhotoDeckAPI.connect(key, secret, username, password)
  PhotoDeckAPI.key = key
  PhotoDeckAPI.secret = secret
  PhotoDeckAPI.username = username
  PhotoDeckAPI.password = password
  PhotoDeckAPI.loggedin = false
end

function PhotoDeckAPI.ping(text)
  logger:trace('PhotoDeckAPI.ping')
  local t = {}
  if text then
    t = { text = text }
  end
  local response, headers = PhotoDeckAPI.request('GET', '/ping.xml', t)
  local xmltable = LrXml.xmlElementToSimpleTable(response)
  return xmltable['message']['_value']
end

function PhotoDeckAPI.whoami()
  logger:trace('PhotoDeckAPI.whoami')
  local response, headers = PhotoDeckAPI.request('GET', '/whoami.xml')
  local result = PhotoDeckAPIXSLT.transform(response, PhotoDeckAPIXSLT.whoami)
  -- logger:trace(printTable(result))
  return result
end

function PhotoDeckAPI.websites()
  logger:trace('PhotoDeckAPI.websites')
  local result = PhotoDeckAPICache['websites']
  if not result then
    local response, headers = PhotoDeckAPI.request('GET', '/websites.xml', { view = 'details' })
    result = PhotoDeckAPIXSLT.transform(response, PhotoDeckAPIXSLT.websites)
    PhotoDeckAPICache['websites'] = result
    -- logger:trace(printTable(result))
  end
  return result
end

function PhotoDeckAPI.galleries(urlname)
  logger:trace('PhotoDeckAPI.galleries')
  local response, headers = PhotoDeckAPI.request('GET', '/websites/' .. urlname .. '/galleries.xml', { view = 'details' })
  local result = PhotoDeckAPIXSLT.transform(response, PhotoDeckAPIXSLT.galleries)
  -- logger:trace(printTable(result))
  return result
end

function PhotoDeckAPI.gallery(urlname, galleryId)
  logger:trace('PhotoDeckAPI.gallery')
  local response, headers = PhotoDeckAPI.request('GET', '/websites/' .. urlname .. '/galleries/' .. galleryId .. '.xml', { view = 'details' })
  local result = PhotoDeckAPIXSLT.transform(response, PhotoDeckAPIXSLT.gallery)
  -- logger:trace(printTable(result))
  return result
end

local function buildGalleryInfoFromLrCollection(collection)
  local galleryInfo = {}
  if collection.getCollectionInfoSummary then
    local info = collection:getCollectionInfoSummary().collectionSettings
    galleryInfo['gallery[description]'] = info['description']
    galleryInfo['gallery[display_style]'] = info['display_style']
  end
  return galleryInfo
end

function PhotoDeckAPI.createGallery(urlname, name, collection, parentId)
  logger:trace('PhotoDeckAPI.createGallery')
  local galleryInfo = buildGalleryInfoFromLrCollection(collection)
  galleryInfo['gallery[parent]'] = parentId
  galleryInfo['gallery[name]'] = name
  logger:trace(printTable(galleryInfo))
  local response, headers = PhotoDeckAPI.request('POST', '/websites/' .. urlname .. '/galleries.xml', galleryInfo)
  local result = PhotoDeckAPIXSLT.transform(response, PhotoDeckAPIXSLT.createGallery)
  local gallery = PhotoDeckAPI.gallery(urlname, result['uuid'])
  return gallery
end

function PhotoDeckAPI.updateGallery(urlname, galleryId, newname, collection, parentId)
  logger:trace('PhotoDeckAPI.updateGallery')
  local galleryInfo = buildGalleryInfoFromLrCollection(collection)
  galleryInfo['gallery[name]'] = newname
  galleryInfo['gallery[parent]'] = parentId
  galleryInfo['gallery[url_path]'] = string.gsub(newname:lower(), ' ', '-')
  logger:trace(printTable(galleryInfo))
  local response = PhotoDeckAPI.request('PUT', '/websites/' .. urlname .. '/galleries/' .. galleryId .. '.xml', galleryInfo)
  logger:trace('PhotoDeckAPI.updateGallery: ' .. response)
  local gallery = PhotoDeckAPI.gallery(urlname, galleryId)
  return gallery
end


function PhotoDeckAPI.createOrUpdateGallery(urlname, name, collectionInfo)
  logger:trace('PhotoDeckAPI.createOrUpdateGallery')
  local website = PhotoDeckAPI.websites()[urlname]
  local galleries = PhotoDeckAPI.galleries(urlname)
  local rootGallery = nil
  for _, gallery in pairs(galleries) do
    if not gallery['parentuuid'] or gallery['parentuuid'] == "" then
      rootGallery = gallery
      break
    end
  end
  local parentGallery = rootGallery
  local collection = collectionInfo.publishedCollection
  -- prefer remote Id, particularly for renames, but optionally defer to name
  local gallery = galleries[collection:getRemoteId()] or galleries[name]
  for _, parent in pairs(collectionInfo.parents) do
    logger:trace(printTable(parent))
    local galleryForParent = galleries[parent.remoteCollectionId] or galleries[parent.name]
    if not galleryForParent then
      galleryForParent = PhotoDeckAPI.createGallery(urlname, parent.name, parent,
          parentGallery.uuid)
    end
    parentGallery = galleryForParent
    local parentCollection = collection.catalog:getPublishedCollectionByLocalIdentifier(parent.localCollectionId)
    parentGallery.fullurl = website.homeurl .. "/-/" .. parentGallery.fullurlpath
    if parentCollection and (not parent.remoteCollectionId or parentCollection:getRemoteId() ~= parent.remoteCollectionId or parentCollection:getRemoteUrl() ~= parentGallery.fullurl) then
      logger:trace('Updating parent remote Id and Url')
      parentCollection.catalog:withWriteAccessDo('Set Parent Remote Id and Url', function()
        parentCollection:setRemoteId(parentGallery.uuid)
        parentCollection:setRemoteUrl(parentGallery.fullurl)
      end)
    end
  end
  if gallery then
    gallery = PhotoDeckAPI.updateGallery(urlname, gallery.uuid, name, collection, parentGallery.uuid)
  else
    gallery = PhotoDeckAPI.createGallery(urlname, name, collection, parentGallery.uuid)
  end
  gallery.fullurl = website.homeurl .. "/-/" .. gallery.fullurlpath
  if collection:getRemoteId() == nil or collection:getRemoteId() ~= gallery.uuid or
      collection:getRemoteUrl() ~= gallery.fullurl then
    logger:trace('Updating collection remote Id and Url')
    collection.catalog:withWriteAccessDo('Set Remote Id and Url', function()
      collection:setRemoteId(gallery.uuid)
      collection:setRemoteUrl(gallery.fullurl)
    end)
  end
  return gallery
end

-- getPhoto returns a photo with remote ID uuid, or nil if it does not exist
function PhotoDeckAPI.getPhoto(photoId)
  logger:trace('PhotoDeckAPI.getPhoto')
  local url = '/medias/' .. photoId .. '.xml'
  local onerror = {}
  onerror["404"] = function() return nil end
  local response = PhotoDeckAPI.request('GET', url, nil, onerror)
  if not response then
    return response
  else
    local result = PhotoDeckAPIXSLT.transform(response, PhotoDeckAPIXSLT.getPhoto)
    logger:trace('PhotoDeckAPI.getPhoto: ' .. printTable(result))
    return result
  end
end

function PhotoDeckAPI.photosInGallery(urlname, galleryId)
  logger:trace('PhotoDeckAPI.photosInGallery')
  local url = '/websites/' .. urlname .. '/galleries/' .. galleryId .. '.xml'
  local response, headers = PhotoDeckAPI.request('GET', url, { view = 'details_with_medias' })
  local medias = PhotoDeckAPIXSLT.transform(response, PhotoDeckAPIXSLT.photosInGallery)
  -- turn it into a set for ease of testing inclusion
  local mediaSet = {}
  if medias then
    for _, v in pairs(medias) do
      mediaSet[v] = v
    end
  end
  logger:trace("PhotoDeckAPI.photosInGallery: " .. printTable(mediaSet))
  return mediaSet
end

function PhotoDeckAPI.uploadPhoto( urlname, t)
  logger:trace('PhotoDeckAPI.uploadPhoto')
  -- set up authorisation headers request
  local website = PhotoDeckAPI.websites()[urlname]
  local headers = auth_headers('POST', '/medias.xml')
  local content = {
    { name = 'media[content]', filePath = t.filePath,
      fileName = PhotoDeckUtils.basename(t.filePath), contentType = 'image/jpeg' },
    { name = 'media[publish_to_galleries]', value = t.gallery.uuid }
  }
  logger:trace('PhotoDeckAPI.uploadPhoto: ' .. printTable(content))
  local response, resp_headers = LrHttp.postMultipart(urlprefix .. '/medias.xml', content, headers)
  handle_errors(response, resp_headers)
  local media = PhotoDeckAPIXSLT.transform(response, PhotoDeckAPIXSLT.uploadPhoto)
  media.url = website.homeurl .. '/-/' .. t.gallery.fullurlpath .. "/-/medias/" .. media.uuid
  logger:trace('PhotoDeckAPI.uploadPhoto: ' .. printTable(media))
  return media
end

local function multipartRequest(url, content, method)
  local headers = auth_headers(method, url)
  -- boundary just needs to be sufficiently unique to be unlikely to appear in the file content
  local boundary = LrDigest.SHA256.digest(tostring(LrDate.currentTime()))
  table.insert(headers, { field = 'Content-Type', value = 'multipart/form-data; boundary=' .. boundary })
  local data = table_to_mime_multipart(content, boundary)
  --logger:trace('PhotoDeckAPI.updatePhoto: ' .. string.gsub(data, "[^%w%s%p]+", '.'))
  local response, resp_headers = LrHttp.post(urlprefix .. url, data, headers, 'PUT')
  handle_errors(response, resp_headers)
  return response
end

function PhotoDeckAPI.updatePhoto( photoId, urlname, t)
  logger:trace('PhotoDeckAPI.updatePhoto: ' .. printTable(t))
  -- set up authorisation headers request
  local website = PhotoDeckAPI.websites()[urlname]
  local url = '/medias/' .. photoId .. '.xml'
  local content = {
    { name = 'media[content]', filePath = t.filePath,
      fileName = PhotoDeckUtils.basename(t.filePath), contentType = 'image/jpeg' },
    { name = 'media[publish_to_galleries]', value = t.gallery.uuid }
  }
  logger:trace('PhotoDeckAPI.updatePhoto: ' .. printTable(content))
  local response = multipartRequest(url, content, 'PUT')
  local media = PhotoDeckAPIXSLT.transform(response, PhotoDeckAPIXSLT.updatePhoto)
  media.url = website.homeurl .. '/-/' .. t.gallery.fullurlpath .. "/-/medias/" .. media.uuid
  logger:trace('PhotoDeckAPI.updatePhoto: ' .. printTable(media))
  return media
end

function PhotoDeckAPI.deletePhoto(photoId)
  logger:trace('PhotoDeckAPI.deletePhoto')
  local response, resp_headers = PhotoDeckAPI.request('DELETE', '/medias/' .. photoId .. '.xml')
  logger:trace('PhotoDeckAPI.deletePhoto: ' .. response)
end

function PhotoDeckAPI.unpublishPhoto(photoId, galleryId)
  logger:trace('PhotoDeckAPI.unpublishPhoto')
  local url = '/medias/' .. photoId .. '.xml'
  local content = { { name = 'media[unpublish_from_galleries]', value = galleryId } }
  local response = multipartRequest(url, content, 'PUT')
  logger:trace('PhotoDeckAPI.unpublishPhoto: ' .. response)
end

function PhotoDeckAPI.galleryDisplayStyles(urlname)
  logger:trace('PhotoDeckAPI.galleryDisplayStyles')
  local result = PhotoDeckAPICache['gallery_display_styles/' .. urlname]
  if not result then
    local url = '/websites/' .. urlname .. '/gallery_display_styles.xml'
    local response, headers = PhotoDeckAPI.request('GET', url, { view = 'details' })
    result = PhotoDeckAPIXSLT.transform(response, PhotoDeckAPIXSLT.galleryDisplayStyles)
    PhotoDeckAPICache['gallery_display_styles/' .. urlname] = result
    logger:trace('PhotoDeckAPI.galleryDisplayStyles: ' .. printTable(result))
  end
  return result
end

function PhotoDeckAPI.deleteGallery(urlname, galleryId)
  logger:trace('PhotoDeckAPI.deleteGallery')
  local url = '/websites/' .. urlname .. '/galleries/' .. galleryId .. '.xml'
  logger:trace(url)
  local response, resp_headers = PhotoDeckAPI.request('DELETE', url)
  logger:trace('PhotoDeckAPI.deleteGallery: ' .. response)
end

return PhotoDeckAPI
