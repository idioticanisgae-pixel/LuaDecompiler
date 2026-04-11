--[[
  ZUKv2 CORE — Luau bytecode disassembler
  Compatible: Luau (Roblox executors), Lua 5.1, Lua 5.2, Lua 5.3, Lua 5.4

  Usage (CLI):
    lua zukv2.lua <bytecode_file> [options]

  Options:
    --mode disasm       disassembly (default)
    --clean             enable clean / prettified output
    --no-globals        suppress used-globals header
    --timeout N         set decompiler timeout in seconds (default 10)
    --float-precision N float formatting precision (default 7)
    --show-debug        show proto debug metadata
    --show-lines        show instruction line numbers
    --show-opidx        show instruction indices
    --show-opnames      show raw opcode names
    --show-trivial      show trivial (bookkeeping) ops
    --no-typeinfo       disable type annotation output

  As a module:
    local zuk = require("zukv2")
    local result = zuk.decompile(bytecodeString, options)
    local pretty  = zuk.prettyPrint(result)
    local clean   = zuk.cleanOutput(result)
]]

-- ── Runtime detection ────────────────────────────────────────────────────────
-- Detect Luau, LuaJIT (bit lib), or plain Lua 5.1/5.2/5.3/5.4
local _LUAU   = type(bit32) == "table" and bit32.band ~= nil  -- Luau exposes bit32 natively
local _LUA51  = (not _LUAU) and (_VERSION == "Lua 5.1")
local _LUAJIT = (not _LUAU) and (type(jit) == "table")

-- ── Pure-Lua bit32 shim (used when not running on Luau/5.2+/LuaJIT) ─────────
-- Under Luau the native bit32 library is already present; we only build the
-- shim when running under a plain Lua without bitwise operators.

local bit32
do
  -- Try to pick up an existing bit32 (Lua 5.2 / Luau)
  if type(_G.bit32) == "table" then
    bit32 = _G.bit32
  -- LuaJIT / Lua 5.1 executor with "bit" library
  elseif type(_G.bit) == "table" then
    local b = _G.bit
    bit32 = {
      band    = b.band,
      bor     = b.bor,
      bxor    = b.bxor,
      bnot    = function(a) return b.bnot(a) end,
      lshift  = function(a, n) return b.lshift(a, n % 32) end,
      rshift  = function(a, n) return b.rshift(a, n % 32) end,
      arshift = function(a, n) return b.arshift(a, n % 32) end,
      btest   = function(a, c) return b.band(a, c) ~= 0 end,
      extract = function(v, f, w)
        w = w or 1
        return b.rshift(b.band(v, b.lshift(b.lshift(1, w) - 1, f)), f)
      end,
      replace = function(v, r, f, w)
        w = w or 1
        local mask = b.lshift(b.lshift(1, w) - 1, f)
        return b.bor(b.band(v, b.bnot(mask)), b.band(b.lshift(r, f), mask))
      end,
      lrotate = function(a, n)
        a = b.band(a, 0xFFFFFFFF); n = n % 32
        return b.band(b.bor(b.lshift(a, n), b.rshift(a, 32 - n)), 0xFFFFFFFF)
      end,
      rrotate = function(a, n)
        a = b.band(a, 0xFFFFFFFF); n = n % 32
        return b.band(b.bor(b.rshift(a, n), b.lshift(a, 32 - n)), 0xFFFFFFFF)
      end,
      countlz = function(a)
        a = b.band(a, 0xFFFFFFFF); if a == 0 then return 32 end
        local n = 0
        while b.rshift(a, 31) == 0 do a = b.lshift(a, 1); n = n + 1 end
        return n
      end,
      countrz = function(a)
        a = b.band(a, 0xFFFFFFFF); if a == 0 then return 32 end
        local n = 0
        while b.band(a, 1) == 0 do a = b.rshift(a, 1); n = n + 1 end
        return n
      end,
      byteswap = function(a)
        a = b.band(a, 0xFFFFFFFF)
        return b.bor(
          b.lshift(b.band(a, 0xFF), 24),
          b.lshift(b.band(b.rshift(a, 8),  0xFF), 16),
          b.lshift(b.band(b.rshift(a, 16), 0xFF), 8),
                   b.band(b.rshift(a, 24), 0xFF))
      end,
    }
  else
    -- Pure-Lua fallback using multiplication/modulo (works on all versions)
    local function uint32(n)
      n = n % 0x100000000
      if n < 0 then n = n + 0x100000000 end
      return n
    end
    local function lsh(a, n)
      if n >= 32 or n <= -32 then return 0 end
      if n < 0 then return math.floor(uint32(a) / 2^(-n)) end
      return uint32(a * 2^n) % 0x100000000
    end
    local function rsh(a, n) return lsh(a, -n) end
    local function band(a, b)
      local r, p = 0, 1
      a, b = uint32(a), uint32(b)
      for _ = 1, 32 do
        local ab, bb = a % 2, b % 2
        if ab == 1 and bb == 1 then r = r + p end
        a, b, p = math.floor(a/2), math.floor(b/2), p * 2
      end
      return r
    end
    local function bor(a, b)
      local r, p = 0, 1
      a, b = uint32(a), uint32(b)
      for _ = 1, 32 do
        if a % 2 == 1 or b % 2 == 1 then r = r + p end
        a, b, p = math.floor(a/2), math.floor(b/2), p * 2
      end
      return r
    end
    local function bxor(a, b)
      local r, p = 0, 1
      a, b = uint32(a), uint32(b)
      for _ = 1, 32 do
        if a % 2 ~= b % 2 then r = r + p end
        a, b, p = math.floor(a/2), math.floor(b/2), p * 2
      end
      return r
    end
    local function bnot(a) return uint32(0xFFFFFFFF - uint32(a) + 1) - 1 end
    bit32 = {
      band    = band,
      bor     = bor,
      bxor    = bxor,
      bnot    = bnot,
      lshift  = function(a, n) return lsh(uint32(a), n) end,
      rshift  = function(a, n) return rsh(uint32(a), n) end,
      arshift = function(a, n)
        a = uint32(a)
        if a >= 0x80000000 then a = a - 0x100000000 end
        local r = math.floor(a / 2^n)
        return uint32(r)
      end,
      btest   = function(a, b) return band(a, b) ~= 0 end,
      extract = function(v, f, w)
        w = w or 1
        return band(rsh(uint32(v), f), lsh(1, w) - 1)
      end,
      replace = function(v, r, f, w)
        w = w or 1
        local mask = lsh(lsh(1, w) - 1, f)
        return bor(band(uint32(v), bnot(mask)), band(lsh(r, f), mask))
      end,
      lrotate = function(a, n)
        a = uint32(a); n = n % 32
        return band(bor(lsh(a, n), rsh(a, 32 - n)), 0xFFFFFFFF)
      end,
      rrotate = function(a, n)
        a = uint32(a); n = n % 32
        return band(bor(rsh(a, n), lsh(a, 32 - n)), 0xFFFFFFFF)
      end,
      countlz = function(a)
        a = uint32(a); if a == 0 then return 32 end
        local n = 0
        while a < 0x80000000 do a = lsh(a, 1); n = n + 1 end
        return n
      end,
      countrz = function(a)
        a = uint32(a); if a == 0 then return 32 end
        local n = 0
        while band(a, 1) == 0 do a = rsh(a, 1); n = n + 1 end
        return n
      end,
      byteswap = function(a)
        a = uint32(a)
        return bor(lsh(band(a, 0xFF), 24),
                   lsh(band(rsh(a, 8),  0xFF), 16),
                   lsh(band(rsh(a, 16), 0xFF), 8),
                       band(rsh(a, 24), 0xFF))
      end,
    }
  end
end

-- ── Helper: portable integer right-shift wrapper ─────────────────────────────
local function bshr(a, n) return bit32.rshift(a, n) end
local function bshl(a, n) return bit32.lshift(a, n) end
local function band(a, b) return bit32.band(a, b) end
local function bor(a, b)  return bit32.bor(a, b) end

-- ── Lua 5.1 / unpack compat ──────────────────────────────────────────────────
local _unpack = table.unpack or unpack

-- ── Binary reader (replaces Roblox buffer.*) ─────────────────────────────────
local Reader = {}
Reader.__index = Reader

function Reader.new(bytes)
  return setmetatable({ _bytes = bytes, _pos = 1, _len = #bytes }, Reader)
end

function Reader:len()  return self._len end

local function _checkbounds(self, n)
  if self._pos + n - 1 > self._len then
    error(string.format("Reader OOB: need %d byte(s) at offset %d (buf len %d)",
      n, self._pos - 1, self._len), 3)
  end
end

function Reader:nextByte()
  _checkbounds(self, 1)
  local b = string.byte(self._bytes, self._pos)
  self._pos = self._pos + 1
  return b
end

function Reader:nextSignedByte()
  local b = self:nextByte()
  if b >= 128 then return b - 256 end
  return b
end

function Reader:nextBytes(count)
  local t = {}
  for i = 1, count do t[i] = self:nextByte() end
  return t
end

function Reader:nextChar()  return string.char(self:nextByte()) end

function Reader:nextUInt32()
  _checkbounds(self, 4)
  local a, b, c, d = string.byte(self._bytes, self._pos, self._pos + 3)
  self._pos = self._pos + 4
  return bor(a, bor(bshl(b, 8), bor(bshl(c, 16), bshl(d, 24))))
end

function Reader:nextInt32()
  local v = self:nextUInt32()
  if v >= 0x80000000 then return v - 0x100000000 end
  return v
end

function Reader:nextFloat()
  -- IEEE 754 single (4 bytes, little-endian)
  _checkbounds(self, 4)
  local a, b, c, d = string.byte(self._bytes, self._pos, self._pos + 3)
  self._pos = self._pos + 4
  local bits = bor(a, bor(bshl(b, 8), bor(bshl(c, 16), bshl(d, 24))))
  local sign  = bshr(bits, 31) == 1 and -1 or 1
  local exp   = band(bshr(bits, 23), 0xFF)
  local frac  = band(bits, 0x7FFFFF)
  local value
  if exp == 0 then
    value = sign * (frac / 0x800000) * 2^-126
  elseif exp == 255 then
    value = frac == 0 and (sign * math.huge) or (0/0)
  else
    value = sign * (1 + frac / 0x800000) * 2^(exp - 127)
  end
  return value
end

function Reader:nextVarInt()
  local result = 0
  for i = 0, 4 do
    local b = self:nextByte()
    result = bor(result, bshl(band(b, 0x7F), i * 7))
    if band(b, 0x80) == 0 then break end
  end
  return result
end

function Reader:nextString(slen)
  slen = slen or self:nextVarInt()
  if slen == 0 then return "" end
  _checkbounds(self, slen)
  local s = string.sub(self._bytes, self._pos, self._pos + slen - 1)
  self._pos = self._pos + slen
  return s
end

function Reader:nextDouble()
  -- IEEE 754 double (8 bytes, little-endian)
  -- We reconstruct the value directly from the two 32-bit halves
  _checkbounds(self, 8)
  local bytes = { string.byte(self._bytes, self._pos, self._pos + 7) }
  self._pos = self._pos + 8
  -- lo = bytes 1-4, hi = bytes 5-8
  local lo = bor(bytes[1], bor(bshl(bytes[2], 8), bor(bshl(bytes[3], 16), bshl(bytes[4], 24))))
  local hi = bor(bytes[5], bor(bshl(bytes[6], 8), bor(bshl(bytes[7], 16), bshl(bytes[8], 24))))
  -- make both unsigned
  if lo < 0 then lo = lo + 0x100000000 end
  if hi < 0 then hi = hi + 0x100000000 end
  local sign = (bshr(hi, 31) == 1) and -1 or 1
  local exp  = band(bshr(hi, 20), 0x7FF)
  -- fractional mantissa: top 20 bits from hi, all 32 bits of lo
  local frac_hi = band(hi, 0x000FFFFF)
  local frac = frac_hi * (2^32) + lo
  if exp == 0 then
    return sign * (frac / (2^52)) * 2^-1022
  elseif exp == 0x7FF then
    return frac == 0 and sign * math.huge or (0/0)
  else
    return sign * (1 + frac / (2^52)) * 2^(exp - 1023)
  end
end

-- ── Core decompiler ───────────────────────────────────────────────────────────
local FLOAT_PRECISION = 7

local function Reader_Set(fp) FLOAT_PRECISION = fp end

local Strings = {
  SUCCESS             = "%s",
  TIMEOUT             = "-- DECOMPILER TIMEOUT",
  COMPILATION_FAILURE = "-- SCRIPT FAILED TO COMPILE, ERROR:\n%s",
  UNSUPPORTED_LBC_VERSION = "-- PASSED BYTECODE IS TOO OLD AND IS NOT SUPPORTED",
  USED_GLOBALS        = "-- USED GLOBALS: %s.\n",
  DECOMPILER_REMARK   = "-- DECOMPILER REMARK: %s\n",
}

local CASE_MULTIPLIER = 227

local Luau = {
  OpCode = {
    {name="NOP",type="none"},{name="BREAK",type="none"},
    {name="LOADNIL",type="A"},{name="LOADB",type="ABC"},
    {name="LOADN",type="AsD"},{name="LOADK",type="AD"},
    {name="MOVE",type="AB"},
    {name="GETGLOBAL",type="AC",aux=true},{name="SETGLOBAL",type="AC",aux=true},
    {name="GETUPVAL",type="AB"},{name="SETUPVAL",type="AB"},
    {name="CLOSEUPVALS",type="A"},
    {name="GETIMPORT",type="AD",aux=true},
    {name="GETTABLE",type="ABC"},{name="SETTABLE",type="ABC"},
    {name="GETTABLEKS",type="ABC",aux=true},{name="SETTABLEKS",type="ABC",aux=true},
    {name="GETTABLEN",type="ABC"},{name="SETTABLEN",type="ABC"},
    {name="NEWCLOSURE",type="AD"},{name="NAMECALL",type="ABC",aux=true},
    {name="CALL",type="ABC"},{name="RETURN",type="AB"},
    {name="JUMP",type="sD"},{name="JUMPBACK",type="sD"},
    {name="JUMPIF",type="AsD"},{name="JUMPIFNOT",type="AsD"},
    {name="JUMPIFEQ",type="AsD",aux=true},{name="JUMPIFLE",type="AsD",aux=true},
    {name="JUMPIFLT",type="AsD",aux=true},{name="JUMPIFNOTEQ",type="AsD",aux=true},
    {name="JUMPIFNOTLE",type="AsD",aux=true},{name="JUMPIFNOTLT",type="AsD",aux=true},
    {name="ADD",type="ABC"},{name="SUB",type="ABC"},{name="MUL",type="ABC"},
    {name="DIV",type="ABC"},{name="MOD",type="ABC"},{name="POW",type="ABC"},
    {name="ADDK",type="ABC"},{name="SUBK",type="ABC"},{name="MULK",type="ABC"},
    {name="DIVK",type="ABC"},{name="MODK",type="ABC"},{name="POWK",type="ABC"},
    {name="AND",type="ABC"},{name="OR",type="ABC"},
    {name="ANDK",type="ABC"},{name="ORK",type="ABC"},
    {name="CONCAT",type="ABC"},
    {name="NOT",type="AB"},{name="MINUS",type="AB"},{name="LENGTH",type="AB"},
    {name="NEWTABLE",type="AB",aux=true},{name="DUPTABLE",type="AD"},
    {name="SETLIST",type="ABC",aux=true},
    {name="FORNPREP",type="AsD"},{name="FORNLOOP",type="AsD"},
    {name="FORGLOOP",type="AsD",aux=true},
    {name="FORGPREP_INEXT",type="A"},
    {name="FASTCALL3",type="ABC",aux=true},
    {name="FORGPREP_NEXT",type="A"},{name="NATIVECALL",type="none"},
    {name="GETVARARGS",type="AB"},{name="DUPCLOSURE",type="AD"},
    {name="PREPVARARGS",type="A"},{name="LOADKX",type="A",aux=true},
    {name="JUMPX",type="E"},{name="FASTCALL",type="AC"},
    {name="COVERAGE",type="E"},{name="CAPTURE",type="AB"},
    {name="SUBRK",type="ABC"},{name="DIVRK",type="ABC"},
    {name="FASTCALL1",type="ABC"},
    {name="FASTCALL2",type="ABC",aux=true},{name="FASTCALL2K",type="ABC",aux=true},
    {name="FORGPREP",type="AsD"},
    {name="JUMPXEQKNIL",type="AsD",aux=true},{name="JUMPXEQKB",type="AsD",aux=true},
    {name="JUMPXEQKN",type="AsD",aux=true},{name="JUMPXEQKS",type="AsD",aux=true},
    {name="IDIV",type="ABC"},{name="IDIVK",type="ABC"},
    {name="_COUNT",type="none"},
  },
  BytecodeTag = {
    LBC_VERSION_MIN=3, LBC_VERSION_MAX=6,
    LBC_TYPE_VERSION_MIN=1, LBC_TYPE_VERSION_MAX=3,
    LBC_CONSTANT_NIL=0, LBC_CONSTANT_BOOLEAN=1, LBC_CONSTANT_NUMBER=2,
    LBC_CONSTANT_STRING=3, LBC_CONSTANT_IMPORT=4, LBC_CONSTANT_TABLE=5,
    LBC_CONSTANT_CLOSURE=6, LBC_CONSTANT_VECTOR=7,
  },
  BytecodeType = {
    LBC_TYPE_NIL=0,LBC_TYPE_BOOLEAN=1,LBC_TYPE_NUMBER=2,LBC_TYPE_STRING=3,
    LBC_TYPE_TABLE=4,LBC_TYPE_FUNCTION=5,LBC_TYPE_THREAD=6,LBC_TYPE_USERDATA=7,
    LBC_TYPE_VECTOR=8,LBC_TYPE_BUFFER=9,LBC_TYPE_ANY=15,
    LBC_TYPE_TAGGED_USERDATA_BASE=64,LBC_TYPE_TAGGED_USERDATA_END=64+32,
    LBC_TYPE_OPTIONAL_BIT=0,  -- set after table init below
  },
  CaptureType  = {LCT_VAL=0,LCT_REF=1,LCT_UPVAL=2},
  BuiltinFunction = {
    LBF_NONE=0,LBF_ASSERT=1,LBF_MATH_ABS=2,LBF_MATH_ACOS=3,LBF_MATH_ASIN=4,
    LBF_MATH_ATAN2=5,LBF_MATH_ATAN=6,LBF_MATH_CEIL=7,LBF_MATH_COSH=8,
    LBF_MATH_COS=9,LBF_MATH_DEG=10,LBF_MATH_EXP=11,LBF_MATH_FLOOR=12,
    LBF_MATH_FMOD=13,LBF_MATH_FREXP=14,LBF_MATH_LDEXP=15,LBF_MATH_LOG10=16,
    LBF_MATH_LOG=17,LBF_MATH_MAX=18,LBF_MATH_MIN=19,LBF_MATH_MODF=20,
    LBF_MATH_POW=21,LBF_MATH_RAD=22,LBF_MATH_SINH=23,LBF_MATH_SIN=24,
    LBF_MATH_SQRT=25,LBF_MATH_TANH=26,LBF_MATH_TAN=27,
    LBF_BIT32_ARSHIFT=28,LBF_BIT32_BAND=29,LBF_BIT32_BNOT=30,LBF_BIT32_BOR=31,
    LBF_BIT32_BXOR=32,LBF_BIT32_BTEST=33,LBF_BIT32_EXTRACT=34,
    LBF_BIT32_LROTATE=35,LBF_BIT32_LSHIFT=36,LBF_BIT32_REPLACE=37,
    LBF_BIT32_RROTATE=38,LBF_BIT32_RSHIFT=39,LBF_TYPE=40,
    LBF_STRING_BYTE=41,LBF_STRING_CHAR=42,LBF_STRING_LEN=43,LBF_TYPEOF=44,
    LBF_STRING_SUB=45,LBF_MATH_CLAMP=46,LBF_MATH_SIGN=47,LBF_MATH_ROUND=48,
    LBF_RAWSET=49,LBF_RAWGET=50,LBF_RAWEQUAL=51,LBF_TABLE_INSERT=52,
    LBF_TABLE_UNPACK=53,LBF_VECTOR=54,LBF_BIT32_COUNTLZ=55,LBF_BIT32_COUNTRZ=56,
    LBF_SELECT_VARARG=57,LBF_RAWLEN=58,LBF_BIT32_EXTRACTK=59,
    LBF_GETMETATABLE=60,LBF_SETMETATABLE=61,LBF_TONUMBER=62,LBF_TOSTRING=63,
    LBF_BIT32_BYTESWAP=64,
    LBF_BUFFER_READI8=65,LBF_BUFFER_READU8=66,LBF_BUFFER_WRITEU8=67,
    LBF_BUFFER_READI16=68,LBF_BUFFER_READU16=69,LBF_BUFFER_WRITEU16=70,
    LBF_BUFFER_READI32=71,LBF_BUFFER_READU32=72,LBF_BUFFER_WRITEU32=73,
    LBF_BUFFER_READF32=74,LBF_BUFFER_WRITEF32=75,LBF_BUFFER_READF64=76,
    LBF_BUFFER_WRITEF64=77,
    LBF_VECTOR_MAGNITUDE=78,LBF_VECTOR_NORMALIZE=79,LBF_VECTOR_CROSS=80,
    LBF_VECTOR_DOT=81,LBF_VECTOR_FLOOR=82,LBF_VECTOR_CEIL=83,
    LBF_VECTOR_ABS=84,LBF_VECTOR_SIGN=85,LBF_VECTOR_CLAMP=86,
    LBF_VECTOR_MIN=87,LBF_VECTOR_MAX=88,
  },
  ProtoFlag = {
    LPF_NATIVE_MODULE   = bit32.lshift(1,0),
    LPF_NATIVE_COLD     = bit32.lshift(1,1),
    LPF_NATIVE_FUNCTION = bit32.lshift(1,2),
  },
}
-- Deferred init: bit32 is available now
Luau.BytecodeType.LBC_TYPE_OPTIONAL_BIT = bit32.lshift(1, 7)
Luau.BytecodeType.LBC_TYPE_INVALID = 256

function Luau:INSN_OP(i)  return band(i, 0xFF) end
function Luau:INSN_A(i)   return band(bshr(i, 8), 0xFF) end
function Luau:INSN_B(i)   return band(bshr(i, 16), 0xFF) end
function Luau:INSN_C(i)   return band(bshr(i, 24), 0xFF) end
function Luau:INSN_D(i)   return bshr(i, 16) end
function Luau:INSN_sD(i)
  local D = self:INSN_D(i)
  return (D > 0x7FFF and D <= 0xFFFF) and (-(0xFFFF - D) - 1) or D
end
function Luau:INSN_E(i)   return bshr(i, 8) end

function Luau:GetBaseTypeString(t, checkOpt)
  local BT = self.BytecodeType
  local tag = band(t, band(bit32.bnot(BT.LBC_TYPE_OPTIONAL_BIT), 0xFF))
  local names = {
    [BT.LBC_TYPE_NIL]="nil", [BT.LBC_TYPE_BOOLEAN]="boolean",
    [BT.LBC_TYPE_NUMBER]="number", [BT.LBC_TYPE_STRING]="string",
    [BT.LBC_TYPE_TABLE]="table", [BT.LBC_TYPE_FUNCTION]="function",
    [BT.LBC_TYPE_THREAD]="thread", [BT.LBC_TYPE_USERDATA]="userdata",
    [BT.LBC_TYPE_VECTOR]="Vector3", [BT.LBC_TYPE_BUFFER]="buffer",
    [BT.LBC_TYPE_ANY]="any"
  }
  local r = names[tag] or "unknown"
  if checkOpt then
    r = r .. (band(t, BT.LBC_TYPE_OPTIONAL_BIT) == 0 and "" or "?")
  end
  return r
end

function Luau:GetBuiltinInfo(bfid)
  local BF = self.BuiltinFunction
  local map = {
    [BF.LBF_NONE]="none",[BF.LBF_ASSERT]="assert",
    [BF.LBF_TYPE]="type",[BF.LBF_TYPEOF]="typeof",
    [BF.LBF_RAWSET]="rawset",[BF.LBF_RAWGET]="rawget",
    [BF.LBF_RAWEQUAL]="rawequal",[BF.LBF_RAWLEN]="rawlen",
    [BF.LBF_TABLE_UNPACK]="unpack",[BF.LBF_SELECT_VARARG]="select",
    [BF.LBF_GETMETATABLE]="getmetatable",[BF.LBF_SETMETATABLE]="setmetatable",
    [BF.LBF_TONUMBER]="tonumber",[BF.LBF_TOSTRING]="tostring",
    [BF.LBF_MATH_ABS]="math.abs",[BF.LBF_MATH_ACOS]="math.acos",
    [BF.LBF_MATH_ASIN]="math.asin",[BF.LBF_MATH_ATAN2]="math.atan2",
    [BF.LBF_MATH_ATAN]="math.atan",[BF.LBF_MATH_CEIL]="math.ceil",
    [BF.LBF_MATH_COSH]="math.cosh",[BF.LBF_MATH_COS]="math.cos",
    [BF.LBF_MATH_DEG]="math.deg",[BF.LBF_MATH_EXP]="math.exp",
    [BF.LBF_MATH_FLOOR]="math.floor",[BF.LBF_MATH_FMOD]="math.fmod",
    [BF.LBF_MATH_FREXP]="math.frexp",[BF.LBF_MATH_LDEXP]="math.ldexp",
    [BF.LBF_MATH_LOG10]="math.log10",[BF.LBF_MATH_LOG]="math.log",
    [BF.LBF_MATH_MAX]="math.max",[BF.LBF_MATH_MIN]="math.min",
    [BF.LBF_MATH_MODF]="math.modf",[BF.LBF_MATH_POW]="math.pow",
    [BF.LBF_MATH_RAD]="math.rad",[BF.LBF_MATH_SINH]="math.sinh",
    [BF.LBF_MATH_SIN]="math.sin",[BF.LBF_MATH_SQRT]="math.sqrt",
    [BF.LBF_MATH_TANH]="math.tanh",[BF.LBF_MATH_TAN]="math.tan",
    [BF.LBF_MATH_CLAMP]="math.clamp",[BF.LBF_MATH_SIGN]="math.sign",
    [BF.LBF_MATH_ROUND]="math.round",
    [BF.LBF_BIT32_ARSHIFT]="bit32.arshift",[BF.LBF_BIT32_BAND]="bit32.band",
    [BF.LBF_BIT32_BNOT]="bit32.bnot",[BF.LBF_BIT32_BOR]="bit32.bor",
    [BF.LBF_BIT32_BXOR]="bit32.bxor",[BF.LBF_BIT32_BTEST]="bit32.btest",
    [BF.LBF_BIT32_EXTRACT]="bit32.extract",[BF.LBF_BIT32_EXTRACTK]="bit32.extract",
    [BF.LBF_BIT32_LROTATE]="bit32.lrotate",[BF.LBF_BIT32_LSHIFT]="bit32.lshift",
    [BF.LBF_BIT32_REPLACE]="bit32.replace",[BF.LBF_BIT32_RROTATE]="bit32.rrotate",
    [BF.LBF_BIT32_RSHIFT]="bit32.rshift",[BF.LBF_BIT32_COUNTLZ]="bit32.countlz",
    [BF.LBF_BIT32_COUNTRZ]="bit32.countrz",[BF.LBF_BIT32_BYTESWAP]="bit32.byteswap",
    [BF.LBF_STRING_BYTE]="string.byte",[BF.LBF_STRING_CHAR]="string.char",
    [BF.LBF_STRING_LEN]="string.len",[BF.LBF_STRING_SUB]="string.sub",
    [BF.LBF_TABLE_INSERT]="table.insert",[BF.LBF_VECTOR]="Vector3.new",
    [BF.LBF_BUFFER_READI8]="buffer.readi8",[BF.LBF_BUFFER_READU8]="buffer.readu8",
    [BF.LBF_BUFFER_WRITEU8]="buffer.writeu8",[BF.LBF_BUFFER_READI16]="buffer.readi16",
    [BF.LBF_BUFFER_READU16]="buffer.readu16",[BF.LBF_BUFFER_WRITEU16]="buffer.writeu16",
    [BF.LBF_BUFFER_READI32]="buffer.readi32",[BF.LBF_BUFFER_READU32]="buffer.readu32",
    [BF.LBF_BUFFER_WRITEU32]="buffer.writeu32",[BF.LBF_BUFFER_READF32]="buffer.readf32",
    [BF.LBF_BUFFER_WRITEF32]="buffer.writef32",[BF.LBF_BUFFER_READF64]="buffer.readf64",
    [BF.LBF_BUFFER_WRITEF64]="buffer.writef64",
    [BF.LBF_VECTOR_MAGNITUDE]="vector.magnitude",[BF.LBF_VECTOR_NORMALIZE]="vector.normalize",
    [BF.LBF_VECTOR_CROSS]="vector.cross",[BF.LBF_VECTOR_DOT]="vector.dot",
    [BF.LBF_VECTOR_FLOOR]="vector.floor",[BF.LBF_VECTOR_CEIL]="vector.ceil",
    [BF.LBF_VECTOR_ABS]="vector.abs",[BF.LBF_VECTOR_SIGN]="vector.sign",
    [BF.LBF_VECTOR_CLAMP]="vector.clamp",[BF.LBF_VECTOR_MIN]="vector.min",
    [BF.LBF_VECTOR_MAX]="vector.max",
  }
  return map[bfid] or ("builtin#"..tostring(bfid))
end

-- Encode OpCode table with case multiplier
do
  local raw = Luau.OpCode
  local encoded = {}
  for i, v in ipairs(raw) do
    local case = band((i - 1) * CASE_MULTIPLIER, 0xFF)
    encoded[case] = v
  end
  Luau.OpCode = encoded
end

local DEFAULT_OPTIONS = {
  EnabledRemarks       = {ColdRemark=false, InlineRemark=true},
  DecompilerTimeout    = 10,
  DecompilerMode       = "disasm",
  ReaderFloatPrecision = 7,
  ShowDebugInformation = false,
  ShowInstructionLines = false,
  ShowOperationIndex   = false,
  ShowOperationNames   = false,
  ShowTrivialOperations= false,
  UseTypeInfo          = true,
  ListUsedGlobals      = true,
  ReturnElapsedTime    = false,
  CleanMode            = true,
}

local LuauOpCode       = Luau.OpCode
local LuauBytecodeTag  = Luau.BytecodeTag
local LuauBytecodeType = Luau.BytecodeType
local LuauCaptureType  = Luau.CaptureType
local LuauProtoFlag    = Luau.ProtoFlag

local function toBoolean(v)     return v ~= 0 end
local function toEscapedString(v)
  if type(v) == "string" then return string.format("%q", v) end
  return tostring(v)
end
local function formatIndexString(key)
  if type(key) == "string" and key:match("^[%a_][%w_]*$") then
    return "." .. key
  end
  return "[" .. toEscapedString(key) .. "]"
end
local function padLeft(v, ch, n)
  local s = tostring(v); return string.rep(ch, math.max(0, n - #s)) .. s
end
local function padRight(v, ch, n)
  local s = tostring(v); return s .. string.rep(ch, math.max(0, n - #s))
end

local ROBLOX_GLOBALS = {
  "game","workspace","script","plugin","settings","shared","UserSettings",
  "print","warn","error","assert","pcall","xpcall","require","select",
  "pairs","ipairs","next","unpack","type","typeof","tostring","tonumber",
  "setmetatable","getmetatable","rawset","rawget","rawequal","rawlen",
  "math","table","string","bit32","coroutine","os","utf8","task","buffer",
  "Instance","Enum","Vector3","Vector2","CFrame","Color3","BrickColor",
  "UDim","UDim2","Ray","Axes","Faces","NumberRange","NumberSequence",
  "ColorSequence","TweenInfo","RaycastParams","OverlapParams",
  "tick","time","wait","delay","spawn","_G","_VERSION",
}
local function isGlobal(key)
  for _, v in ipairs(ROBLOX_GLOBALS) do if v == key then return true end end
  return false
end

local function Decompile(bytecode, options)
  local bytecodeVersion, typeEncodingVersion
  Reader_Set(options.ReaderFloatPrecision)
  local reader = Reader.new(bytecode)

  local function disassemble()
    if bytecodeVersion >= 4 then
      typeEncodingVersion = reader:nextByte()
    end
    local stringTable = {}
    local function readStringTable()
      local n = reader:nextVarInt()
      for i = 1, n do stringTable[i] = reader:nextString() end
    end
    local userdataTypes = {}
    local function readUserdataTypes()
      while true do
        local idx = reader:nextByte()
        if idx == 0 then break end
        userdataTypes[idx] = reader:nextVarInt()
      end
    end
    local protoTable = {}
    local function readProtoTable()
      local n = reader:nextVarInt()
      for i = 1, n do
        local protoId = i - 1
        local proto = {
          id=protoId, instructions={}, constants={},
          captures={}, innerProtos={}, instructionLineInfo={},
        }
        protoTable[protoId] = proto
        proto.maxStackSize  = reader:nextByte()
        proto.numParams     = reader:nextByte()
        proto.numUpvalues   = reader:nextByte()
        proto.isVarArg      = toBoolean(reader:nextByte())
        if bytecodeVersion >= 4 then
          proto.flags = reader:nextByte()
          local resultTypedParams, resultTypedUpvalues, resultTypedLocals = {}, {}, {}
          local allTypeInfoSize = reader:nextVarInt()
          local hasTypeInfo = allTypeInfoSize > 0
          proto.hasTypeInfo = hasTypeInfo
          if hasTypeInfo then
            local totalTypedParams   = allTypeInfoSize
            local totalTypedUpvalues = 0
            local totalTypedLocals   = 0
            if typeEncodingVersion and typeEncodingVersion > 1 then
              totalTypedParams   = reader:nextVarInt()
              totalTypedUpvalues = reader:nextVarInt()
              totalTypedLocals   = reader:nextVarInt()
            end
            if totalTypedParams > 0 then
              resultTypedParams = reader:nextBytes(totalTypedParams)
              table.remove(resultTypedParams, 1)
              table.remove(resultTypedParams, 1)
            end
            for j = 1, totalTypedUpvalues do
              resultTypedUpvalues[j] = {type=reader:nextByte()}
            end
            for j = 1, totalTypedLocals do
              local lt  = reader:nextByte()
              local lr  = reader:nextByte()
              local lsp = reader:nextVarInt() + 1
              local lep = reader:nextVarInt() + lsp - 1
              resultTypedLocals[j] = {type=lt, register=lr, startPC=lsp}
            end
          end
          proto.typedParams   = resultTypedParams
          proto.typedUpvalues = resultTypedUpvalues
          proto.typedLocals   = resultTypedLocals
        end
        proto.sizeInstructions = reader:nextVarInt()
        for j = 1, proto.sizeInstructions do
          proto.instructions[j] = reader:nextUInt32()
        end
        proto.sizeConstants = reader:nextVarInt()
        for j = 1, proto.sizeConstants do
          local constType  = reader:nextByte()
          local constValue
          local BT = LuauBytecodeTag
          if constType == BT.LBC_CONSTANT_BOOLEAN then
            constValue = toBoolean(reader:nextByte())
          elseif constType == BT.LBC_CONSTANT_NUMBER then
            constValue = reader:nextDouble()
          elseif constType == BT.LBC_CONSTANT_STRING then
            constValue = stringTable[reader:nextVarInt()]
          elseif constType == BT.LBC_CONSTANT_IMPORT then
            local id = reader:nextUInt32()
            local idxCount = bshr(id, 30)
            local ci1 = band(bshr(id, 20), 0x3FF)
            local ci2 = band(bshr(id, 10), 0x3FF)
            local ci3 = band(id, 0x3FF)
            local tag = ""
            local function kv(idx) return proto.constants[idx+1] end
            if     idxCount == 1 then tag = tostring(kv(ci1) and kv(ci1).value or "")
            elseif idxCount == 2 then tag = tostring(kv(ci1) and kv(ci1).value or "")
              ..".."..tostring(kv(ci2) and kv(ci2).value or "")
            elseif idxCount == 3 then tag = tostring(kv(ci1) and kv(ci1).value or "")
              .."."..tostring(kv(ci2) and kv(ci2).value or "")
              .."."..tostring(kv(ci3) and kv(ci3).value or "")
            end
            constValue = tag
          elseif constType == BT.LBC_CONSTANT_TABLE then
            local sz = reader:nextVarInt()
            local keys = {}
            for k = 1, sz do keys[k] = reader:nextVarInt()+1 end
            constValue = {size=sz, keys=keys}
          elseif constType == BT.LBC_CONSTANT_CLOSURE then
            constValue = reader:nextVarInt() + 1
          elseif constType == BT.LBC_CONSTANT_VECTOR then
            local x,y,z,w = reader:nextFloat(),reader:nextFloat(),reader:nextFloat(),reader:nextFloat()
            constValue = w == 0 and ("Vector3.new("..x..","..y..","..z..")")
              or ("vector.create("..x..","..y..","..z..","..w..")")
          end
          proto.constants[j] = {type=constType, value=constValue}
        end
        proto.sizeInnerProtos = reader:nextVarInt()
        for j = 1, proto.sizeInnerProtos do
          proto.innerProtos[j] = protoTable[reader:nextVarInt()]
        end
        proto.lineDefined = reader:nextVarInt()
        local nameId = reader:nextVarInt()
        proto.name = stringTable[nameId]
        local hasLineInfo = toBoolean(reader:nextByte())
        proto.hasLineInfo = hasLineInfo
        if hasLineInfo then
          local lgap = reader:nextByte()
          local baselineSize = bshr(proto.sizeInstructions - 1, lgap) + 1
          local smallLineInfo, absLineInfo = {}, {}
          local lastOffset, lastLine = 0, 0
          for j = 1, proto.sizeInstructions do
            local b = reader:nextSignedByte()
            lastOffset = lastOffset + b
            smallLineInfo[j] = lastOffset
          end
          for j = 1, baselineSize do
            local lc = lastLine + reader:nextInt32()
            absLineInfo[j-1] = lc
            lastLine = lc
          end
          local resultLineInfo = {}
          for j, line in ipairs(smallLineInfo) do
            local absIdx = bshr(j - 1, lgap)
            local absLine = absLineInfo[absIdx]
            local rl = line + absLine
            if lgap <= 1 and (-line == absLine) then
              rl = rl + (absLineInfo[absIdx+1] or 0)
            end
            if rl <= 0 then rl = rl + 0x100 end
            resultLineInfo[j] = rl
          end
          proto.lineInfoSize = lgap
          proto.instructionLineInfo = resultLineInfo
        end
        local hasDebugInfo = toBoolean(reader:nextByte())
        proto.hasDebugInfo = hasDebugInfo
        if hasDebugInfo then
          local totalLocals = reader:nextVarInt()
          local debugLocals = {}
          for j = 1, totalLocals do
            debugLocals[j] = {
              name     = stringTable[reader:nextVarInt()],
              startPC  = reader:nextVarInt(),
              endPC    = reader:nextVarInt(),
              register = reader:nextByte(),
            }
          end
          proto.debugLocals = debugLocals
          local totalUpvals = reader:nextVarInt()
          local debugUpvalues = {}
          for j = 1, totalUpvals do
            debugUpvalues[j] = {name=stringTable[reader:nextVarInt()]}
          end
          proto.debugUpvalues = debugUpvalues
        end
      end
    end
    readStringTable()
    if bytecodeVersion and bytecodeVersion > 5 then readUserdataTypes() end
    readProtoTable()
    local mainProtoId = reader:nextVarInt()
    return mainProtoId, protoTable
  end

  local function organize()
    local mainProtoId, protoTable = disassemble()
    local mainProto = protoTable[mainProtoId]
    mainProto.main = true
    local registerActions = {}
    local function baseProto(proto)
      local protoRegisterActions = {}
      registerActions[proto.id] = {proto=proto, actions=protoRegisterActions}
      local instructions = proto.instructions
      local innerProtos  = proto.innerProtos
      local constants    = proto.constants
      local captures     = proto.captures
      local flags        = proto.flags
      local function collectCaptures(baseIdx, p)
        local nup = p.numUpvalues
        if nup > 0 then
          local _c = p.captures
          for j = 1, nup do
            local cap = instructions[baseIdx + j]
            local ctype = Luau:INSN_A(cap)
            local sreg  = Luau:INSN_B(cap)
            if ctype == LuauCaptureType.LCT_VAL or ctype == LuauCaptureType.LCT_REF then
              _c[j-1] = sreg
            elseif ctype == LuauCaptureType.LCT_UPVAL then
              _c[j-1] = captures[sreg]
            end
          end
        end
      end
      local function writeFlags()
        if type(flags) == "table" then return end
        local rawFlags = type(flags) == "number" and flags or 0
        local df = {}
        if proto.main then
          df.native = toBoolean(band(rawFlags, LuauProtoFlag.LPF_NATIVE_MODULE))
        else
          df.native = toBoolean(band(rawFlags, LuauProtoFlag.LPF_NATIVE_FUNCTION))
          df.cold   = toBoolean(band(rawFlags, LuauProtoFlag.LPF_NATIVE_COLD))
        end
        flags = df; proto.flags = df
      end
      local function writeInstructions()
        local auxSkip = false
        local function reg(act, regs, extra, hide)
          table.insert(protoRegisterActions, {
            usedRegisters=regs or {}, extraData=extra,
            opCode=act, hide=hide
          })
        end
        for idx, instruction in ipairs(instructions) do
          repeat  -- repeat/until true used as a continue-able block (break = continue)
          if auxSkip then auxSkip=false; break end
          local oci = LuauOpCode[Luau:INSN_OP(instruction)]
          if not oci then break end
          local opn  = oci.name
          local opt  = oci.type
          local isAux= oci.aux == true
          local A,B,C,sD,D,E,aux
          if     opt=="A"   then A=Luau:INSN_A(instruction)
          elseif opt=="E"   then E=Luau:INSN_E(instruction)
          elseif opt=="AB"  then A=Luau:INSN_A(instruction); B=Luau:INSN_B(instruction)
          elseif opt=="AC"  then A=Luau:INSN_A(instruction); C=Luau:INSN_C(instruction)
          elseif opt=="ABC" then A=Luau:INSN_A(instruction); B=Luau:INSN_B(instruction); C=Luau:INSN_C(instruction)
          elseif opt=="AD"  then A=Luau:INSN_A(instruction); D=Luau:INSN_D(instruction)
          elseif opt=="AsD" then A=Luau:INSN_A(instruction); sD=Luau:INSN_sD(instruction)
          elseif opt=="sD"  then sD=Luau:INSN_sD(instruction)
          end
          if isAux then
            auxSkip=true; reg(oci,nil,nil,true)
            aux=instructions[idx+1]
          end
          local st = not options.ShowTrivialOperations
          if opn=="NOP" or opn=="BREAK" or opn=="NATIVECALL" then reg(oci,nil,nil,st)
          elseif opn=="LOADNIL" then reg(oci,{A})
          elseif opn=="LOADB"   then reg(oci,{A},{B,C})
          elseif opn=="LOADN"   then reg(oci,{A},{sD})
          elseif opn=="LOADK"   then reg(oci,{A},{D})
          elseif opn=="MOVE"    then reg(oci,{A,B})
          elseif opn=="GETGLOBAL" or opn=="SETGLOBAL" then reg(oci,{A},{aux})
          elseif opn=="GETUPVAL" or opn=="SETUPVAL"  then reg(oci,{A},{B})
          elseif opn=="CLOSEUPVALS" then reg(oci,{A},nil,st)
          elseif opn=="GETIMPORT" then reg(oci,{A},{D,aux})
          elseif opn=="GETTABLE" or opn=="SETTABLE" then reg(oci,{A,B,C})
          elseif opn=="GETTABLEKS" or opn=="SETTABLEKS" then reg(oci,{A,B},{C,aux})
          elseif opn=="GETTABLEN" or opn=="SETTABLEN" then reg(oci,{A,B},{C})
          elseif opn=="NEWCLOSURE" then
            reg(oci,{A},{D})
            local p2=innerProtos[D+1]
            if p2 then collectCaptures(idx,p2); baseProto(p2) end
          elseif opn=="DUPCLOSURE" then
            reg(oci,{A},{D})
            local c=constants[D+1]
            if c then local p2=protoTable[c.value-1]; if p2 then collectCaptures(idx,p2); baseProto(p2) end end
          elseif opn=="NAMECALL"  then reg(oci,{A,B},{C,aux},st)
          elseif opn=="CALL"      then reg(oci,{A},{B,C})
          elseif opn=="RETURN"    then reg(oci,{A},{B})
          elseif opn=="JUMP" or opn=="JUMPBACK" then reg(oci,{},{sD})
          elseif opn=="JUMPIF" or opn=="JUMPIFNOT" then reg(oci,{A},{sD})
          elseif opn=="JUMPIFEQ" or opn=="JUMPIFLE" or opn=="JUMPIFLT"
              or opn=="JUMPIFNOTEQ" or opn=="JUMPIFNOTLE" or opn=="JUMPIFNOTLT" then
            reg(oci,{A,aux},{sD})
          elseif opn=="ADD" or opn=="SUB" or opn=="MUL" or opn=="DIV"
              or opn=="MOD" or opn=="POW" then reg(oci,{A,B,C})
          elseif opn=="ADDK" or opn=="SUBK" or opn=="MULK" or opn=="DIVK"
              or opn=="MODK" or opn=="POWK" then reg(oci,{A,B},{C})
          elseif opn=="AND" or opn=="OR" then reg(oci,{A,B,C})
          elseif opn=="ANDK" or opn=="ORK" then reg(oci,{A,B},{C})
          elseif opn=="CONCAT" then
            local regs={A}
            for r=B,C do table.insert(regs,r) end
            reg(oci,regs)
          elseif opn=="NOT" or opn=="MINUS" or opn=="LENGTH" then reg(oci,{A,B})
          elseif opn=="NEWTABLE" then reg(oci,{A},{B,aux})
          elseif opn=="DUPTABLE" then reg(oci,{A},{D})
          elseif opn=="SETLIST"  then
            if C~=0 then
              local regs={A,B}
              for k=1,C-2 do table.insert(regs,A+k) end
              reg(oci,regs,{aux,C})
            else reg(oci,{A,B},{aux,C}) end
          elseif opn=="FORNPREP" then reg(oci,{A,A+1,A+2},{sD})
          elseif opn=="FORNLOOP" then reg(oci,{A},{sD})
          elseif opn=="FORGLOOP" then
            local nv=band(aux or 0,0xFF)
            local regs={}
            for k=1,nv do table.insert(regs,A+k) end
            reg(oci,regs,{sD,aux})
          elseif opn=="FORGPREP_INEXT" or opn=="FORGPREP_NEXT" then reg(oci,{A,A+1})
          elseif opn=="FORGPREP"  then reg(oci,{A},{sD})
          elseif opn=="GETVARARGS" then
            if B~=0 then
              local regs={A}
              for k=0,B-1 do table.insert(regs,A+k) end
              reg(oci,regs,{B})
            else reg(oci,{A},{B}) end
          elseif opn=="PREPVARARGS" then reg(oci,{},{A},st)
          elseif opn=="LOADKX"  then reg(oci,{A},{aux})
          elseif opn=="JUMPX"   then reg(oci,{},{E})
          elseif opn=="COVERAGE" then reg(oci,{},{E},st)
          elseif opn=="JUMPXEQKNIL" or opn=="JUMPXEQKB"
              or opn=="JUMPXEQKN"   or opn=="JUMPXEQKS" then
            reg(oci,{A},{sD,aux})
          elseif opn=="CAPTURE" then reg(oci,nil,nil,st)
          elseif opn=="SUBRK" or opn=="DIVRK" then reg(oci,{A,C},{B})
          elseif opn=="IDIV"  then reg(oci,{A,B,C})
          elseif opn=="IDIVK" then reg(oci,{A,B},{C})
          elseif opn=="FASTCALL"  then reg(oci,{},{A,C},st)
          elseif opn=="FASTCALL1" then reg(oci,{B},{A,C},st)
          elseif opn=="FASTCALL2" then
            local r2=band(aux or 0,0xFF)
            reg(oci,{B,r2},{A,C},st)
          elseif opn=="FASTCALL2K" then reg(oci,{B},{A,C,aux},st)
          elseif opn=="FASTCALL3" then
            local r2=band(aux or 0,0xFF)
            local r3=bshr(r2,8)
            reg(oci,{B,r2,r3},{A,C},st)
          end
          until true  -- end of continue block
        end
      end
      writeFlags()
      writeInstructions()
    end
    baseProto(mainProto)
    return mainProtoId, registerActions, protoTable
  end

  local function finalize(mainProtoId, registerActions, protoTable)
    local finalResult = ""
    local totalParameters = 0
    local usedGlobals    = {}
    local usedGlobalsSet = {}
    local function isValidGlobal(key)
      if usedGlobalsSet[key] then return false end
      return not isGlobal(key)
    end
    local function processResult(res)
      local embed = ""
      if options.ListUsedGlobals and #usedGlobals > 0 then
        embed = string.format(Strings.USED_GLOBALS, table.concat(usedGlobals, ", "))
      end
      return embed .. res
    end
    if options.DecompilerMode == "disasm" then
      local resultParts = {}
      local function emit(s) resultParts[#resultParts + 1] = s end
      local function writeActions(protoActions)
        local actions  = protoActions.actions
        local proto    = protoActions.proto
        local lineInfo = proto.instructionLineInfo
        local inner    = proto.innerProtos
        local consts   = proto.constants
        local caps     = proto.captures
        local pflags   = proto.flags
        local numParams= proto.numParams
        local jumpMarkers = {}
        local function makeJump(idx) idx=idx-1; jumpMarkers[idx]=(jumpMarkers[idx] or 0)+1 end
        totalParameters = totalParameters + numParams
        if proto.main and pflags and pflags.native then emit("--!native\n") end

        local function buildRegNames(instrIdx)
          local names = {}
          if proto.debugLocals then
            for _, dl in ipairs(proto.debugLocals) do
              if instrIdx >= dl.startPC and instrIdx <= dl.endPC then
                names[dl.register] = dl.name
              end
            end
          end
          return names
        end
        local function fmtUpv(r)
          if r == nil then return "upv_unknown" end
          local du = proto.debugUpvalues
          if du then
            local entry = du[r + 1]
            if entry and entry.name and entry.name ~= "" then
              return entry.name
            end
          end
          local capturedReg = caps[r]
          if capturedReg ~= nil and proto.debugLocals then
            for _, dl in ipairs(proto.debugLocals) do
              if dl.register == capturedReg and dl.name and dl.name ~= "" then
                return dl.name
              end
            end
          end
          return "upv_" .. tostring(r)
        end
        local regNameCache = {}
        local function fmtReg(r, instrIdx)
          if instrIdx and proto.debugLocals then
            local cached = regNameCache[instrIdx]
            if not cached then
              cached = buildRegNames(instrIdx)
              regNameCache[instrIdx] = cached
            end
            if cached[r] and cached[r] ~= "" then
              return cached[r]
            end
          end
          local pr = r + 1
          if pr < numParams + 1 then
            return "p"..((totalParameters - numParams) + pr)
          end
          return "v"..(r - numParams)
        end
        local function paramName(j)
          if proto.debugLocals then
            for _, dl in ipairs(proto.debugLocals) do
              if dl.startPC == 0 and dl.register == j-1 then
                return dl.name
              end
            end
          end
          return "p"..(totalParameters + j)
        end
        local function fmtConst(k)
          if not k then return "nil" end
          if k.type == LuauBytecodeTag.LBC_CONSTANT_VECTOR then
            return tostring(k.value)
          end
          if type(tonumber(k.value)) == "number" then
            return tostring(tonumber(string.format("%0."..options.ReaderFloatPrecision.."f", k.value)))
          end
          local s = toEscapedString(k.value)
          if k.type == LuauBytecodeTag.LBC_CONSTANT_IMPORT then
            s = s:gsub("%.%.+", "."):gsub("^%.", ""):gsub("%.$", "")
          end
          return s
        end
        local function fmtProto(p)
          local body = ""
          if p.flags and p.flags.native then
            if p.flags.cold and options.EnabledRemarks and options.EnabledRemarks.ColdRemark then
              body = body .. string.format(Strings.DECOMPILER_REMARK,
                "This function is marked cold and is not compiled natively")
            end
            body = body .. "@native "
          end
          if p.name then body = "local function " .. p.name
          else body = "function" end
          body = body .. "("
          for j = 1, p.numParams do
            local pb = paramName(j)
            if p.hasTypeInfo and options.UseTypeInfo and p.typedParams and p.typedParams[j] then
              pb = pb .. ": " .. Luau:GetBaseTypeString(p.typedParams[j], true)
            end
            if j ~= p.numParams then pb = pb .. ", " end
            body = body .. pb
          end
          if p.isVarArg then
            body = body .. ((p.numParams > 0) and ", ..." or "...")
          end
          body = body .. ")\n"
          if options.ShowDebugInformation then
            body = body .. "-- proto pool id: "..p.id.."\n"
            body = body .. "-- num upvalues: "..p.numUpvalues.."\n"
            body = body .. "-- num inner protos: "..(p.sizeInnerProtos or 0).."\n"
            body = body .. "-- size instructions: "..(p.sizeInstructions or 0).."\n"
            body = body .. "-- size constants: "..(p.sizeConstants or 0).."\n"
            body = body .. "-- lineinfo gap: "..(p.lineInfoSize or "n/a").."\n"
            body = body .. "-- max stack size: "..p.maxStackSize.."\n"
            body = body .. "-- is typed: "..tostring(p.hasTypeInfo).."\n"
          end
          return body
        end
        local function writeProto(reg, p)
          local body = fmtProto(p)
          if p.name then
            emit("\n"..body)
            writeActions(registerActions[p.id])
            if not options.CleanMode then
              emit("end\n"..fmtReg(reg).." = "..p.name)
            else
              emit("end")
            end
          else
            emit(fmtReg(reg).." = "..body)
            writeActions(registerActions[p.id])
            emit("end")
          end
        end
        local CLEAN_SUPPRESS = {
          CLOSEUPVALS=true, PREPVARARGS=true, COVERAGE=true,
          CAPTURE=true, FASTCALL=true, FASTCALL1=true,
          FASTCALL2=true, FASTCALL2K=true, FASTCALL3=true,
          JUMPX=true, NOP=true, JUMPBACK=true,
        }
        for i, action in ipairs(actions) do
          repeat  -- repeat/until true used as a continue-able block (break = continue)
          if action.hide then break end
          local ur  = action.usedRegisters
          local ed  = action.extraData
          local oci = action.opCode
          if not oci then break end
          local opn = oci.name
          if options.CleanMode and CLEAN_SUPPRESS[opn] then break end
          if options.CleanMode and opn == "RETURN" then
            local b = ed and ed[1] or 0
            if b == 1 then break end
          end
          if options.CleanMode and opn == "MOVE" and
             i > 1 and actions[i-1] and
             (actions[i-1].opCode.name == "NEWCLOSURE" or
              actions[i-1].opCode.name == "DUPCLOSURE") then
            break
          end
          local function R(r) return fmtReg(r, i) end
          local function handleJumps()
            local n = jumpMarkers[i]
            if n then
              jumpMarkers[i]=nil
              for _=1,n do emit("end\n") end
            end
          end
          if not options.CleanMode then
            if options.ShowOperationIndex then
              emit("["..padLeft(i,"0",3).."] ")
            end
            if options.ShowInstructionLines and lineInfo and lineInfo[i] then
              emit(":"..padLeft(lineInfo[i],"0",3)..":")
            end
            if options.ShowOperationNames then
              emit(padRight(opn," ",15))
            end
          end
          if opn=="LOADNIL" then emit(R(ur[1]).." = nil")
          elseif opn=="LOADB" then
            emit(R(ur[1]).." = "..toEscapedString(toBoolean(ed[1])))
            if ed[2]~=0 then emit(" +"..ed[2]) end
          elseif opn=="LOADN" then emit(R(ur[1]).." = "..ed[1])
          elseif opn=="LOADK" then emit(R(ur[1]).." = "..fmtConst(consts[ed[1]+1]))
          elseif opn=="MOVE"  then emit(R(ur[1]).." = "..R(ur[2]))
          elseif opn=="GETGLOBAL" then
            local gk=tostring(consts[ed[1]+1] and consts[ed[1]+1].value or "")
            if options.ListUsedGlobals and isValidGlobal(gk) then
              table.insert(usedGlobals,gk); usedGlobalsSet[gk]=true
            end
            emit(R(ur[1]).." = "..gk)
          elseif opn=="SETGLOBAL" then
            local gk=tostring(consts[ed[1]+1] and consts[ed[1]+1].value or "")
            if options.ListUsedGlobals and isValidGlobal(gk) then
              table.insert(usedGlobals,gk); usedGlobalsSet[gk]=true
            end
            emit(gk.." = "..R(ur[1]))
          elseif opn=="GETUPVAL" then
            emit(R(ur[1]).." = "..fmtUpv(caps[ed[1]]))
          elseif opn=="SETUPVAL" then
            emit(fmtUpv(caps[ed[1]]).." = "..R(ur[1]))
          elseif opn=="CLOSEUPVALS" then emit("-- clear captures from back until: "..ur[1])
          elseif opn=="GETIMPORT" then
            local imp=tostring(consts[ed[1]+1] and consts[ed[1]+1].value or "")
            imp = imp:gsub("%.%.+", "."):gsub("^%.", ""):gsub("%.$", "")
            local totalIdx = bshr(ed[2] or 0, 30)
            if totalIdx==1 and options.ListUsedGlobals and isValidGlobal(imp) then
              table.insert(usedGlobals,imp); usedGlobalsSet[imp]=true
            end
            emit(R(ur[1]).." = "..imp)
          elseif opn=="GETTABLE" then
            emit(R(ur[1]).." = "..R(ur[2]).."["..R(ur[3]).."]")
          elseif opn=="SETTABLE" then
            emit(R(ur[2]).."["..R(ur[3]).."] = "..R(ur[1]))
          elseif opn=="GETTABLEKS" then
            local key = consts[ed[2]+1] and consts[ed[2]+1].value
            emit(R(ur[1]).." = "..R(ur[2])..formatIndexString(key))
          elseif opn=="SETTABLEKS" then
            local key = consts[ed[2]+1] and consts[ed[2]+1].value
            emit(R(ur[2])..formatIndexString(key).." = "..R(ur[1]))
          elseif opn=="GETTABLEN" then
            emit(R(ur[1]).." = "..R(ur[2]).."["..(ed[1]+1).."]")
          elseif opn=="SETTABLEN" then
            emit(R(ur[2]).."["..(ed[1]+1).."] = "..R(ur[1]))
          elseif opn=="NEWCLOSURE" then
            local p2=inner[ed[1]+1]; if p2 then writeProto(ur[1],p2) end
          elseif opn=="DUPCLOSURE" then
            local c=consts[ed[1]+1]
            if c then local p2=protoTable[c.value-1]; if p2 then writeProto(ur[1],p2) end end
          elseif opn=="NAMECALL" then
            local method=tostring(consts[ed[2]+1] and consts[ed[2]+1].value or "")
            emit("-- :"..method)
          elseif opn=="CALL" then
            local baseR=ur[1]
            local nArgs=ed[1]-1; local nRes=ed[2]-1
            local nmMethod=""; local argOff=0
            local prev=actions[i-1]
            if prev and prev.opCode and prev.opCode.name=="NAMECALL" then
              nmMethod=":"..tostring(consts[prev.extraData[2]+1] and consts[prev.extraData[2]+1].value or "")
              nArgs=nArgs-1; argOff=argOff+1
            end
            local callBody=""
            if nRes==-1 then callBody="... = "
            elseif nRes>0 then
              local rb=""
              for k=1,nRes do
                rb=rb..R(baseR+k-1)
                if k~=nRes then rb=rb..", " end
              end
              callBody=rb.." = "
            end
            callBody = callBody..R(baseR)..nmMethod.."("
            if nArgs==-1 then callBody=callBody.."..."
            elseif nArgs>0 then
              local ab=""
              for k=1,nArgs do
                ab=ab..R(baseR+k+argOff)
                if k~=nArgs then ab=ab..", " end
              end
              callBody=callBody..ab
            end
            callBody=callBody..")"
            emit(callBody)
          elseif opn=="RETURN" then
            local baseR=ur[1]; local tot=ed[1]-2
            local rb=""
            if tot==-2 then rb=" "..R(baseR)..", ..."
            elseif tot>-1 then
              rb=" "
              for k=0,tot do
                rb=rb..R(baseR+k)
                if k~=tot then rb=rb..", " end
              end
            end
            emit("return"..rb)
          elseif opn=="JUMP" then emit("-- jump to #"..(i+ed[1]))
          elseif opn=="JUMPBACK" then emit("-- jump back to #"..(i+ed[1]+1))
          elseif opn=="JUMPIF" then
            local ei=i+ed[1]; makeJump(ei)
            emit("if not "..R(ur[1]).." then -- goto #"..ei)
          elseif opn=="JUMPIFNOT" then
            local ei=i+ed[1]; makeJump(ei)
            emit("if "..R(ur[1]).." then -- goto #"..ei)
          elseif opn=="JUMPIFEQ" then
            local ei=i+ed[1]; makeJump(ei)
            emit("if "..R(ur[1]).." == "..R(ur[2]).." then -- goto #"..ei)
          elseif opn=="JUMPIFLE" then
            local ei=i+ed[1]; makeJump(ei)
            emit("if "..R(ur[1]).." >= "..R(ur[2]).." then -- goto #"..ei)
          elseif opn=="JUMPIFLT" then
            local ei=i+ed[1]; makeJump(ei)
            emit("if "..R(ur[1]).." > "..R(ur[2]).." then -- goto #"..ei)
          elseif opn=="JUMPIFNOTEQ" then
            local ei=i+ed[1]; makeJump(ei)
            emit("if "..R(ur[1]).." ~= "..R(ur[2]).." then -- goto #"..ei)
          elseif opn=="JUMPIFNOTLE" then
            local ei=i+ed[1]; makeJump(ei)
            emit("if "..R(ur[1]).." <= "..R(ur[2]).." then -- goto #"..ei)
          elseif opn=="JUMPIFNOTLT" then
            local ei=i+ed[1]; makeJump(ei)
            emit("if "..R(ur[1]).." < "..R(ur[2]).." then -- goto #"..ei)
          elseif opn=="ADD"  then emit(R(ur[1]).." = "..R(ur[2]).." + "..R(ur[3]))
          elseif opn=="SUB"  then emit(R(ur[1]).." = "..R(ur[2]).." - "..R(ur[3]))
          elseif opn=="MUL"  then emit(R(ur[1]).." = "..R(ur[2]).." * "..R(ur[3]))
          elseif opn=="DIV"  then emit(R(ur[1]).." = "..R(ur[2]).." / "..R(ur[3]))
          elseif opn=="MOD"  then emit(R(ur[1]).." = "..R(ur[2]).." % "..R(ur[3]))
          elseif opn=="POW"  then emit(R(ur[1]).." = "..R(ur[2]).." ^ "..R(ur[3]))
          elseif opn=="ADDK" then emit(R(ur[1]).." = "..R(ur[2]).." + "..fmtConst(consts[ed[1]+1]))
          elseif opn=="SUBK" then emit(R(ur[1]).." = "..R(ur[2]).." - "..fmtConst(consts[ed[1]+1]))
          elseif opn=="MULK" then emit(R(ur[1]).." = "..R(ur[2]).." * "..fmtConst(consts[ed[1]+1]))
          elseif opn=="DIVK" then emit(R(ur[1]).." = "..R(ur[2]).." / "..fmtConst(consts[ed[1]+1]))
          elseif opn=="MODK" then emit(R(ur[1]).." = "..R(ur[2]).." % "..fmtConst(consts[ed[1]+1]))
          elseif opn=="POWK" then emit(R(ur[1]).." = "..R(ur[2]).." ^ "..fmtConst(consts[ed[1]+1]))
          elseif opn=="AND"  then emit(R(ur[1]).." = "..R(ur[2]).." and "..R(ur[3]))
          elseif opn=="OR"   then emit(R(ur[1]).." = "..R(ur[2]).." or "..R(ur[3]))
          elseif opn=="ANDK" then emit(R(ur[1]).." = "..R(ur[2]).." and "..fmtConst(consts[ed[1]+1]))
          elseif opn=="ORK"  then emit(R(ur[1]).." = "..R(ur[2]).." or "..fmtConst(consts[ed[1]+1]))
          elseif opn=="CONCAT" then
            local tgt=table.remove(ur,1)
            local cb=""
            for k,r in ipairs(ur) do
              cb=cb..fmtReg(r); if k~=#ur then cb=cb.." .. " end
            end
            emit(R(tgt).." = "..cb)
          elseif opn=="NOT"    then emit(R(ur[1]).." = not "..R(ur[2]))
          elseif opn=="MINUS"  then emit(R(ur[1]).." = -"..R(ur[2]))
          elseif opn=="LENGTH" then emit(R(ur[1]).." = #"..R(ur[2]))
          elseif opn=="NEWTABLE" then
            emit(R(ur[1]).." = {}")
          elseif opn=="DUPTABLE" then
            local cv=consts[ed[1]+1]
            if cv and type(cv.value)=="table" then
              local tb="{"
              for k=1,cv.value.size do
                tb=tb..fmtConst(consts[cv.value.keys[k]])
                if k~=cv.value.size then tb=tb..", " end
              end
              emit(R(ur[1]).." = {} -- "..tb.."}")
            else emit(R(ur[1]).." = {}") end
          elseif opn=="SETLIST" then
            local tgt=ur[1]; local src=ur[2]
            local si=ed[1]; local vc=ed[2]
            if vc==0 then
              emit(R(tgt).."["..si.."] = [...]")
            else
              local tot2=#ur-1; local cb=""
              for k=1,tot2 do
                cb=cb..R(ur[k]).."["..(si+k-1).."] = "..R(src+k-1)
                if k~=tot2 then cb=cb.."\n" end
              end
              emit(cb)
            end
          elseif opn=="FORNPREP" then
            emit("for "..R(ur[3]).." = "..R(ur[3])..", "..R(ur[1])..", "..R(ur[2]).." do -- end at #"..(i+ed[1]))
          elseif opn=="FORNLOOP" then
            emit("end -- iterate + jump to #"..(i+ed[1]))
          elseif opn=="FORGLOOP" then
            emit("end -- iterate + jump to #"..(i+ed[1]))
          elseif opn=="FORGPREP_INEXT" then
            local tr=ur[1]+1
            emit("for "..R(tr+2)..", "..R(tr+3).." in ipairs("..R(tr)..") do")
          elseif opn=="FORGPREP_NEXT" then
            local tr=ur[1]+1
            emit("for "..R(tr+2)..", "..R(tr+3).." in pairs("..R(tr)..") do")
          elseif opn=="FORGPREP" then
            local ei=i+ed[1]+2
            local ea=actions[ei]
            local vb=""
            if ea and ea.usedRegisters and #ea.usedRegisters > 0 then
              for k,r in ipairs(ea.usedRegisters) do
                vb=vb..fmtReg(r, ei); if k~=#ea.usedRegisters then vb=vb..", " end
              end
            else
              local baseReg = ur[1]
              local nVars = 2
              if ea and ea.extraData and ea.extraData[2] then
                nVars = math.max(1, band(ea.extraData[2], 0xFF))
              end
              local parts = {}
              for k = 1, nVars do
                parts[k] = fmtReg(baseReg + 2 + (k - 1), i)
              end
              vb = table.concat(parts, ", ")
            end
            emit("for "..vb.." in "..R(ur[1]).." do -- end at #"..ei)
          elseif opn=="GETVARARGS" then
            local vc2=ed[1]-1
            local rb=""
            if vc2==-1 then rb=R(ur[1])
            else
              for k=1,vc2 do
                rb=rb..R(ur[k]); if k~=vc2 then rb=rb..", " end
              end
            end
            emit(rb.." = ...")
          elseif opn=="PREPVARARGS" then emit("-- ... ; number of fixed args: "..ed[1])
          elseif opn=="LOADKX" then emit(R(ur[1]).." = "..fmtConst(consts[ed[1]+1]))
          elseif opn=="JUMPX"    then emit("-- jump to #"..(i+ed[1]))
          elseif opn=="COVERAGE" then emit("-- coverage ("..ed[1]..")")
          elseif opn=="JUMPXEQKNIL" then
            local rev=bshr(ed[2] or 0, 0x1F) ~= 1
            local sign=rev and "~=" or "=="
            local ei=i+ed[1]; makeJump(ei)
            emit("if "..R(ur[1]).." "..sign.." nil then -- goto #"..ei)
          elseif opn=="JUMPXEQKB" then
            local val=tostring(toBoolean(band(ed[2] or 0, 1)))
            local rev=bshr(ed[2] or 0, 0x1F) ~= 1
            local sign=rev and "~=" or "=="
            local ei=i+ed[1]; makeJump(ei)
            emit("if "..R(ur[1]).." "..sign.." "..val.." then -- goto #"..ei)
          elseif opn=="JUMPXEQKN" or opn=="JUMPXEQKS" then
            local cidx=band(ed[2] or 0, 0xFFFFFF)
            local val=fmtConst(consts[cidx+1])
            local rev=bshr(ed[2] or 0, 0x1F) ~= 1
            local sign=rev and "~=" or "=="
            local ei=i+ed[1]; makeJump(ei)
            emit("if "..R(ur[1]).." "..sign.." "..val.." then -- goto #"..ei)
          elseif opn=="CAPTURE"  then emit("-- upvalue capture")
          elseif opn=="SUBRK"    then emit(R(ur[1]).." = "..fmtConst(consts[ed[1]+1]).." - "..R(ur[2]))
          elseif opn=="DIVRK"    then emit(R(ur[1]).." = "..fmtConst(consts[ed[1]+1]).." / "..R(ur[2]))
          elseif opn=="IDIV"     then emit(R(ur[1]).." = "..R(ur[2]).." // "..R(ur[3]))
          elseif opn=="IDIVK"    then emit(R(ur[1]).." = "..R(ur[2]).." // "..fmtConst(consts[ed[1]+1]))
          elseif opn=="FASTCALL" then emit("-- FASTCALL; "..Luau:GetBuiltinInfo(ed[1]).."()")
          elseif opn=="FASTCALL1" then emit("-- FASTCALL1; "..Luau:GetBuiltinInfo(ed[1]).."("..R(ur[1])..")")
          elseif opn=="FASTCALL2" then emit("-- FASTCALL2; "..Luau:GetBuiltinInfo(ed[1]).."("..R(ur[1])..", "..R(ur[2])..")")
          elseif opn=="FASTCALL2K" then
            emit("-- FASTCALL2K; "..Luau:GetBuiltinInfo(ed[1]).."("..R(ur[1])..", "..fmtConst(consts[(ed[3] or 0)+1])..")")
          elseif opn=="FASTCALL3" then
            emit("-- FASTCALL3; "..Luau:GetBuiltinInfo(ed[1]).."("..R(ur[1])..", "..R(ur[2])..", "..R(ur[3])..")")
          end
          emit("\n")
          handleJumps()
          until true  -- end of continue block
        end
      end
      writeActions(registerActions[mainProtoId])
      finalResult = processResult(table.concat(resultParts))
    else
      finalResult = processResult("-- mode not supported")
    end
    return finalResult
  end

  local function manager(proceed, issue)
    if proceed then
      local startTime = os.clock()
      local ok, res = pcall(function() return finalize(organize()) end)
      local result = ok and res or ("-- RUNTIME ERROR:\n-- " .. tostring(res))
      if (os.clock() - startTime) >= options.DecompilerTimeout then
        return Strings.TIMEOUT
      end
      return string.format(Strings.SUCCESS, result)
    else
      if issue == "COMPILATION_FAILURE" then
        local len = reader:len()-1
        return string.format(Strings.COMPILATION_FAILURE, reader:nextString(len))
      elseif issue == "UNSUPPORTED_LBC_VERSION" then
        return Strings.UNSUPPORTED_LBC_VERSION
      end
    end
  end

  bytecodeVersion = reader:nextByte()
  if bytecodeVersion == 0 then
    return manager(false, "COMPILATION_FAILURE")
  elseif bytecodeVersion >= LuauBytecodeTag.LBC_VERSION_MIN
     and bytecodeVersion <= LuauBytecodeTag.LBC_VERSION_MAX then
    return manager(true)
  else
    return manager(false, "UNSUPPORTED_LBC_VERSION")
  end
end

-- ── Pretty-printer ────────────────────────────────────────────────────────────
local function prettyPrint(text)
  local result = {}
  local depth  = 0

  local DEDENT_BEFORE      = { ["end"]=true, ["until"]=true }
  local INDENT_AFTER       = { ["then"]=true, ["do"]=true, ["repeat"]=true }
  local DEDENT_THEN_INDENT = { ["else"]=true, ["elseif"]=true }

  local function stripStrings(s)
    s = s:gsub('"[^"]*"', '""')
    s = s:gsub("'[^']*'", "''")
    s = s:gsub("%-%-.*$", "")
    return s
  end
  local function firstWord(s)
    return (stripStrings(s):match("^%s*([%a_][%w_]*)")) or ""
  end
  local function containsOpener(s)
    local clean = stripStrings(s)
    local fw = clean:match("^%s*([%a_][%w_]*)")
    if fw == "elseif" or fw == "else" then return false end
    for w in clean:gmatch("[%a_][%w_]*") do
      if INDENT_AFTER[w] then return true end
      if w == "function" then return true end
    end
    return false
  end

  for line in (text .. "\n"):gmatch("[^\n]*\n") do
    local bare = line:gsub("\n$", "")
    if bare == "" then
      result[#result+1] = "\n"
    else
      local expr = bare:match("^%[%d+%]%s*:?%d*:?%s*%u[%u_]*%s+(.*)") or bare
      local kw = firstWord(expr)

      if DEDENT_THEN_INDENT[kw] then
        depth = math.max(0, depth - 1)
        result[#result+1] = string.rep("    ", depth) .. bare .. "\n"
        depth = depth + 1
      elseif DEDENT_BEFORE[kw] then
        depth = math.max(0, depth - 1)
        result[#result+1] = string.rep("    ", depth) .. bare .. "\n"
      else
        result[#result+1] = string.rep("    ", depth) .. bare .. "\n"
        if containsOpener(expr) then depth = depth + 1 end
      end
    end
  end

  return table.concat(result)
end

-- ── Clean-output pass ─────────────────────────────────────────────────────────
local function cleanOutput(text)
  local rawLines = {}
  for line in (text .. "\n"):gmatch("[^\n]*\n") do
    rawLines[#rawLines+1] = line:gsub("\n$", "")
  end

  local function escpat(s)
    return s:gsub("([%(%)%.%%%+%-%*%?%[%^%$])", "%%%1")
  end
  local function nextNonBlank(start)
    local j = start
    while j <= #rawLines and (rawLines[j] == nil or rawLines[j]:match("^%s*$")) do
      j = j + 1
    end
    return j
  end

  local function tryCollapse(i)
    local line = rawLines[i]
    if line == nil then return false end
    local reg, lit = line:match('^%s*(v%d+) = (".-")%s*$')
    if not reg then reg, lit = line:match('^%s*(v%d+) = (%-?%d+%.?%d*)%s*$') end
    if not reg then reg, lit = line:match('^%s*(v%d+) = (true)%s*$') end
    if not reg then reg, lit = line:match('^%s*(v%d+) = (false)%s*$') end
    if not reg then reg, lit = line:match('^%s*(v%d+) = (nil)%s*$') end
    if not reg then reg, lit = line:match('^%s*(v%d+) = ([%a_][%w_%.]+)%s*$') end
    if not reg then return false end
    local j = nextNonBlank(i + 1)
    if j > #rawLines or rawLines[j] == nil then return false end
    local nextLine = rawLines[j]
    local ep = escpat(reg)
    local count = 0
    for _ in nextLine:gmatch(ep) do count = count + 1 end
    if count ~= 1 then return false end
    if nextLine:match("^%s*" .. ep .. "%s*=") then return false end
    for k = i+1, j-1 do
      local midLine = rawLines[k]
      if midLine and midLine:match("^%s*" .. ep .. "%s*=") then return false end
    end
    rawLines[j] = nextLine:gsub(ep, lit, 1)
    rawLines[i] = nil
    return true
  end
  for _ = 1, 8 do
    for i = 1, #rawLines do tryCollapse(i) end
  end

  local function tryFoldField(i)
    local line = rawLines[i]
    if not line then return false end
    local lreg, src, field = line:match('^%s*(v%d+) = (v%d+)%.([%a_][%w_]*)%s*$')
    if not lreg then
      lreg, src, field = line:match('^%s*(v%d+) = (v%d+)%[(.-)%]%s*$')
      if lreg then field = "[" .. field .. "]" else return false end
    else
      field = "." .. field
    end
    local j = nextNonBlank(i + 1)
    if j > #rawLines then return false end
    local nextLine = rawLines[j]
    local epReg = escpat(lreg)
    local epSrc = escpat(src)
    local count = 0
    for _ in nextLine:gmatch(epReg) do count = count + 1 end
    if count ~= 1 then return false end
    if nextLine:match("^%s*" .. epReg .. "%s*=") then return false end
    for k = i+1, j-1 do
      local midLine = rawLines[k]
      if midLine and midLine:match("^%s*" .. epSrc .. "%s*=") then return false end
    end
    if src:match("^upv_") then return false end
    rawLines[j] = nextLine:gsub(epReg, src .. field, 1)
    rawLines[i] = nil
    return true
  end
  for _ = 1, 6 do
    for i = 1, #rawLines do tryFoldField(i) end
  end

  local pass2 = {}
  for idx = 1, #rawLines do
    local line = rawLines[idx]
    if line ~= nil then
      local stripped = line:match("^%s*(.-)%s*$")
      if not stripped:match("^%-%- goto #%d+$") and not stripped:match("^%-%- jump") then
        line = line:gsub("%s*%-%- goto #%d+$", "")
        line = line:gsub("%s*%-%- end at #%d+$", "")
        line = line:gsub("%s*%-%- iterate %+ jump to #%d+$", "")
        pass2[#pass2+1] = line
      end
    end
  end

  local pass3 = {}
  local i = 1
  while i <= #pass2 do
    local line = pass2[i]
    local nxt  = pass2[i+1]
    local s    = line and line:match("^%s*(.-)%s*$") or ""
    local isNilInit = s:match("^v%d+ = nil") ~= nil
    local nextIsFor = nxt and nxt:match("^%s*for%s+v%d+") ~= nil
    if isNilInit and nextIsFor then i = i + 1
    else pass3[#pass3+1] = line; i = i + 1 end
  end

  local seen = {}
  local pass4 = {}
  for _, line in ipairs(pass3) do
    local reg = line:match("^%s*(v%d+)%s*=")
    if reg and not seen[reg] then
      seen[reg] = true
      line = line:gsub("^(%s*)(v%d+%s*=)", "%1local %2", 1)
    end
    pass4[#pass4+1] = line
  end

  local final = {}
  local lastBlank = false
  for _, line in ipairs(pass4) do
    local isBlank = line:match("^%s*$") ~= nil
    if not (isBlank and lastBlank) then
      lastBlank = isBlank
      final[#final+1] = line
    end
  end

  return table.concat(final, "\n")
end

-- ── Public module API ─────────────────────────────────────────────────────────
local M = {}

function M.decompile(bytecode, opts)
  local options = {}
  for k, v in pairs(DEFAULT_OPTIONS) do options[k] = v end
  if opts then
    for k, v in pairs(opts) do options[k] = v end
  end
  return Decompile(bytecode, options)
end

M.prettyPrint  = prettyPrint
M.cleanOutput  = cleanOutput
M.DEFAULT_OPTIONS = DEFAULT_OPTIONS

-- ── CLI entry point ───────────────────────────────────────────────────────────
-- Only run when executed directly (not required as a module).
-- Uses a portable check: Luau executors don't have `arg`, and `io`/`os.exit`
-- may not be available — we guard every call so the module is safe to require.
local _isMain = false
-- arg[0] is the script name only when run directly as `lua script.lua`
-- When dofile/require is used, arg may still be a table but arg[0] is the
-- parent script, not this file. We use debug.getinfo to check reliably.
if debug and type(debug.getinfo) == "function" then
  local ok, info = pcall(debug.getinfo, 1, "S")
  if ok and info and info.what == "main" then
    -- Further confirm by matching arg[0] to source name if available
    if type(arg) == "table" and type(arg[0]) == "string" then
      local src = info.source or ""
      -- info.source starts with '@' for file-based chunks
      if src:sub(1,1) == "@" then
        local srcFile = src:sub(2):match("[^/\\]+$") or src:sub(2)
        local argFile = (arg[0] or ""):match("[^/\\]+$") or (arg[0] or "")
        if srcFile == argFile then _isMain = true end
      end
    elseif type(arg) == "table" then
      _isMain = true
    end
  end
elseif type(arg) == "table" then
  -- No debug lib (some stripped builds) – best-effort
  _isMain = true
end

if _isMain and type(io) == "table" and type(os) == "table" then
  local args = arg or {}
  local filepath = nil
  local opts = {}

  local i = 1
  while i <= #args do
    local a = args[i]
    if a == "--mode" then
      i = i + 1; opts.DecompilerMode = args[i]
    elseif a == "--clean" then
      opts.CleanMode = true
    elseif a == "--no-globals" then
      opts.ListUsedGlobals = false
    elseif a == "--timeout" then
      i = i + 1; opts.DecompilerTimeout = tonumber(args[i]) or 10
    elseif a == "--float-precision" then
      i = i + 1; opts.ReaderFloatPrecision = tonumber(args[i]) or 7
    elseif a == "--show-debug" then
      opts.ShowDebugInformation = true
    elseif a == "--show-lines" then
      opts.ShowInstructionLines = true
    elseif a == "--show-opidx" then
      opts.ShowOperationIndex = true
    elseif a == "--show-opnames" then
      opts.ShowOperationNames = true
    elseif a == "--show-trivial" then
      opts.ShowTrivialOperations = true
    elseif a == "--no-typeinfo" then
      opts.UseTypeInfo = false
    elseif a == "--help" or a == "-h" then
      print("Usage: lua zukv2.lua <bytecode_file> [options]")
      print("Options: --mode disasm | --clean | --no-globals | --timeout N")
      print("         --float-precision N | --show-debug | --show-lines")
      print("         --show-opidx | --show-opnames | --show-trivial | --no-typeinfo")
      os.exit(0)
    elseif not filepath then
      filepath = a
    end
    i = i + 1
  end

  if not filepath then
    io.stderr:write("Usage: lua zukv2.lua <bytecode_file> [options]\n")
    os.exit(1)
  end

  local f, err = io.open(filepath, "rb")
  if not f then
    io.stderr:write("Error opening file: " .. tostring(err) .. "\n")
    os.exit(1)
  end
  local bytecode = f:read("*a")
  f:close()

  local result = M.decompile(bytecode, opts)

  if opts.CleanMode then
    result = prettyPrint(result)
    result = cleanOutput(result)
  end

  io.write(result)
end

return M
