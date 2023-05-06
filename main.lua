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

SHELL = "bash"
function wrapWithShell(path, args)
  return {"-l", "-c", "samfile=\"" .. path .. "\" " .. normalizeArgs(args)}
end

function innerExecute(path, args)
  if args ~= nil and #args == 0 then
    return
  end
  return shell.ExecCommand(SHELL, unpack(wrapWithShell(path, args)))
end

function showOutput(output, err)
  if err ~= nil then
    micro.InfoBar():Error(err)
  end

  if output ~= nil and #output > 0 then
    local b = buffer.NewBuffer(output, "")
    b.Type.Readonly = true
    b.Type.Scratch = true
    b:SetOptionNative("statusformatr", "")
    b:SetOptionNative("statusformatl", "+Errors")
    micro.CurPane():VSplitIndex(b, true)
  end
end

function showStdinExecuteOutput(output, _userargs)
  showOutput(output, nil)
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
  local oldTxt = getText(pane, a,b)

  innerExecuteWithStdin(pane.Buf.Path, args, oldTxt, showStdinExecuteOutput, {})
end

function pipeIn(pane, args)
  local a, b = getTextLoc(pane)

  local output, err = innerExecute(pane.Buf.Path, args)
  if err ~= nil then
    showOutput(output, err)
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

function execute(pane, args)
  showOutput(innerExecute(pane.Buf.Path, args))
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

local TAG_SETTING_KEY = "__acme_tag_path"
-- Path -> tag BufPane
local opened_tags = {}

function tag(body, args)
  local path = body.Buf.Path

  local b = buffer.NewBuffer("", "")
  b.Type.Scratch = true
  b:SetOptionNative("statusformatr", "")
  b:SetOptionNative("statusformatl", "+Tags@" .. path)

  local tag = body:HSplitIndex(b, false)
  tag:ResizePane(3)
  tag.Buf.Settings[TAG_SETTING_KEY] = body
  opened_tags[path] = tag
end

function onQuit(pane)
  if pane.Buf.Settings[TAG_SETTING_KEY] then
    -- tag view
    local body = pane.Buf.Settings[TAG_SETTING_KEY]
    opened_tags[body.Buf.Path] = nil
    body:Quit()
  elseif opened_tags[pane.Buf.Path] then
    -- body view
    local tag = opened_tags[pane.Buf.Path]
    opened_tags[pane.Buf.Path] = nil
    tag:Quit()
  end
  return false
end

function buildArgs(command)
  local args = {}
  for a in string.gmatch(command, "([^%s]+)") do
    args[#args + 1] = a
  end
  return args
end

function tagExecute(tag, _args)
  if tag.Buf.Settings[TAG_SETTING_KEY] == nil then
    return
  end
  local body = tag.Buf.Settings[TAG_SETTING_KEY]

  local m, startLoc, endLoc = expandText(tag)

  if m == nil or startLoc == nil or endLoc == nil then
    return
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

function init()
  config.MakeCommand(">", pipeOut, config.NoComplete)
  config.MakeCommand("<", pipeIn, config.NoComplete)
  config.MakeCommand("|", pipeBoth, config.NoComplete)
  config.MakeCommand("e", execute, config.NoComplete)
  config.MakeCommand("E", tagExecute, config.NoComplete)
  config.MakeCommand("tag", tag, config.NoComplete)
end
