# Ruby 3.2/3.3 Compatibility Analysis for nwrfc

## Overview
This gem is a wrapper around the SAP Netweaver RFC SDK using FFI. It has several
compatibility issues with Ruby 3.2 and 3.3 that need to be addressed.



## Issues Found

### 1. **CRITICAL: Outdated FFI Dependency** ⚠️
**File:** [nwrfc.gemspec](nwrfc.gemspec) **Issue:** FFI version constraint is
too old
```ruby
s.add_dependency('ffi', '>= 1.9.3')
```
**Problem:**
- Requires FFI 1.9.3+ (from 2014), but Ruby 3.2/3.3 compatibility requires FFI
  1.15.0+
- Older FFI versions have issues with Ruby 3.x memory management and encoding
  handling
- FFI 1.15+ is recommended for full Ruby 3.x support

**Fix:** Update to:
```ruby
s.add_dependency('ffi', '>= 1.15.0')
```



### 2. **DEPRECATED: `String#cU` and `String#uC` Encoding Methods** ⚠️
**Files:**
- [lib/nwrfc/nwrfclib.rb](lib/nwrfc/nwrfclib.rb#L62-L74)

**Issue:** The custom string encoding methods use deprecated patterns:
```ruby
def cU
  (self.to_s + "\0").force_encoding('UTF-8').encode('UTF-16LE')
end
```

**Problems:**
- `force_encoding` followed by `encode` on the same string is problematic in
  Ruby 3.2+
- String handling for UTF-16LE has stricter validation in Ruby 3.2+
- The intermediate `to_s` call is redundant (String is already a string)

**Fix:** Simplify to:
```ruby
def cU
  encode('UTF-16LE')
end
```



### 3. **DEPRECATED: `RUBY_VERSION_18` Check** ⚠️
**File:** [lib/nwrfc/nwrfclib.rb](lib/nwrfc/nwrfclib.rb#L11-L20)

**Issue:** Code still includes legacy Ruby 1.8 compatibility checks:
```ruby
RUBY_VERSION_18 = RUBY_VERSION[0..2] == "1.8"
# ... later ...
if RUBY_VERSION_18
  FFI::MemoryPointer.class_eval { alias :read_uint :read_int }
end
```

**Problem:**
- Ruby 1.8 has been unsupported since 2013
- This code path will never execute in Ruby 3.2+, adding maintenance burden
- String slicing with `[0..2]` is outdated practice

**Fix:** Remove entirely (Ruby 1.8 is EOL)



### 4. **DEPRECATED: `String#cU` String Slicing with Range** ⚠️
**File:** [lib/nwrfc/nwrfclib.rb](lib/nwrfc/nwrfclib.rb#L11)

**Issue:**
```ruby
RUBY_VERSION_18 = RUBY_VERSION[0..2] == "1.8"
```

**Problem:**
- Using range-based string slicing (`[0..2]`) is less idiomatic in modern Ruby
- While not deprecated, `RUBY_VERSION.start_with?` would be clearer (if needed)

**Fix:** Use `RUBY_VERSION.start_with?("1.8")` or remove entirely



### 5. **DEPRECATED: `Iconv` Library** ⚠️
**File:** [lib/nwrfc/nwrfclib.rb](lib/nwrfc/nwrfclib.rb#L13)

**Issue:**
```ruby
require 'iconv' unless STRING_SUPPORTS_ENCODE
```

**Problem:**
- `Iconv` was removed from Ruby 2.0+ and completely unsupported in Ruby 3.x
- This code path should never execute in Ruby 3.2/3.3
- The else branch (using `Iconv`) will cause a `LoadError` if executed

**Fix:** Remove the entire `Iconv` fallback since `STRING_SUPPORTS_ENCODE` will
always be `true` in Ruby 3.2+



### 6. **POTENTIAL ISSUE: FFI::MemoryPointer UTF-16LE String Reading** ⚠️
**File:** [lib/nwrfc/nwrfclib.rb](lib/nwrfc/nwrfclib.rb#L32-L44)

**Issue:**
```ruby
def read_string_dn(max=0)
  cont_nullcount = 0
  offset = 0
  until cont_nullcount == 2
    byte = get_bytes(offset, 1)
    cont_nullcount += 1 if byte == "\000"
    cont_nullcount = 0 if byte != "\000"
    offset += 1
  end
  get_bytes(0, offset+1)
end
```

**Problem:**
- Comparing bytes with `"\000"` works but is non-standard
- Should use integer comparison for clarity and performance
- UTF-16LE encoding issues may arise in Ruby 3.2+ with stricter encoding
  validation

**Fix:** Use numeric comparison:
```ruby
def read_string_dn(max=0)
  cont_nullcount = 0
  offset = 0
  until cont_nullcount == 2
    byte = get_bytes(offset, 1)
    cont_nullcount += 1 if byte.bytes.first == 0
    cont_nullcount = 0 if byte.bytes.first != 0
    offset += 1
  end
  get_bytes(0, offset+1)
end
```



### 7. **DEPRECATED: `class` Attribute Name** ⚠️
**File:** [lib/nwrfc/nwerror.rb](lib/nwrfc/nwerror.rb#L7)

**Issue:**
```ruby
attr_reader :code, :group, :message, :class, :type, :number
```

**Problem:**
- Using `class` as an attribute name shadows the `Object#class` method
- In Ruby 3.2+, this is a severe code smell and causes issues with introspection
- Accessing `obj.class` will return the attribute value instead of the Class
  object

**Fix:** Rename to `:klass` or `:error_class`:
```ruby
attr_reader :code, :group, :message, :klass, :type, :number
```



### 8. **POTENTIAL: BigDecimal Constructor Change** ⚠️
**File:** [lib/nwrfc/datacontainer.rb](lib/nwrfc/datacontainer.rb#L47)

**Issue:**
```ruby
return BigDecimal(buf.get_bytes(0, size*2).uC)
```

**Problem:**
- `BigDecimal()` constructor is safe, but the string conversion chain
  (`buf.get_bytes(...).uC`) may produce encoding issues in Ruby 3.2+
- Ensure the UTF-8 string from `.uC` is properly encoded before passing to
  BigDecimal

**Fix:** Ensure string is valid UTF-8:
```ruby
decimal_str = buf.get_bytes(0, size*2).uC
raise "Invalid BigDecimal string" unless decimal_str.valid_encoding?
return BigDecimal(decimal_str)
```



## Summary of Required Changes

| Issue | Severity | Action |
|-------|----------|--------|
| FFI version constraint | **CRITICAL** | Update to `>= 1.15.0` |
| Remove Ruby 1.8 support code | High | Delete entirely |
| Remove Iconv fallback | High | Delete Iconv require and else branch |
| `class` attribute naming | High | Rename to `:klass` |
| String encoding logic | Medium | Simplify `cU` and `uC` methods |
| UTF-16LE null terminator detection | Medium | Improve byte comparison logic |
| BigDecimal encoding validation | Low | Add validation before conversion |



## Testing Recommendations

1. **Test with Ruby 3.2.0 and 3.3.0** using RVM or rbenv
2. **Run full test suite** in [test/test_nwrfc.rb](test/test_nwrfc.rb)
3. **Test string encoding** with various character sets (ASCII, UTF-8, special
   characters)
4. **Test FFI integration** with actual SAP Netweaver RFC connections
5. **Check for warnings** with `ruby -w` when running tests



## Compatibility Matrix

| Ruby Version | Status | Notes |
|--------------|--------|-------|
| 1.8 - 2.1 | EOL | Not tested |
| 2.2 - 3.0 | Not verified | May work with fixes |
| 3.1 | Not verified | May work with fixes |
| 3.2 | **NEEDS FIXES** | Multiple compatibility issues |
| 3.3 | **NEEDS FIXES** | Same issues as 3.2 |

