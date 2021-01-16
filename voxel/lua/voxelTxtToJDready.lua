#! /usr/bin/lua

local iTS0 = os.clock()

-- system dependent path separator
local sDirSep = '/'
-- separator for direction vector in command argument
local sDirectionSep = 'x'
local sDS = sDirectionSep

-- maximum line length (one \n is added)
local iMaxChars = 1023
-- maximum lines per file
local iMaxLines = 11111

-- position where jd can jump to if needed
-- we don't know it, so we use smth that will never be used
-- but easy for lua controller to detect in-game.
local tEscapePos = { x = .1, y = .1, z = .1, m = 0 }
-- radius of jumpdrive
local iJDradius = 1
-- calculate min jump distance from radius
local iDeltaMin = 1 + (2 * iJDradius)

local function showUsage()
	local sOut = arg[0] .. ' <path to input file> <path to output directory>'
				.. '[ <build direction vector>]\n\n'
				.. 'input file is a file generated with voxel converter\n'
				.. '<insert link>\n\n'
				.. 'build direction defaults to 0' .. sDS .. '1' .. sDS .. '0'
				.. ' -> from bottom up\n'
	print(sOut)
end -- showUsage


-- based on: https://stackoverflow.com/questions/1340230/check-if-directory-exists-in-lua
local function isDir(sPath)
	if 'string' ~= type(sPath) then return false end
	local hF = io.popen('cd ' .. sPath)
	local sAll = hF:read('*all')
	if sAll:find('ItemNotFoundException') then
		return false
	else
		return true
	end
end -- isDir

function dump(mVal, iIndent)
	local sOut
	local sT = type(mVal)
	if 'string' == sT then sOut = '"' .. mVal .. '"'
	elseif 'nil' == sT then sOut = 'nil'
	elseif 'function' == sT then sOut = 'function'
	elseif 'boolean' == sT then sOut = (mVal and 'true') or 'false'
	elseif 'number' == sT then sOut = tostring(mVal)
	elseif 'userdata' == sT then sOut = sT
	elseif 'table' == sT then
		iIndent = iIndent or 0
		if 13 <= iIndent then return '<<too deep, not dumping more>>' end
		local sQ
		local sIndent = '' for _ = 1, iIndent do sIndent = sIndent .. ' ' end
		sOut = '{\n'
		sIndent = sIndent .. ' '
		iIndent = iIndent + 1
		for k, v in pairs(mVal) do
			sQ = ''
			if 'string' == type(k) then sQ = '"' end
			sOut = sOut .. sIndent .. '[' .. sQ .. k .. sQ .. '] = '
					.. dump(v, iIndent) .. '\n'
		end
		sOut = sOut .. (sIndent:sub(2)) .. '}'
	else return 'unhandled type: ' .. sT
	end
	return sOut
end -- dump
local function pd(mV) print(dump(mV)) end


function string:split(sSep)
	sSep = sSep or ' '
	local lOut = {}
	if 'string' ~= type(sSep) or 1 ~= #sSep then return lOut end

	local iSep0 = 1
	local iSep1
	local bDone = false
	local sPart = ''
	repeat
		iSep1 = self:find(sSep, iSep0, true)
		if nil == iSep1 then
			bDone = true
			sPart = self:sub(iSep0)
		else
			sPart = self:sub(iSep0, iSep1 - 1)
			iSep0 = iSep1 + 1
		end
		if '' ~= sPart and sSep ~= sPart then
			table.insert(lOut, sPart)
		end
	until bDone

	return lOut

end -- string:split

local function stringToFile(sOut, sPathFileOut)
	local rFH = io.open(sPathFileOut, 'w')
	if rFH then
		rFH:write(sOut)
		rFH:close()
		return true, ''
	else
		return false, 'error opening file to write: ' .. sPathFileOut
	end
end -- stringToFile

local function pointToString(t, iMaterial, bSkipMaterial)
	local sOut = tostring(t.x) .. '|' .. tostring(t.y) .. '|' .. tostring(t.z)
	if bSkipMaterial then return sOut end
	iMaterial = t.m or iMaterial or 0
	return sOut .. '|' .. tostring(iMaterial)
end
local function makePoint(x, y, z, m) return { x = x or 0, y = y or 0, z = z or 0, m = m or 0 } end
local function pointFromList(l, iMaterial)
	return makePoint(tonumber(l[1]), tonumber(l[2]), tonumber(l[3]), iMaterial)
end
local function isValidDirection(t)
	if nil == t.x or nil == t.y or nil == t.z then return false end
	if 1 ~= math.abs(t.x) + math.abs(t.y) + math.abs(t.z) then return false end
	return true
end
local function isSamePoint(tA, tB)
	if tA.x ~= tB.x then return false end
	if tA.y ~= tB.y then return false end
	if tA.z ~= tB.z then return false end
	return true
end -- isSamePoint
local function containsPoint(tHaystack, tPoint)
	local i = #tHaystack
	if 0 == i then return false end

	repeat
		if isSamePoint(tPoint, tHaystack[i]) then return true end
		i = i - 1
	until 0 == i

	return false
end -- containsPoint
local function isNotIntersecting(tA, tB)
	if math.abs(tA.x - tB.x) >= iDeltaMin then return true end
	if math.abs(tA.y - tB.y) >= iDeltaMin then return true end
	if math.abs(tA.z - tB.z) >= iDeltaMin then return true end
	return false
end -- isNotIntersecting

-- read arguments
local sPathFileIn = arg[1]
local sPathOut = arg[2]
local sDirection = arg[3] or ('0' .. sDS .. '1' .. sDS .. '0')

if nil == sPathFileIn then
	showUsage()
	os.exit()
end

if not isDir(sPathOut) then
	showUsage()
	os.exit()
end
-- extract id out of path
local lPath = sPathOut:split(sDirSep)
local sID = lPath[#lPath]
if sPathOut:sub(-1) ~= sDirSep then sPathOut = sPathOut .. sDirSep end

local hIn = io.open(sPathFileIn)
if nil == hIn then
	showUsage()
	os.exit()
end
hIn:close()

local tDirection = pointFromList(sDirection:split(sDS))
if not isValidDirection(tDirection) then
	print('invalid direction vector given')
	showUsage()
	os.exit()
end

-- read all points into a table
-- detecting materials as we go
local tDB = {}
local tHash = {}
local tPoint
local tPmax = { x = -45678, y = -45678, z = -45678 }
local tPmin = { x = 45678, y = 45678, z = 45678 }
local lLine
local iMaterial
local sColour
local tMaterials = { [1] = '#000000', ['#000000'] = 1 }
for sLine in io.lines(sPathFileIn) do
	--print(sLine)
	lLine = sLine:split(',')
	if 3 == #lLine then
		iMaterial = 1
	elseif 6 == #lLine then
		sColour = string.format('#%02x%02x%02x', lLine[4], lLine[5], lLine[6])
		if not tMaterials[sColour] then
			tMaterials[#tMaterials + 1] = sColour
			tMaterials[sColour] = #tMaterials
		end
		iMaterial = tMaterials[sColour]
	else
		print('unknown material format')
	end
	tPoint = pointFromList(lLine, iMaterial)
	-- detect min and max to later calculate dimensions
	if tPmax.x < tPoint.x then tPmax.x = tPoint.x end
	if tPmax.y < tPoint.y then tPmax.y = tPoint.y end
	if tPmax.z < tPoint.z then tPmax.z = tPoint.z end
	if tPmin.x > tPoint.x then tPmin.x = tPoint.x end
	if tPmin.y > tPoint.y then tPmin.y = tPoint.y end
	if tPmin.z > tPoint.z then tPmin.z = tPoint.z end
	-- add to database
	tDB[#tDB + 1] = tPoint
	-- add to hash lookup
	tHash[pointToString(tPoint, nil, true)] = tPoint
	--print(pointToString(tPoint))
end
-- collect some info for user
local tTotal = {
	x = tPmax.x - tPmin.x + 1,
	y = tPmax.y - tPmin.y + 1,
	z = tPmax.z - tPmin.z + 1,
	c = #tDB
}
local sSummary = 'ID: ' .. sID .. '\n'
		.. 'width (x): ' .. tTotal.x .. '\n'
		.. 'height (y): ' .. tTotal.y .. '\n'
		.. 'depth (z): ' .. tTotal.z .. '\n'
		.. 'total points: ' .. tTotal.c .. '\n'
		.. 'materials: ' .. tostring(#tMaterials)


-- print for model-index.txt
print('Add following line to models index.txt\n')
local sOut = sID .. '|' .. tTotal.x .. '|' .. tTotal.y .. '|' .. tTotal.z
	.. '|' .. #tMaterials .. '|' .. sDirection:gsub(sDS, '|')
	.. '|<insert title>\n'
print(sOut)

-- export colour index table
sOut = ''
for i = 1, #tMaterials do
	sOut = sOut .. tostring(i) .. tMaterials[i] .. '\n'
end
local sPathFileOut = sPathOut .. 'materials.txt'
local bOK, sError = stringToFile(sOut, sPathFileOut)
if not bOK then
	print(sError)
	os.exit()
end

-- determine primary axis to be used for slices
-- and subsequent order
local sK1, sK2, sK3
local iStep, lsDirection, sDirectionInfo
if 0 ~= tDirection.x then
	sK1 = 'x' sK2 = 'y' sK3 = 'z'
	iStep = tDirection.x
	lsDirection = { 'West', 'East' }
elseif 0 ~= tDirection.y then
	sK1 = 'y' sK2 = 'x' sK3 = 'z'
	iStep = tDirection.y
	lsDirection = { 'Down', 'Up' }
elseif 0 ~= tDirection.z then
	sK1 = 'z' sK2 = 'x' sK3 = 'y'
	iStep = tDirection.z
	lsDirection = { 'South', 'North' }
end
local iFirst, iLast, sSign
if 0 < iStep then
	iFirst = tPmin[sK1]
	iLast = tPmax[sK1]
	sDirectionInfo = lsDirection[2]
	sSign = '+'
else
	iFirst = tPmax[sK1]
	iLast = tPmin[sK1]
	sDirectionInfo = lsDirection[1]
	sSign = '-'
end
sDirectionInfo = 'Build direction: ' .. sDirectionInfo .. 'ward'

-- make a scaffold info.txt
sOut = sSummary .. '\n' .. sDirectionInfo .. ' (' .. sSign .. sK1 .. ')'
sPathFileOut = sPathOut .. 'info.txt'
bOK, sError = stringToFile(sOut, sPathFileOut)
print(sOut .. ' ' .. sError)

-- separate slices, materials and 'sort'
local sPoint
local lSlice, lM
local lSlices = {}
for i = iFirst, iLast, iStep do
	--print(sK1 .. ' ' .. i)
	lSlice = {}
	for l = 1, #tMaterials do lSlice[l] = {} end
	for j = tPmin[sK2], tPmax[sK2], 1 do
		--print(sK2 .. ' ' .. j)
		for k = tPmin[sK3], tPmax[sK3], 1 do
			tPoint = {}
			tPoint[sK1] = i
			tPoint[sK2] = j
			tPoint[sK3] = k
			sPoint = pointToString(tPoint, nil, true)
			--print(sPoint)
			if tHash[sPoint] then
				tPoint = tHash[sPoint]
				lM = lSlice[tPoint.m]
				lM[#lM + 1] = tPoint
				--lSlice[tPoint.m] = lM
				--print(sPoint)
			end
		end
	end
	--print(#lSlice)
	--if 0 ~= #lSlice then lSlices[#lSlices + 1] = lSlice end
	lSlices[#lSlices + 1] = lSlice
end

-- now we need to make jump-compatible
local lJDcompat = {}
local lDone, iDone, bFound
local tLastDefault = function() return { x = -45678, y = -45678, z = -45678 } end
local tLast
for i, lS in ipairs(lSlices) do
	--pd('i ' .. i)
	lJDcompat[i] = {}
	for j = 1, #tMaterials do
		--pd('j ' .. j)
		lJDcompat[i][j] = {}
		lSlice = lS[j]
		lDone = {}
		iDone = 0
		tLast = tLastDefault()
		--pd(lSlice)
		--print('slice: ' .. i)
		if 0 < #lSlice then
			repeat
				bFound = false
				for _, tPoint in ipairs(lSlice) do
					sPoint = pointToString(tPoint)
					if not lDone[sPoint] then
						if isNotIntersecting(tLast, tPoint) then
							tLast = tPoint
							lJDcompat[i][j][#lJDcompat[i][j] + 1] = tPoint
							lDone[sPoint] = true
							iDone = iDone + 1
							bFound = true
						end -- if far enough away from last
					end -- if not yet added
				end -- loop j (points on slice)
				if not bFound then
					print('adding escape pos after: ' .. pointToString(tLast))
					-- add a jump to escape position
					lJDcompat[i][j][#lJDcompat[i][j] + 1] = tEscapePos
					tLast = tLastDefault()
				end
			until #lSlice == iDone
		end -- if got any at all
	end -- loop materials
end -- loop i (slices)

-- dump
local sLine, sFile
local sIndex = ''
for i, lS in ipairs(lJDcompat) do
	--print('slice: ' .. i)
	for j = 1, #tMaterials do
		lSlice = lS[j]
		sOut = ''
		sLine = ''
		for _, tPoint in ipairs(lSlice) do
			sPoint = pointToString(tPoint, j, true)
			if (#sPoint + #sLine) < iMaxChars then
				if 0 ~= #sLine then sLine = sLine .. '|' end
				sLine = sLine .. sPoint
			else
				sOut = sOut .. sLine .. '\n'
				sLine = ''
			end
		end -- loop points on slice
		sOut = sOut .. sLine
		if 0 < #sOut then
			sFile = 's' .. tostring(i) .. '_m' .. tostring(j) .. '.txt'
			bOK, sError = stringToFile(sOut, sPathOut .. sFile)
			if bOK then
				sIndex = sIndex .. sFile .. '\n'
			else
				print(sError)
			end
			--print('>>>', sOut, '<<<')
		end -- if got anything to export
	end -- loop materials
end -- loop slices

sPathFileOut = sPathOut .. 'index.txt'
bOK, sError = stringToFile(sIndex, sPathFileOut)
if not bOK then print(sError) end

print(string.format('elapsed time: %.2f\n', os.clock() - iTS0))

