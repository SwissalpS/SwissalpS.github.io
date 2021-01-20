#! /usr/bin/lua
--[[
	voxelTxtToJDready.lua
	Script to prepare coordinates for minetest Lua Controller and
	jumpdrive to 3D-Print models.
	The input files are expected to be formatted this way:
		x1, y1, z1\n
		x2, y2, z2
	For material/colour format input this way:
		x1, y1, z1, r1, g1, b1\n
		x2, y2, z2, r2, g2, b2

	These input files can be created with tools like:
		https://drububu.com/miscellaneous/voxelizer/

	The script outputs:
		info.txt
			Basic info about the model. Intended to be augmented with more
			description by user.
		index<1-n>.txt
			Not intended for user to edit this. All the file names in order of
			printing are listed here.
			The amount n can be taken from models index.txt (directory higher up)
		materials.txt
			Index of all colour/materials. Currently only for user reference.
		s<Slice Number>_m<Material Index>_p<Part Number>.txt
			Each material/colour for each slice is in it's own file.
			The file format is:
				x1|y1|z1|x2|y2|z2 ... xN|yN|zN
			There is a limit to how many points are in one file. Slice continues
			in next part-file (last number in file name increases)
			There is a special coordinate triplet: '0.1|0.1|0.1'
			It signifies an escape position when jumpdrive needs to jump somewhere
			to avoid 'jump to self' error.

	All the coordinates



--]]

local iTS0 = os.clock()

local tSettings = {}
local tS = tSettings
-- system dependent path separator
tSettings.sDirSep = '/'
-- separator for direction vector in command argument
tSettings.sDirectionSep = 'x'
local sDS = tSettings.sDirectionSep

-- maximum points per file (1400 is absolute max according to recent test)
tSettings.iMaxJumps = 1234
-- maximum nodes carried with printer head
tSettings.iMaxNodes = 9 * 99 -- full deployer
-- maximum charachters in slice indexN.txt files (approx as one entry will be added)
-- test with adding 10 chars per round burnt Lua Controller at length 99980
tSettings.iMaxChars = 76543

-- position where jd can jump to if needed
-- we don't know it, so we use something that will never be used
-- but easy for lua controller to detect.
tSettings.tEscapePos = { x = .1, y = .1, z = .1, m = 0 }
-- radius of jumpdrive
tSettings.iJDradius = 1
-- calculate min jump distance from radius
local iDeltaMin = 1 + (2 * tSettings.iJDradius)

-- pseudo object
local oC = {}
function oC.showUsage()
	local sOut = arg[0] .. ' <path to input file> <path to output directory>'
				.. '[ <build direction vector>]\n\n'
				.. 'input file is a file generated with voxel converter\n'
				.. '<insert link>\n\n'
				.. 'build direction defaults to 0' .. sDS .. '1' .. sDS .. '0'
				.. ' -> from bottom up\n'
	print(sOut)
end -- showUsage


-- based on: https://stackoverflow.com/questions/1340230/check-if-directory-exists-in-lua
-- had to make a couple of changes to get it to work on Fedora 33
local function isDir(sPath)
	if 'string' ~= type(sPath) then return false end
	local hF = io.popen('cd ' .. sPath .. ' 2>&1')
	if not hF then return false end
	local sAll = hF:read('*all')
	hF:close()
	if sAll:find('No such file or directory') then
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


function oC.stringToFile(sOut, sPathFileOut)
	local rFH = io.open(sPathFileOut, 'w')
	if rFH then
		rFH:write(sOut)
		rFH:close()
		return true, ''
	else
		return false, 'error opening file to write: ' .. sPathFileOut
	end
end -- stringToFile


function oC.pointToString(t, iMaterial, bSkipMaterial)
	local sOut = tostring(t.x) .. '|' .. tostring(t.y) .. '|' .. tostring(t.z)
	if bSkipMaterial then return sOut end
	iMaterial = t.m or iMaterial or 0
	return sOut .. '|' .. tostring(iMaterial)
end
function oC.makePoint(x, y, z, m) return { x = x or 0, y = y or 0, z = z or 0, m = m or 0 } end
function oC.pointFromList(l, iMaterial)
	return oC.makePoint(tonumber(l[1]), tonumber(l[2]), tonumber(l[3]), iMaterial)
end
function oC.isValidDirection(t)
	if nil == t.x or nil == t.y or nil == t.z then return false end
	if 1 ~= math.abs(t.x) + math.abs(t.y) + math.abs(t.z) then return false end
	return true
end
function oC.isSamePoint(tA, tB)
	if tA.x ~= tB.x then return false end
	if tA.y ~= tB.y then return false end
	if tA.z ~= tB.z then return false end
	return true
end -- isSamePoint
function oC.containsPoint(tHaystack, tPoint)
	local i = #tHaystack
	if 0 == i then return false end
	repeat
		if oC.isSamePoint(tPoint, tHaystack[i]) then return true end
		i = i - 1
	until 0 == i
	return false
end -- containsPoint
function oC.isNotIntersecting(tA, tB)
	if math.abs(tA.x - tB.x) >= iDeltaMin then return true end
	if math.abs(tA.y - tB.y) >= iDeltaMin then return true end
	if math.abs(tA.z - tB.z) >= iDeltaMin then return true end
	return false
end -- isNotIntersecting

-- read arguments
oC.sPathFileIn = arg[1]
oC.sPathOut = arg[2]
oC.sDirection = arg[3] or ('0' .. sDS .. '1' .. sDS .. '0')

if nil == oC.sPathFileIn then
	oC.showUsage()
	os.exit()
end

if not isDir(oC.sPathOut) then
	oC.showUsage()
	os.exit()
end

-- extract id out of path
local lPath = oC.sPathOut:split(tS.sDirSep)
oC.sID = lPath[#lPath]
if oC.sPathOut:sub(-1) ~= tS.sDirSep then oC.sPathOut = oC.sPathOut .. tS.sDirSep end

-- test to see if infile exists and can be opened for reading
local hIn = io.open(oC.sPathFileIn, 'r')
if nil == hIn then
	oC.showUsage()
	os.exit()
end
hIn:close()

oC.tDirection = oC.pointFromList(oC.sDirection:split(sDS))
if not oC.isValidDirection(oC.tDirection) then
	print('invalid direction vector given')
	oC.showUsage()
	os.exit()
end

-- read all points into a table
-- detecting materials as we go
oC.tDB = {}
oC.tHash = {}
local tPoint
oC.tPmax = { x = -45678, y = -45678, z = -45678 }
oC.tPmin = { x = 45678, y = 45678, z = 45678 }
local lLine
local iMaterial
local sColour
oC.tMaterials = { [1] = '#000000', ['#000000'] = 1 }
for sLine in io.lines(oC.sPathFileIn) do
	--print(sLine)
	lLine = sLine:split(',')
	if 3 == #lLine then
		iMaterial = 1
	elseif 6 == #lLine then
		sColour = string.format('#%02x%02x%02x', lLine[4], lLine[5], lLine[6])
		if not oC.tMaterials[sColour] then
			oC.tMaterials[#oC.tMaterials + 1] = sColour
			oC.tMaterials[sColour] = #oC.tMaterials
		end
		iMaterial = oC.tMaterials[sColour]
	else
		print('unknown material format')
	end
	tPoint = oC.pointFromList(lLine, iMaterial)
	-- detect min and max to later calculate dimensions
	if oC.tPmax.x < tPoint.x then oC.tPmax.x = tPoint.x end
	if oC.tPmax.y < tPoint.y then oC.tPmax.y = tPoint.y end
	if oC.tPmax.z < tPoint.z then oC.tPmax.z = tPoint.z end
	if oC.tPmin.x > tPoint.x then oC.tPmin.x = tPoint.x end
	if oC.tPmin.y > tPoint.y then oC.tPmin.y = tPoint.y end
	if oC.tPmin.z > tPoint.z then oC.tPmin.z = tPoint.z end
	-- add to database
	oC.tDB[#oC.tDB + 1] = tPoint
	-- add to hash lookup
	oC.tHash[oC.pointToString(tPoint, nil, true)] = tPoint
	--print(pointToString(tPoint))
end
-- collect some info for user
oC.tTotal = {
	x = oC.tPmax.x - oC.tPmin.x + 1,
	y = oC.tPmax.y - oC.tPmin.y + 1,
	z = oC.tPmax.z - oC.tPmin.z + 1,
	c = #oC.tDB
}
oC.sSummary = 'ID: ' .. oC.sID .. '\n'
		.. 'width (x): ' .. oC.tTotal.x .. '\n'
		.. 'height (y): ' .. oC.tTotal.y .. '\n'
		.. 'depth (z): ' .. oC.tTotal.z .. '\n'
		.. 'total points: ' .. oC.tTotal.c .. '\n'
		.. 'materials: ' .. tostring(#oC.tMaterials)

-- export colour index table
sOut = ''
for i = 1, #oC.tMaterials do
	sOut = sOut .. tostring(i) .. oC.tMaterials[i] .. '\n'
end
local sPathFileOut = oC.sPathOut .. 'materials.txt'
local bOK, sError = oC.stringToFile(sOut, sPathFileOut)
if not bOK then
	print(sError)
	os.exit()
end

-- determine primary axis to be used for slices
-- and subsequent order
local sK1, sK2, sK3
local iStep, lsDirection, sDirectionInfo
if 0 ~= oC.tDirection.x then
	sK1 = 'x' sK2 = 'y' sK3 = 'z'
	iStep = oC.tDirection.x
	lsDirection = { 'West', 'East' }
elseif 0 ~= oC.tDirection.y then
	sK1 = 'y' sK2 = 'x' sK3 = 'z'
	iStep = oC.tDirection.y
	lsDirection = { 'Down', 'Up' }
elseif 0 ~= oC.tDirection.z then
	sK1 = 'z' sK2 = 'x' sK3 = 'y'
	iStep = oC.tDirection.z
	lsDirection = { 'South', 'North' }
end
local iFirst, iLast, sSign
if 0 < iStep then
	iFirst = oC.tPmin[sK1]
	iLast = oC.tPmax[sK1]
	sDirectionInfo = lsDirection[2]
	sSign = '+'
else
	iFirst = oC.tPmax[sK1]
	iLast = oC.tPmin[sK1]
	sDirectionInfo = lsDirection[1]
	sSign = '-'
end
sDirectionInfo = 'Build direction: ' .. sDirectionInfo .. 'ward'

-- separate slices, materials and 'sort'
local sPoint
local lSlice, lM
oC.lSlices = {}
for i = iFirst, iLast, iStep do
	--print(sK1 .. ' ' .. i)
	lSlice = {}
	for l = 1, #oC.tMaterials do lSlice[l] = {} end
	for j = oC.tPmin[sK2], oC.tPmax[sK2], 1 do
		--print(sK2 .. ' ' .. j)
		for k = oC.tPmin[sK3], oC.tPmax[sK3], 1 do
			tPoint = {}
			tPoint[sK1] = i
			tPoint[sK2] = j
			tPoint[sK3] = k
			sPoint = oC.pointToString(tPoint, nil, true)
			--print(sPoint)
			if oC.tHash[sPoint] then
				tPoint = oC.tHash[sPoint]
				lM = lSlice[tPoint.m]
				lM[#lM + 1] = tPoint
				--lSlice[tPoint.m] = lM
				--print(sPoint)
			end
		end
	end
	--print(#lSlice)
	--if 0 ~= #lSlice then lSlices[#lSlices + 1] = lSlice end
	oC.lSlices[#oC.lSlices + 1] = lSlice
end

-- now we need to make jump-compatible
oC.lJDcompat = {}
local lDone, iDone, bFound
oC.tLastDefault = function() return { x = -45678, y = -45678, z = -45678 } end
local tLast
for i, lS in ipairs(oC.lSlices) do
	--pd('i ' .. i)
	oC.lJDcompat[i] = {}
	for j = 1, #oC.tMaterials do
		--pd('j ' .. j)
		oC.lJDcompat[i][j] = {}
		lSlice = lS[j]
		lDone = {}
		iDone = 0
		tLast = oC.tLastDefault()
		--pd(lSlice)
		--print('slice: ' .. i)
		if 0 < #lSlice then
			repeat
				bFound = false
				for _, tPoint in ipairs(lSlice) do
					sPoint = oC.pointToString(tPoint)
					if not lDone[sPoint] then
						if oC.isNotIntersecting(tLast, tPoint) then
							tLast = tPoint
							oC.lJDcompat[i][j][#oC.lJDcompat[i][j] + 1] = tPoint
							lDone[sPoint] = true
							iDone = iDone + 1
							bFound = true
						end -- if far enough away from last
					end -- if not yet added
				end -- loop j (points on slice)
				if not bFound then
					print('adding escape pos after: ' .. oC.pointToString(tLast))
					-- add a jump to escape position
					oC.lJDcompat[i][j][#oC.lJDcompat[i][j] + 1] = tS.tEscapePos
					tLast = oC.tLastDefault()
				end
			until #lSlice == iDone
		end -- if got any at all
	end -- loop materials
end -- loop i (slices)

-- dump
local sLine, sFile, iCountJumps, iCountNodes, iCountParts
local sIndex = ''
local iTotalJumps = 0
local iTotalNodes = 0
local iTotalIndexFiles = 1
for i, lS in ipairs(oC.lJDcompat) do
	--print('slice: ' .. i)
	for j = 1, #oC.tMaterials do
		lSlice = lS[j]
		sOut = ''
		iCountJumps = 0
		iCountNodes = 0
		iCountParts = 0
		for _, tPoint in ipairs(lSlice) do
			iCountJumps = iCountJumps + 1
			if not oC.isSamePoint(tPoint, tSettings.tEscapePos) then
				iCountNodes = iCountNodes + 1
			end
			sPoint = oC.pointToString(tPoint, j, true)
			if 0 ~= #sOut then sOut = sOut .. '|' end
			sOut = sOut .. sPoint
			if tS.iMaxJumps <= iCountJumps or tS.iMaxNodes <= iCountNodes then
				sFile = 's' .. tostring(i) .. '_m' .. tostring(j)
						.. '_p' .. tostring(iCountParts)
				bOK, sError = oC.stringToFile(sOut, oC.sPathOut .. sFile .. '.txt')
				if bOK then
					sIndex = sIndex .. sFile .. '\n'
				else
					print(sError)
				end
				sOut = ''
				iTotalJumps = iTotalJumps + iCountJumps
				iTotalNodes = iTotalNodes + iCountNodes
				iCountJumps = 0
				iCountNodes = 0
				iCountParts = iCountParts + 1
			end -- if need to write file
		end -- loop points on slice
		if 0 < #sOut then
			iTotalJumps = iTotalJumps + iCountJumps
			iTotalNodes = iTotalNodes + iCountNodes
			sFile = 's' .. tostring(i) .. '_m' .. tostring(j)
			if 0 < iCountParts then
				sFile = sFile .. '_p' .. tostring(iCountParts)
			end
			bOK, sError = oC.stringToFile(sOut, oC.sPathOut .. sFile .. '.txt')
			if bOK then
				sIndex = sIndex .. sFile .. '\n'
				if tS.iMaxChars <= #sIndex then
					sPathFileOut = oC.sPathOut .. 'index'
							.. tostring(iTotalIndexFiles) .. '.txt'
					bOK, sError = oC.stringToFile(sIndex:sub(1, -2), sPathFileOut)
					if not bOK then print(sError) end
					iTotalIndexFiles = iTotalIndexFiles + 1
					sIndex = ''
				end
			else
				print(sError)
			end
			--print('>>>', sOut, '<<<')
		end -- if got anything to export
	end -- loop materials
end -- loop slices

-- write last indexN.txt
if 0 < #sIndex then
	sPathFileOut = oC.sPathOut .. 'index'
			.. tostring(iTotalIndexFiles) .. '.txt'
	bOK, sError = oC.stringToFile(sIndex:sub(1, -2), sPathFileOut)
	if not bOK then print(sError) end
end

-- make a scaffold info.txt
sOut = oC.sSummary .. '\n' .. sDirectionInfo .. ' (' .. sSign .. sK1 .. ')'
		.. '\nTotal Jumps: ' .. tostring(iTotalJumps)
		.. '\nTotal Nodes: ' .. tostring(iTotalNodes)
sPathFileOut = oC.sPathOut .. 'info.txt'
bOK, sError = oC.stringToFile(sOut, sPathFileOut)
print(sOut .. ' ' .. sError)

-- print for model-index.txt
print('Add following line to models index.txt\n')
local sOut = oC.sID .. '|' .. oC.tTotal.x .. '|' .. oC.tTotal.y .. '|' .. oC.tTotal.z
	.. '|' .. #oC.tMaterials .. '|' .. oC.sDirection:gsub(sDS, '|')
	.. '|' .. tostring(iTotalIndexFiles) .. '|<insert title>\n'
print(sOut)

print(string.format('elapsed time: %.2f\n', os.clock() - iTS0))

