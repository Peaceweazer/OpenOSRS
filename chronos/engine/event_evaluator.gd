extends RefCounted
## Declarative condition and effect vocabulary.
##
## Deliberately tiny. This is not a programming language: there are no
## variables, no arithmetic, no loops, no user functions. It supports exactly
## what the proof cases need.
##
## Conditions:
##   and                {conditions: [...]}
##   not                {condition: {...}}
##   entity_exists      {selector}
##   entity_at          {selector, location}
##   entity_state_equals{selector, field, value}
##   entity_knows       {selector, token}
##   global_equals      {key, value}
##
## Effects:
##   set_global         {key, value}
##   set_entity_state   {selector, field, value}
##   move_entity        {selector, location}
##   create_entity      {instance_id, lineage_id, location, state?, knowledge?}
##   destroy_entity     {selector}
##   add_knowledge      {selector, token}
##
## Effects that address an existing instance require the selector to resolve to
## EXACTLY ONE active instance. Zero or several matches block the whole event;
## events are atomic and never apply partially.

const Canon = preload("res://engine/canonicalizer.gd")
const WorldState = preload("res://engine/world_state.gd")

const CONDITION_TYPES := [
	"and", "not", "entity_exists", "entity_at", "entity_state_equals",
	"entity_knows", "global_equals",
]
const EFFECT_TYPES := [
	"set_global", "set_entity_state", "move_entity", "create_entity",
	"destroy_entity", "add_knowledge",
]

static func describe_selector(selector: Dictionary) -> String:
	var parts := []
	if selector.has("instance_id"):
		parts.append(str(selector["instance_id"]))
	if selector.has("lineage_id"):
		parts.append(str(selector["lineage_id"]))
	if selector.has("entity_type"):
		parts.append(str(selector["entity_type"]))
	if selector.has("temporal"):
		parts.append("temporal" if bool(selector["temporal"]) else "non-temporal")
	if selector.has("location"):
		parts.append("at " + str(selector["location"]))
	if selector.has("state"):
		var fields: Array = selector["state"].keys()
		fields.sort()
		for f in fields:
			parts.append("%s=%s" % [f, Canon.canonical(selector["state"][f])])
	if selector.has("knows"):
		for t in selector["knows"]:
			parts.append("knows " + str(t))
	if parts.is_empty():
		return "any entity"
	return " ".join(parts)

# ---------------------------------------------------------------------------
# Conditions
# ---------------------------------------------------------------------------

static func evaluate(condition, state) -> Dictionary:
	if condition == null:
		return {"ok": true, "reasons": []}
	var type := str(condition.get("type", ""))
	match type:
		"and":
			var reasons := []
			for sub in condition.get("conditions", []):
				var r := evaluate(sub, state)
				if not r["ok"]:
					for reason in r["reasons"]:
						reasons.append(reason)
			return {"ok": reasons.is_empty(), "reasons": reasons}
		"not":
			var inner := evaluate(condition.get("condition", null), state)
			if inner["ok"]:
				return {"ok": false, "reasons": [{
					"code": "NEGATED_CONDITION_HELD",
					"message": "condition that must be false held: %s" % [summarize(condition.get("condition", null))],
				}]}
			return {"ok": true, "reasons": []}
		"entity_exists":
			var selector: Dictionary = condition.get("selector", {})
			if state.select(selector).is_empty():
				return {"ok": false, "reasons": [{
					"code": "ENTITY_NOT_PRESENT",
					"selector": selector,
					"message": "%s does not exist" % [describe_selector(selector)],
				}]}
			return {"ok": true, "reasons": []}
		"entity_at":
			var selector2: Dictionary = condition.get("selector", {}).duplicate(true)
			var location := str(condition.get("location", ""))
			selector2["location"] = location
			if state.select(selector2).is_empty():
				return {"ok": false, "reasons": [{
					"code": "ENTITY_NOT_AT_LOCATION",
					"selector": condition.get("selector", {}),
					"location": location,
					"message": "%s not present at %s" % [
						describe_selector(condition.get("selector", {})), location],
				}]}
			return {"ok": true, "reasons": []}
		"entity_state_equals":
			var selector3: Dictionary = condition.get("selector", {}).duplicate(true)
			var field := str(condition.get("field", ""))
			selector3["state"] = {field: condition.get("value", null)}
			if state.select(selector3).is_empty():
				return {"ok": false, "reasons": [{
					"code": "ENTITY_STATE_MISMATCH",
					"selector": condition.get("selector", {}),
					"field": field,
					"expected": condition.get("value", null),
					"message": "no %s with %s == %s" % [
						describe_selector(condition.get("selector", {})), field,
						Canon.canonical(condition.get("value", null))],
				}]}
			return {"ok": true, "reasons": []}
		"entity_knows":
			var selector4: Dictionary = condition.get("selector", {}).duplicate(true)
			var token := str(condition.get("token", ""))
			selector4["knows"] = [token]
			if state.select(selector4).is_empty():
				return {"ok": false, "reasons": [{
					"code": "KNOWLEDGE_MISSING",
					"selector": condition.get("selector", {}),
					"token": token,
					"message": "%s does not know %s" % [
						describe_selector(condition.get("selector", {})), token],
				}]}
			return {"ok": true, "reasons": []}
		"global_equals":
			var key := str(condition.get("key", ""))
			var expected = condition.get("value", null)
			var actual = state.globals.get(key, null)
			if Canon.canonical(actual) != Canon.canonical(expected):
				return {"ok": false, "reasons": [{
					"code": "GLOBAL_STATE_MISMATCH",
					"key": key,
					"expected": expected,
					"actual": actual,
					"message": "%s == %s (expected %s)" % [
						key, Canon.canonical(actual), Canon.canonical(expected)],
				}]}
			return {"ok": true, "reasons": []}
	return {"ok": false, "reasons": [{
		"code": "UNKNOWN_CONDITION_TYPE",
		"message": "unknown condition type '%s'" % [type],
	}]}

static func summarize(condition) -> String:
	if condition == null:
		return "true"
	var type := str(condition.get("type", ""))
	match type:
		"and":
			var parts := []
			for sub in condition.get("conditions", []):
				parts.append(summarize(sub))
			return "(" + " AND ".join(parts) + ")"
		"not":
			return "NOT " + summarize(condition.get("condition", null))
		"entity_exists":
			return "%s exists" % [describe_selector(condition.get("selector", {}))]
		"entity_at":
			return "%s at %s" % [describe_selector(condition.get("selector", {})),
				condition.get("location", "")]
		"entity_state_equals":
			return "%s.%s == %s" % [describe_selector(condition.get("selector", {})),
				condition.get("field", ""), Canon.canonical(condition.get("value", null))]
		"entity_knows":
			return "%s knows %s" % [describe_selector(condition.get("selector", {})),
				condition.get("token", "")]
		"global_equals":
			return "%s == %s" % [condition.get("key", ""),
				Canon.canonical(condition.get("value", null))]
	return "unknown(%s)" % [type]

# ---------------------------------------------------------------------------
# Effects
# ---------------------------------------------------------------------------

## Computes every write of an event against the phase-start state.
## Returns {"ok": bool, "writes": [...], "reasons": [...]}.
static func compute_effects(effects: Array, state, source: Dictionary) -> Dictionary:
	var writes := []
	var reasons := []
	for effect in effects:
		var type := str(effect.get("type", ""))
		match type:
			"set_global":
				writes.append(WorldState.write_global(
					str(effect["key"]), effect.get("value", null), source))
			"create_entity":
				var spec := {
					"instance_id": str(effect["instance_id"]),
					"lineage_id": str(effect["lineage_id"]),
					"location": str(effect.get("location", "")),
					"state": effect.get("state", {}),
					"knowledge": effect.get("knowledge", []),
					"temporal": false,
				}
				writes.append(WorldState.write_materialize(spec, source))
				writes.append(WorldState.write_location(
					spec["instance_id"], spec["location"], source))
				for field in spec["state"].keys():
					writes.append(WorldState.write_state(
						spec["instance_id"], str(field), spec["state"][field], source))
			_:
				var resolved := _resolve_single(effect.get("selector", {}), state)
				if not resolved["ok"]:
					reasons.append(resolved["reason"])
					continue
				var inst = resolved["instance"]
				match type:
					"set_entity_state":
						writes.append(WorldState.write_state(inst.instance_id,
							str(effect["field"]), effect.get("value", null), source))
					"move_entity":
						writes.append(WorldState.write_location(inst.instance_id,
							str(effect["location"]), source))
					"destroy_entity":
						writes.append(WorldState.write_exists(inst.instance_id, false, source))
					"add_knowledge":
						writes.append(WorldState.write_knowledge(inst.instance_id,
							str(effect["token"]), source))
					_:
						reasons.append({
							"code": "UNKNOWN_EFFECT_TYPE",
							"message": "unknown effect type '%s'" % [type],
						})
	if not reasons.is_empty():
		return {"ok": false, "writes": [], "reasons": reasons}
	return {"ok": true, "writes": writes, "reasons": []}

static func _resolve_single(selector: Dictionary, state) -> Dictionary:
	var matches: Array = state.select(selector)
	if matches.is_empty():
		return {"ok": false, "reason": {
			"code": "EFFECT_TARGET_UNRESOLVED",
			"selector": selector,
			"message": "no active instance matches %s" % [describe_selector(selector)],
		}}
	if matches.size() > 1:
		var ids := []
		for m in matches:
			ids.append(m.instance_id)
		return {"ok": false, "reason": {
			"code": "EFFECT_TARGET_AMBIGUOUS",
			"selector": selector,
			"candidates": ids,
			"message": "%d active instances match %s: %s" % [
				matches.size(), describe_selector(selector), ", ".join(ids)],
		}}
	return {"ok": true, "instance": matches[0]}
