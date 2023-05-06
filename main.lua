VERSION = "0.0.2"

local micro = import("micro")
local buffer = import("micro/buffer")
local config = import("micro/config")
local shell = import("micro/shell")
local strings = import("strings")
local os = import("os")

function normalizeArgs(args)
  local result = ""
  for i = 1, #args do
    result = result .. " \"" .. string.gsub(args[i], "\"", "\\\"") .. "\""
  end
  return result
end

local SHELL = "bash"
function wrapWithShell(path, args)
  return {"-l", "-c", "samfile=\"" .. path .. "\" " .. normalizeArgs(args)}
end

function innerExecute(path, args)
  if args ~= nil and #args == 0 then
    return
  end
  return shell.ExecCommand(SHELL, unpack(wrapWithShell(path, args)))
end

function showOutput(pane, output, err)
  if err ~= nil then
    micro.InfoBar():Error(err)
  end

  if output ~= nil and #output > 0 then
    local b = buffer.NewBuffer(output, "")
    b.Type.Readonly = true
    b.Type.Scratch = true
    b:SetOptionNative("statusformatr", "")
    b:SetOptionNative("statusformatl", "+Errors")
    pane:VSplitIndex(b, true)
  end
end

function showStdinExecuteOutput(output, userargs)
  showOutput(userargs[1], output, nil)
end

function innerExecuteWithStdin(path, args, stdin, onExit, userargs)
  local job = shell.JobSpawn(SHELL, wrapWithShell(path, args),
    nil, nil, onExit, unpack(userargs))
  shell.JobSend(job, stdin)
	job.Stdin:Close()
end

-- Adapted from https://github.com/NicolaiSoeborg/manipulator-plugin/blob/6c621d93985ba696873c54985c0d73d2e59a15e3/manipulator.lua
function getTextLoc(v)
  local a, b, c = nil, nil, v.Cursor
  if c:HasSelection() then
    if c.CurSelection[1]:GreaterThan(-c.CurSelection[2]) then
      a, b = c.CurSelection[2], c.CurSelection[1]
    else
      a, b = c.CurSelection[1], c.CurSelection[2]
    end
  else
    local eol = string.len(v.Buf:Line(c.Loc.Y))
    a, b = c.Loc, buffer.Loc(eol, c.Y)
  end
  return buffer.Loc(a.X, a.Y), buffer.Loc(b.X, b.Y)
end

-- Returns the current marked text or whole line
function getText(pane, a, b)
  local txt, buf = {}, pane.Buf

  -- Editing a single line?
  if a.Y == b.Y then
    return buf:Line(a.Y):sub(a.X+1, b.X)
  end

  -- Add first part of text selection (a.X+1 as Lua is 1-indexed)
  table.insert(txt, buf:Line(a.Y):sub(a.X+1))

  -- Stuff in the middle
  for lineNo = a.Y+1, b.Y-1 do
    table.insert(txt, buf:Line(lineNo))
  end

  -- Insert last part of selection
  table.insert(txt, buf:Line(b.Y):sub(1, b.X))

  return table.concat(txt, "\n")
end


function pipeOut(pane, args)
  local a, b = getTextLoc(pane)
  local oldTxt = getText(pane, a, b)

  innerExecuteWithStdin(pane.Buf.Path, args, oldTxt, showStdinExecuteOutput, { pane })
end

function pipeIn(pane, args)
  local a, b = getTextLoc(pane)

  local output, err = innerExecute(pane.Buf.Path, args)
  if err ~= nil then
    showOutput(pane, output, err)
  else
    pane.Buf:Replace(a, b, strings.TrimSuffix(output, "\n"))
  end
end

function showErrOrReplaceText(output, userargs)
  userargs[1].Buf:Replace(userargs[2], userargs[3], strings.TrimSuffix(output, "\n"))
end

function pipeBoth(pane, args)
  local a, b = getTextLoc(pane)
  local oldTxt = getText(pane, a, b)

  innerExecuteWithStdin(pane.Buf.Path, args, oldTxt, showErrOrReplaceText, {pane, a, b})
end

local ARGUMENT_PLACEHOLDER = "@@"

function executeWithSelection(pane, args)
  local revisedArgs = {}
  for i = 1, #args do
    revisedArgs[i] = args[i]
  end
  revisedArgs[#revisedArgs + 1] = ARGUMENT_PLACEHOLDER
  return execute(pane, revisedArgs)
end

function execute(pane, args)
  local a, b = getTextLoc(pane)
  local oldTxt = getText(pane, a, b)

  for i = 1, #args do
    if args[i] == ARGUMENT_PLACEHOLDER then
      args[i] = oldTxt
    end
  end

  local output, err = innerExecute(pane.Buf.Path, args)

  showOutput(pane, output, err)
end

function isFileExists(filename)
  local _info, err = os.Stat(filename)
  return not os.IsNotExist(err)
end

function expandText(v)
  local startLoc = nil
  local endLoc = nil
  local m = nil

  if v.Cursor:HasSelection() then
    startLoc, endLoc = getTextLoc(v)
    m = getText(v, startLoc, endLoc)
  elseif v.Cursor ~= nil then
    local line = v.Buf:Line(v.Cursor.Loc.Y)

    local s1 = string.sub(line, 1, v.Cursor.Loc.X - 1)
    local s2 = string.sub(line, v.Cursor.Loc.X)

    local m1 = string.match(s1, "[^%s]*$")
    local m2 = string.match(s2, "[^%s]*")

    m = m1 .. m2

    startLoc = buffer.Loc(v.Cursor.Loc.X - #m1, v.Cursor.Loc.Y)
    endLoc = buffer.Loc(startLoc.X + #m - 1, v.Cursor.Loc.Y)
  end

  return m, startLoc, endLoc
end

function search(v, args)
  local m, startLoc, endLoc = expandText(v)

  if m == nil or startLoc == nil or endLoc == nil then
    return
  end

  local data = strings.Split(m, ":")
  local filename = data[1]

  if isFileExists(filename) then
    -- Load file
    -- TODO: add more handling
    local b, err = buffer.NewBufferFromFile(data[1])
    if err ~= nil then
      micro.InfoBar():Error(err)
      return
    end

    v:HSplitIndex(b, true)
    local nv = micro.CurPane()
    if #data > 1 and string.match(data[2], "%d") then
      local loc = buffer.Loc(0, tonumber(data[2]) - 1)
      nv.Cursor:GotoLoc(loc)
      nv.Cursor:ResetSelection()
      nv:Relocate()
    end
  else
    -- Search
    local match, found, err = v.Buf:FindNext(m, v.Buf:Start(), v.Buf:End(),
        endLoc, true, false)
    if err ~= nil then
      micro.InfoBar():Error(err)
      return
    end
    if found then
      v.Cursor:SetSelectionStart(match[1])
      v.Cursor:SetSelectionEnd(match[2])
      v.Cursor:GotoLoc(match[2])
      v:Relocate()
    end
  end
end

local TAG_SETTING_TYPE = "__acme_tag_type_"
local TAG_SETTING_OTHER = "__acme_tag_other_"

local TAG_TYPE_TAG = 1
local TAG_TYPE_BODY = 2

function tag(body, args)
  local body_id = tostring(body:ID())

  if body.Buf.Settings[TAG_SETTING_TYPE .. body_id] then
    return
  end

  local path = body.Buf.Path

  local b = buffer.NewBuffer("", "")
  b.Type.Scratch = true
  b:SetOptionNative("statusformatr", "")
  b:SetOptionNative("statusformatl", "+Tags@" .. path)

  local tag = body:HSplitIndex(b, false)
  tag:ResizePane(3)
  local tag_id = tostring(tag:ID())
  tag.Buf.Settings[TAG_SETTING_TYPE .. tag_id] = TAG_TYPE_TAG
  tag.Buf.Settings[TAG_SETTING_OTHER .. tag_id] = body

  body.Buf.Settings[TAG_SETTING_TYPE .. body_id] = TAG_TYPE_BODY
  body.Buf.Settings[TAG_SETTING_OTHER .. body_id] = tag
end

function onQuit(pane)
  local id = tostring(pane:ID())

  if not pane.Buf.Settings[TAG_SETTING_TYPE .. id] then
    return
  end
  local other = pane.Buf.Settings[TAG_SETTING_OTHER .. id]

  local other_id = tostring(other:ID());
  other.Buf.Settings[TAG_SETTING_TYPE .. other_id] = nil
  other.Buf.Settings[TAG_SETTING_OTHER .. other_id] = nil
  other:Quit()
  return false
end

function buildArgs(command)
  local args = {}
  for a in string.gmatch(command, "([^%s]+)") do
    args[#args + 1] = a
  end
  return args
end

function _tagExecute(tag, includeSelection)
  local id = tostring(tag:ID())

  local body = tag
  if tag.Buf.Settings[TAG_SETTING_TYPE .. id] == TAG_TYPE_TAG then
    body = tag.Buf.Settings[TAG_SETTING_OTHER .. id]
  end

  local m, startLoc, endLoc = expandText(tag)

  if m == nil or startLoc == nil or endLoc == nil then
    return
  end

  if includeSelection then
    m = m .. " @@"
  end

  local prefix = string.sub(m, 1, 1)

  if prefix == ">" then
    pipeOut(body, buildArgs(string.sub(m, 2)))
  elseif prefix == "<" then
    pipeIn(body, buildArgs(string.sub(m, 2)))
  elseif prefix == "|" then
    pipeBoth(body, buildArgs(string.sub(m, 2)))
  else
    execute(body, buildArgs(m))
  end
end

function tagExecuteWithSelection(tag, _args)
  _tagExecute(tag, true)
end

function tagExecute(tag, _args)
  _tagExecute(tag, false)
end

function init()
  config.MakeCommand(">", pipeOut, config.NoComplete)
  config.MakeCommand("<", pipeIn, config.NoComplete)
  config.MakeCommand("|", pipeBoth, config.NoComplete)
  config.MakeCommand("E", executeWithSelection, config.NoComplete)
  config.MakeCommand("e", execute, config.NoComplete)
  config.MakeCommand("X", tagExecuteWithSelection, config.NoComplete)
  config.MakeCommand("x", tagExecute, config.NoComplete)
  config.MakeCommand("tag", tag, config.NoComplete)
end
