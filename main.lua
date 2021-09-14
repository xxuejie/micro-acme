VERSION = "0.0.2"

local micro = import("micro")
local buffer = import("micro/buffer")
local config = import("micro/config")
local shell = import("micro/shell")
local strings = import("strings")
local os = import("os")

function goSliceToLuaArray(slice, s, e)
  local result = {}
  for i = s, e do
    result[#result + 1] = slice[i]
  end
  return result
end

function innerExecute(args)
  if args ~= nil and #args == 0 then
    return
  end
  normalizeArgs(args)
  return shell.ExecCommand(args[1], unpack(goSliceToLuaArray(args, 2, #args)))
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

function innerExecuteWithStdin(args, stdin, onExit, userargs)
  local job = shell.JobSpawn(args[1], goSliceToLuaArray(args, 2, #args),
    nil, nil, onExit, unpack(userargs))
  shell.JobSend(job, stdin)
	job.Stdin:Close()
end

-- Adapted from https://github.com/NicolaiSoeborg/manipulator-plugin/blob/6c621d93985ba696873c54985c0d73d2e59a15e3/manipulator.lua
function getTextLoc()
  local v = micro.CurPane()
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
function getText(a, b)
  local txt, buf = {}, micro.CurPane().Buf

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


function pipeOut(_pane, args)
  local v = micro.CurPane()
  local a, b = getTextLoc()

  local oldTxt = getText(a,b)

  innerExecuteWithStdin(args, oldTxt, showStdinExecuteOutput, {})
end

function pipeIn(_pane, args)
  local v = micro.CurPane()
  local a, b = getTextLoc()

  local output, err = innerExecute(args)
  if err ~= nil then
    showOutput(output, err)
  else
    v.Buf:Replace(a, b, strings.TrimSpace(output))
  end
end

function showErrOrReplaceText(output, userargs)
  userargs[1].Buf:Replace(userargs[2], userargs[3], strings.TrimSpace(output))
end

function pipeBoth(_pane, args)
  local v = micro.CurPane()
  local a, b = getTextLoc()

  local oldTxt = getText(a,b)

  innerExecuteWithStdin(args, oldTxt, showErrOrReplaceText, {v, a, b})
end

function execute(_pane, args)
  showOutput(innerExecute(args))
end

function isFileExists(filename)
  local _info, err = os.Stat(filename)
  return not os.IsNotExist(err)
end

function search(_pane, args)
  local v = micro.CurPane()

  local startLoc = nil
  local endLoc = nil
  local m = nil

  if v.Cursor:HasSelection() then
    startLoc, endLoc = getTextLoc()
    m = getText(startLoc, endLoc)
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

function init()
  config.MakeCommand(">", pipeOut, config.NoComplete)
  config.MakeCommand("<", pipeIn, config.NoComplete)
  config.MakeCommand("|", pipeBoth, config.NoComplete)
  config.MakeCommand("e", execute, config.NoComplete)
end
