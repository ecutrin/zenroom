-- init script embedded at compile time.  executed in
-- zen_load_extensions(L) usually after zen_init()

JSON   = require('json')
SCHEMA = require('schema')
RNG    = require('zenroom_rng')
OCTET  = require('zenroom_octet')
ECDH   = require('ecdh')
LAMBDA = require('functional')
INSIDE = require('inspect')
ECP    = require('ecp')
ECP2   = require('ecp2')
BIG    = require('zenroom_big')
HASH   = require('zenroom_hash')
MSG    = require('msgpack')

-- override type to recognize zenroom's types
luatype = type
function type(var)
   local simple = luatype(var)
   if simple == "userdata" then
	  if getmetatable(var).__name then
		 return(getmetatable(var).__name)
	  else
		 return("unknown")
	  end
   else return(simple) end
end
function content(var)
   if type(var) == "zenroom.octet" then
	  INSIDE.print(var:array())
   else
	  INSIDE.print(var)
   end
end

function ECP2.G()         return ECP2.new() end
function ECP2.generator() return ECP2.new() end

function help(module)
   if module == nil then
	  print("usage: help(module)")
	  print("example > help(octet)")
	  print("example > help(ecdh)")
	  print("example > help(ecp)")
	  return
   end
   for k,v in pairs(module) do
	  if type(v)~='table' and string.sub(k,1,1)~='_' then
		 print("class method: "..k)
	  end
   end
   if module.new == nil then return end
   local inst = module.new()
   for s,f in pairs(getmetatable(inst)) do
	  if(string.sub(s,1,2)~='__') then print("object method: "..s) end
   end
end

function read_json(data, validation)
   if not data then
	  error("read_json: missing data")
	  -- os.exit()
   end
   out,res = JSON.decode(data)
   if not out then
	  if res then
		 error("read_json: invalid json")
		 error(res)
		 -- os.exit()
	  end
   else
	  -- operate schema validation if argument is present
	  if validation then
		 local err = SCHEMA.CheckSchema(out, validation)
		 if err then
			-- error "read_json: schema validation failed"
			error(SCHEMA.FormatOutput(err))
			-- os.exit()
		 end
	  end
	  return out
   end
end
function write_json(data)
   INSIDE.print(data)
end
json_write = write_json
json_read = read_json

-- CompareTables.lua
-- Gianluca Vespignani (c) 2012, Memorandum: technique about Compare Tables
-- ported to Zenroom by Denis Roio (c) 2018
-- v.0.3   added some defaults to simplify the call
-- v.0.2.1 become a function. bug fix: some item was skipped, fix iterators

-- params:	type		description
-- t1:		table		table1
-- t2:		table		table2
-- orderby:	string		order by on significant field. String like SQL ORDER BY: "ORDER BY field1, field2 desc, field3
-- n1:		table		conversion of field name of table1 of the fields signed in orderby {field1="fieldalias1",...}  or {}
-- n2:		table		idem
-- fmt1:	function	format function for n1
-- fmt2:	function	format function for n2
-- comparef: function	comparison function core between formatted value or function(a,b) return a==b end (on the first field of orderby)
-- CBdupli:	function	CallBack function when a couple of duplicate is found. This function must return true or false to look for other doubles on t2
-- CBonly1: function	CallBack function for only in table1 item
-- CBonly2: function	CallBack function for only in table2 item

function diff_tables(t1,t2,orderby,n1,n2,fmt1,fmt2,comparef,CBdupli,CBonly1,CBonly2)
	local t1 = t1 or nil
	local t2 = t2 or nil
	local n1 = n1 or {}
	local n2 = n2 or {}

	-- dbg on t1, t2
	if t1[1]==nil then print("The first table is empty or not index based (t1[1]==nil)") return nil, 0 end
	if t2[1]==nil then print("The second table is empty or not index based (t2[1]==nil)") return nil, 0 end

	-- 1.1.0 Create an indexTable. consider if a working on a clone of the tables may be required, (that could be involves indexes gesture problems)
	-- 1.1.1 Determinate fields to save in indexTable
	local comparisonTabLog = {} 	-- comparison table log
	local counter = 0
	local fieldlist = {}
	-- simply split by ','   eg: "ORDER BY field1, field2 desc, field3"
	local fieldlistlast = orderby:gsub("([^,]*)[,]", function(s) table.insert(fieldlist,s) return "" end )
	table.insert(fieldlist,fieldlistlast)	-- raw inseriment
	for i,v in ipairs(fieldlist) do	-- Apply correction
		fieldlist[i]={} 	-- redefine and reuse
		if i==1 then
			v = v:gsub("^ORDER BY ",""):gsub("^order by ","")
		end
		fieldlist[i].name = v:gsub("^%s+",""):gsub("%s+$","")		-- trim white space
		local _,c = fieldlist[i].name:gsub("%w+","") -- count the words
		if c>1 then
			fieldlist[i].name = fieldlist[i].name:gsub("%s.*$","")	-- keep the first word
			fieldlist[i].desc = true -- decrease
			-- TODO: raise error if the second word is different from 'desc' / 'DESC' or there are more words
		end
	end

	local function alias(nn,field)	-- alias gesture		-- nn is n1 or n2 table
		if #nn==0 then  -- n1=={}
		return field  else return nn[field]
		end
	end
	local fmt1 = fmt1 or function(s) return s end
	local fmt2 = fmt2 or function(s) return s end

	local t1x = {}
	local t2x = {}
	-- Given tables: t1, t2 ...
	for i,v in ipairs(t1) do
		t1x[i] = {}
		t1x[i]._i = i	--save original index / position --table.insert(t1x,{v[n1}])
		for j,field in ipairs(fieldlist) do
			t1x[i][field.name] = fmt1( v[ alias(n1,field.name) ] ) -- apply formatting
		end
	end
	for i,v in ipairs(t2) do
		t2x[i] = {}
		t2x[i]._i=i	--save original index / position --table.insert(t1x,{v[n1}])
		for j,field in ipairs(fieldlist) do
			--dbg = alias(n2,field)
			t2x[i][field.name] = fmt2( v[ alias(n2,field.name) ] ) -- apply formatting
		end
	end

	-- 1.2.1 order on significant field:
	-- 1.2.2 Prepare sorter function for table.sort()
	local sf = function (a,b)
		for i,v in ipairs(fieldlist) do
			if a[v.name] ~= b[v.name] then
				if v.desc then
					return a[v.name] > b[v.name]
				else
					return a[v.name] < b[v.name]
				end
			end
		end
		return a._i < b._i -- else of all, order by original index
	end

	table.sort(t1x, sf)
	table.sort(t2x, sf)

	-- 1.3 init itarator values, remember thru iterations
	local i2 = 1 --0 -- became =1 at 2.4  -- * 1
	local v1f_previous = ""
	local found = false

	local cfc = comparef or function(a,b) return a==b end
	local cb_dupli = CBdupli or function(i1,i2) print(i1, t1[i1].fieldName," -> ",i2, t2[i2].fieldName) return true end
	local cb_only1 = CBonly1 or function(i) print(i, t1[i].fieldName, " +1") return true end
	local cb_only2 = CBonly2 or function(i) print(i, t2[i].fieldName, " +2") return true end

	-- 2.1 for each item in t1x
	for i1,v1 in ipairs(t1x) do
		local v1f = v1[fieldlist[1].name]
		-- 2.4 Check for duplicates on t1x and t2x. if v1f_previous == v1f, i2 is the same
		if i1>1 and v1f_previous == v1f  and comparisonTabLog[i1-1]~=nil  then
			i2 = comparisonTabLog[i1-1][1] -- reload from the necessary index (ref. 4.2 - 4.3)
		--elseif found then -- * was else
		--	i2 = i2+1 -- new item, last was found so increase
		end
		found = false  -- reset this status

		-- 3.2 seach in t2x
		while t2x[i2] do
			counter = counter +1
			local v2 = t2x[i2] -- link like for...in...do , but it's not a clone
			local v2f = t2x[i2][fieldlist[1].name]

			-- 3.4 comparison core
			if cfc(v1f,v2f) then
				-- 4.1 Found! Perform your tasks
				found = true
				cb_dupli(v1._i,v2._i) -- TODO: continue for others?
				-- 4.2 Mind the iterator, logs, or break
				if not comparisonTabLog[i1] then
					comparisonTabLog[i1] = {}	-- init sub table
				end
				-- 4.3 sign and increase iterator
				table.insert(comparisonTabLog[i1], i2)
				i2 = i2+1 -- to search for other duplicates see 2.4
			elseif v2f > v1f then
				-- 5.1 stop the boring comparison. eg: looking for 'Grape' but on t2x you are on 'Lemon'
				break
			elseif v2f < v1f then
				cb_only2(v2._i)	-- item only on t2x
				i2 = i2+1	-- 5.2 usual iteration
			end
		end -- end of while, be sure about there is i2=i2+1 or a break !!!
		-- 6.0 t1x.item finished to compare than table t2x
		-- 6.1 debug stage (interpect loops):
		-- if xi==10 then break end

		-- 6.2 item only in t1x: do something if t1x.item is not found
		if not found then
			cb_only1(v1._i)
		end

		-- 6.3 remember last t1x.item
		v1f_previous = v1f
	end

	-- 6.4 Drop remain queue of t2 if necessary
	if cb_only2~=nil then
		while t2x[i2] do
			cb_only2(t2x[i2]._i)	-- item only on t2x
			i2 = i2+1	-- 5.2 usual iteration
		end
	end

	-- 7.0 finish! you can do something with the comparisonTabLog
	return comparisonTabLog , counter

	-- 7.1 leave memory
	--t1x = nil
	--t2x = nil
end
