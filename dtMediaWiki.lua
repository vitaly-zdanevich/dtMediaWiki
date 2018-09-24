--[[dtMediaWiki is a darktable plugin which exports images to Wikimedia Commons
    Author: Trougnouf (Benoit Brummer) <trougnouf@gmail.com>
    Contributor: Simon Legner (simon04)

Dependencies:
* lua-sec: Lua bindings for OpenSSL library to provide TLS/SSL communication
* lua-luajson: JSON parser/encoder for Lua
* lua-multipart-post: HTTP Multipart Post helper
]]
local dt = require "darktable"
local MediaWikiApi = require "contrib/dtMediaWiki/mediawikiapi"
local version = 39

--[[The version number is generated by .git/hooks/pre-commit (+x)
    with the following content:
  #!/bin/sh
  NEWVERSION="$(expr "$(git log master --pretty=oneline | wc -l)" + 1)"
  sed -i -r "s/local version = [0-9]+/local version = ${NEWVERSION}/1" dtMediaWiki.lua
  git add dtMediaWiki.lua
  ]]
-- Preference entries
local preferences_prefix = "mediawiki"
dt.preferences.register(
  preferences_prefix,
  "username",
  "string",
  "Wikimedia username",
  "Wikimedia Commons username",
  ""
)
dt.preferences.register(
  preferences_prefix,
  "password",
  "string",
  "Wikimedia password",
  "Wikimedia Commons password (to be stored in plain-text!)",
  ""
)
dt.preferences.register(
  preferences_prefix,
  "overwrite",
  "bool",
  "Commons: Overwrite existing images?",
  "Existing images will be overwritten  without confirmation, otherwise the upload will fail.",
  false
)
dt.preferences.register(
  preferences_prefix,
  "cat_cam",
  "bool",
  "Commons: Categorize camera?",
  "A category will be added with the camera information " ..
    "(eg: [[Category:Taken with Fujifilm X-E2 and XF18-55mmF2.8-4 R LM OIS]])",
  false
)

dt.preferences.register(
  preferences_prefix,
  "desc_templates",
  "string",
  "Commons: Templates to be placed in {{Information |description= ...}}",
  'These templates are placed in the {{Information |description= ...}} field. (comma-separated)',
  "Description,Depicted person,en,de,fr,es,ja,ru,zh,it,pt,ar"
)

local namepattern_default = "$TITLE ($FILE_NAME) $DESCRIPTION"

local namepattern_widget =
  dt.new_widget("entry") {
  tooltip = table.concat(
    {
      "Determines the `File:` page name",
      "recognized variables:",
      "$FILE_NAME - basename of the input image",
      "$TITLE - title from metadata",
      "$DESCRIPTION - description from metadata",
      "Note that $TITLE or $DESCRIPTION is required, and if both are chosen but only one is available " ..
        "then the fallback name will be `$TITLE$DESCRIPTION ($FILE_NAME)`"
    },
    "\n"
  ),
  text = dt.preferences.read(preferences_prefix, "namepattern", "string"),
  reset_callback = function(self)
    self.text = namepattern_default
    dt.preferences.write(preferences_prefix, "namepattern", "string", self.text)
  end
}

-- language widget shown in lighttable export
local language_widget =
  dt.new_widget("entry") {
  text = "en",
  tooltip = "Description language code. Additional descriptions may be added with tag "
  .. "{{Description|language_code|description_text}} or any of the templates listed in "
  .. "the desc_template setting.",
  reset_callback = function(self)
    self.text = "en"
  end
}

dt.preferences.register(
  preferences_prefix,
  "authorpattern",
  "string",
  "Commons: Preferred author pattern",
  "Determines the author value; variables are $USERNAME, $CREATOR",
  "[[User:$USERNAME|$CREATOR]]"
)
dt.preferences.register(
  preferences_prefix,
  "titleindesc",
  "bool",
  "Commons: Use title in description",
  "Use the title in description if both are available: description={{en|1=$TITLE: $DESCRIPTION}}",
  true
)

local function msgout(txt)
  print(txt)
  dt.print(txt)
end

-- Generate image name
local function make_image_name(image, tmp_exp_path)
  local basename = image.filename:match "[^.]+"
  local outname = namepattern_widget.text or namepattern_default
  dt.preferences.write(preferences_prefix, "namepattern", "string", outname)
  local presdata = image.title .. image.description
  if image.title ~= "" and image.description ~= "" then --2 items available
    outname = outname:gsub("$TITLE", image.title)
    outname = outname:gsub("$FILE_NAME", basename)
    outname = outname:gsub("$DESCRIPTION", image.description)
  elseif outname:find("$TITLE") and outname:find("$DESCRIPTION") then
    outname = presdata .. " (" .. basename .. ")"
  else
    outname = outname:gsub("$TITLE", presdata)
    outname = outname:gsub("$FILE_NAME", basename)
    outname = outname:gsub("$DESCRIPTION", presdata)
  end
  local ext = tmp_exp_path:match "[^.]+$"
  return outname .. "." .. ext
end

-- Round to 1 decimal, remove useless .0's and convert number to string
local function fmt_flt(num)
  num = math.floor(num * 10 + .5) / 10
  if string.sub(num, -2) == ".0" then
    return string.sub(num, 1, -3)
  else
    return tostring(num)
  end
end

-- Get description field from the description (and optionally title) metadata
local function get_description(image)
  local titleindesc = dt.preferences.read(preferences_prefix, "titleindesc", "bool")
  if titleindesc and image.description ~= "" and image.title ~= "" then
    return image.title .. ": " .. image.description
  elseif image.description ~= "" then
    return image.description
  else
    return image.title
  end
end

local function split(astring) -- helper from http://lua-users.org/wiki/SplitJoin, doesn't work with local (?)
   local sep, fields = ",", {}
   local pattern = string.format("([^%s]+)", sep)
   astring:gsub(pattern, function(c) fields[#fields+1] = c end)
   return fields
end

-- get description templates which need to be added to {{Information| description=...}}
local function get_intl_descriptions(image, discarded_tags)
  local desc_templates = split(dt.preferences.read(preferences_prefix, "desc_templates", "string"))
  local intl_descriptions = ""
  for _, tag in pairs(dt.tags.get_tags(image)) do
    tag = tag.name
    for _,dtemplate in pairs(desc_templates) do
      if tag:sub(1,#dtemplate+3) == '{{' .. dtemplate .. '|' then
        intl_descriptions = intl_descriptions .. tag
        discarded_tags[tag] = true
      end
    end
  end
  return intl_descriptions
end


-- Get other fields that are then added to the Information template (TODO document this feature)
local function get_other_fields(image, discarded_tags)
  local other_fields = ''
  for _, tag in pairs(dt.tags.get_tags(image)) do
    tag = tag.name
    if string.sub(tag, 0, 20) == '{{Information field|'
    or string.sub(tag, 0, 7) == '{{InFi|' then
      other_fields = other_fields .. tag
      discarded_tags[tag] = true
    end
  end
  return other_fields
end

-- Generate an image page with all required info from tags, metadata, and such.
local function make_image_page(image)
  local discarded_tags = {}
  local imgpg = {"=={{int:filedesc}}==\n{{Information"}
  table.insert(imgpg, "|description={{" .. language_widget.text .. "|1="
    .. get_description(image) .. "}}" .. get_intl_descriptions(image, discarded_tags))
  local date = image.exif_datetime_taken
  date = date:gsub("(%d%d%d%d):(%d%d):(%d%d)", "%1-%2-%3") -- format date in ISO 8601 / RFC 3339
  table.insert(imgpg, "|date=" .. date)
  table.insert(imgpg, "|source={{own}}")
  local username = dt.preferences.read(preferences_prefix, "username", "string")
  local author = dt.preferences.read(preferences_prefix, "authorpattern", "string")
  author = author:gsub("$USERNAME", username)
  author = author:gsub("$CREATOR", image.creator or username)
  table.insert(imgpg, "|author=" .. author)
  table.insert(imgpg, '|other fields = ' .. get_other_fields(image, discarded_tags))
  table.insert(imgpg, "}}")
  if image.latitude ~= nil and image.longitude ~= nil then
    table.insert(imgpg, "{{Location |1=" .. image.latitude .. " |2=" .. image.longitude .. " }}")
  end
  table.insert(imgpg, "=={{int:license-header}}==")
  table.insert(imgpg, "{{self|" .. image.rights .. "}}")
  for _, tag in pairs(dt.tags.get_tags(image)) do
    tag = tag.name
    if string.sub(tag, 1, 9) == "Category:" then
      table.insert(imgpg, "[[" .. tag .. "]]")
    elseif tag:sub(1, 2) == "{{" and not discarded_tags[tag] then
      table.insert(imgpg, tag)
    end
  end
  if dt.preferences.read(preferences_prefix, "cat_cam", "bool") then
    print("catcam enabled") --dbg
    if image.exif_model ~= "" then
      local model = image.exif_maker:sub(1, 1) .. image.exif_maker:sub(2):lower()
      local catcam = "[[Category:Taken with " .. model .. " " .. image.exif_model
      if image.exif_lens ~= "" then
        catcam = catcam .. " and " .. image.exif_lens .. "]]"
      else
        catcam = catcam .. "]]"
      end
      table.insert(imgpg, catcam)
    end
    if image.exif_aperture then
      table.insert(imgpg, "[[Category:F-number f/" .. fmt_flt(image.exif_aperture) .. "]]")
    end
    if image.exif_focal_length ~= "" then
      table.insert(imgpg, "[[Category:Lens focal length " .. fmt_flt(image.exif_focal_length) .. " mm]]")
    end
    if image.exif_iso ~= "" then
      table.insert(imgpg, "[[Category:ISO speed rating " .. fmt_flt(image.exif_iso) .. "]]")
    end
  --    if image.exif_exposure ~= "" then
  --      table.insert(imgpg, "[[Category:Exposure time "..image.exif_exposure.." sec]]")
  --    end -- decimal instead of fraction (TODO)
  end
  table.insert(imgpg, "[[Category:Uploaded with dtMediaWiki]]")
  imgpg = table.concat(imgpg, "\n")
  return imgpg
end

-- comment widget shown in lighttable export
local comment_widget =
  dt.new_widget("entry") {
  text = "Uploaded with dtMediaWiki " .. version,
  reset_callback = function(self)
    self.text = "Uploaded with dtMediaWiki " .. version
  end
}

--This function is called once for each exported image
local function register_storage_store(_, image, _, tmp_exp_path, _, _, _, _)
  local imagepage = make_image_page(image)
  local imagename = make_image_name(image, tmp_exp_path)
  --print(imagepage)
  MediaWikiApi.uploadfile(
    tmp_exp_path,
    imagepage,
    imagename,
    dt.preferences.read(preferences_prefix, "overwrite", "bool"),
    comment_widget.text
  )
  msgout("exported " .. imagename) -- that is the path also
end

--This function is called once all images are processed and all store calls are finished.
local function register_storage_finalize(_, image_table, extra_data)
  local fcnt = 0
  for _ in pairs(image_table) do
    fcnt = fcnt + 1
  end
  msgout("exported " .. fcnt .. "/" .. extra_data["init_img_cnt"] .. " images to Wikimedia Commons")
end

--A function called to check if a given image format is supported by the Lua storage;
--This is used to build the dropdown format list for the GUI.
local function register_storage_supported(_, format)
  local ext = format.extension
  return ext == "jpg" or ext == "png" or ext == "tif" or ext == "webp"
end

--A function called before storage happens
--This function can change the list of exported functions
local function register_storage_initialize(_, _, images, _, extra_data)
  local out_images = {}
  for _, img in pairs(images) do
    if img.rights == "" then
      --TODO check allowed formats
      msgout("Error: " .. img.path .. " has no rights, cannot be exported to Wikimedia Commons")
    elseif img.title == "" and img.description == "" then
      msgout(
        "Error: " ..
          img.path .. " is missing a meaningful title and/or description, " .. "won't be exported to Wikimedia Commons"
      )
    else
      table.insert(out_images, img)
    end
  end
  extra_data["init_img_cnt"] = #images
  return out_images
end

-- widgets shown in lighttable
local export_widgets =
  dt.new_widget("box") {
  dt.new_widget("box") {
    orientation = "horizontal",
    dt.new_widget("label") {label = "Naming pattern:"},
    namepattern_widget
  },
  dt.new_widget("box") {
    orientation = "horizontal",
    dt.new_widget("label") {label = "Comment:"},
    comment_widget
  },
  dt.new_widget("box") {
    orientation = "horizontal",
    dt.new_widget("label") {label = "Description language code:"},
    language_widget
  }
}

-- Darktable target storage entry
if
  MediaWikiApi.login(
    dt.preferences.read(preferences_prefix, "username", "string"),
    dt.preferences.read(preferences_prefix, "password", "string")
  )
 then
  dt.register_storage(
    "mediawiki",
    "Wikimedia Commons",
    register_storage_store,
    register_storage_finalize,
    register_storage_supported,
    register_storage_initialize,
    export_widgets
  )
else
  msgout("Unable to log into Wikimedia Commons, export disabled.")
end
