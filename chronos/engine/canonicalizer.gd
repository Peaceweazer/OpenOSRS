extends RefCounted
## Deterministic canonical serialization and signature hashing.
##
## Canonical form rules:
##   * Dictionary keys are sorted lexicographically (never insertion order).
##   * Arrays keep their order; callers must sort arrays they build themselves.
##   * Integers serialize as integers; booleans as true/false; null as null.
##   * Floats are NOT legal causal state. A float that reaches this serializer is
##     emitted as an explicit "!FLOAT!" marker so it can never silently pass a
##     determinism test.

static func canonical(value) -> String:
	match typeof(value):
		TYPE_NIL:
			return "null"
		TYPE_BOOL:
			return "true" if value else "false"
		TYPE_INT:
			return str(value)
		TYPE_FLOAT:
			return "!FLOAT!" + str(value)
		TYPE_STRING, TYPE_STRING_NAME:
			return quote(str(value))
		TYPE_ARRAY:
			var parts := []
			for item in value:
				parts.append(canonical(item))
			return "[" + ",".join(parts) + "]"
		TYPE_DICTIONARY:
			var keys := []
			for k in value.keys():
				keys.append(str(k))
			keys.sort()
			var pairs := []
			for k in keys:
				pairs.append(quote(k) + ":" + canonical(value[k]))
			return "{" + ",".join(pairs) + "}"
	return quote(str(value))

static func quote(text: String) -> String:
	var out := text
	out = out.replace("\\", "\\\\")
	out = out.replace("\"", "\\\"")
	out = out.replace("\n", "\\n")
	out = out.replace("\t", "\\t")
	out = out.replace("\r", "\\r")
	return "\"" + out + "\""

static func signature(value) -> String:
	return canonical(value).sha256_text()

## Sorts an array of dictionaries by their canonical form. Used wherever an
## unordered set has to be serialized deterministically.
static func sorted_records(records: Array) -> Array:
	var keyed := []
	for r in records:
		keyed.append([canonical(r), r])
	keyed.sort_custom(func(a, b): return a[0] < b[0])
	var out := []
	for pair in keyed:
		out.append(pair[1])
	return out

## Recursively converts JSON-parsed whole floats to ints and reports any true
## fractional value found in case data.
static func normalize_numbers(value, path: String, problems: Array):
	match typeof(value):
		TYPE_FLOAT:
			if value == floor(value) and absf(value) < 9007199254740992.0:
				return int(value)
			problems.append("FLOAT_IN_CASE_DATA at %s (%s)" % [path, value])
			return value
		TYPE_ARRAY:
			var arr := []
			for i in value.size():
				arr.append(normalize_numbers(value[i], "%s[%d]" % [path, i], problems))
			return arr
		TYPE_DICTIONARY:
			var out := {}
			for k in value.keys():
				out[k] = normalize_numbers(value[k], "%s.%s" % [path, k], problems)
			return out
	return value
