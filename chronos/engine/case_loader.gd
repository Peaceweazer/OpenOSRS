extends RefCounted
## Loads and validates a data-driven case definition.
##
## The engine contains no case-specific logic whatsoever: everything below is
## generic structural validation.

const K = preload("res://engine/constants.gd")
const Canon = preload("res://engine/canonicalizer.gd")
const Evaluator = preload("res://engine/event_evaluator.gd")
const WorldState = preload("res://engine/world_state.gd")

static func load_case(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"ok": false, "errors": ["CASE_FILE_NOT_FOUND: " + path]}
	var text := FileAccess.get_file_as_string(path)
	var parsed = JSON.parse_string(text)
	if parsed == null or typeof(parsed) != TYPE_DICTIONARY:
		return {"ok": false, "errors": ["CASE_JSON_INVALID: " + path]}
	var problems := []
	var data = Canon.normalize_numbers(parsed, "case", problems)
	if not problems.is_empty():
		return {"ok": false, "errors": problems}
	data["source_path"] = path
	return validate(data)

static func validate(data: Dictionary) -> Dictionary:
	var errors := []
	for field in ["case_id", "tick_start", "tick_end", "events"]:
		if not data.has(field):
			errors.append("CASE_MISSING_FIELD: " + field)
	if not errors.is_empty():
		return {"ok": false, "errors": errors}

	var tick_start := int(data["tick_start"])
	var tick_end := int(data["tick_end"])
	if tick_end < tick_start:
		errors.append("CASE_TICK_RANGE_INVALID")

	var seen_events := {}
	for event in data["events"]:
		var eid := str(event.get("event_id", ""))
		if eid == "":
			errors.append("EVENT_MISSING_ID")
			continue
		if seen_events.has(eid):
			errors.append("EVENT_DUPLICATE_ID: " + eid)
		seen_events[eid] = true
		var tick := int(event.get("tick", -1))
		if tick < tick_start or tick > tick_end:
			errors.append("EVENT_TICK_OUT_OF_RANGE: " + eid)
		var phase := str(event.get("phase", ""))
		if not K.EVENT_PHASES.has(phase):
			errors.append("EVENT_PHASE_INVALID: %s (%s)" % [eid, phase])
		_validate_condition(event.get("condition", null), "event " + eid, errors)
		for effect in event.get("effects", []):
			_validate_effect(effect, "event " + eid, errors)

	var seen_instances := {}
	for inst in data.get("initial_instances", []):
		var iid := str(inst.get("instance_id", ""))
		if iid == "":
			errors.append("INITIAL_INSTANCE_MISSING_ID")
		if seen_instances.has(iid):
			errors.append("INITIAL_INSTANCE_DUPLICATE: " + iid)
		seen_instances[iid] = true
		if not data.get("entity_templates", {}).has(str(inst.get("lineage_id", ""))):
			errors.append("INITIAL_INSTANCE_UNKNOWN_LINEAGE: " + iid)

	for objective in data.get("objectives", []):
		var otick := int(objective.get("tick", -1))
		if otick < tick_start or otick > tick_end:
			errors.append("OBJECTIVE_TICK_OUT_OF_RANGE: " + str(objective.get("objective_id", "")))
		if not K.PHASES.has(str(objective.get("phase", ""))):
			errors.append("OBJECTIVE_PHASE_INVALID: " + str(objective.get("objective_id", "")))
		_validate_condition(objective.get("condition", null),
			"objective " + str(objective.get("objective_id", "")), errors)

	for invariant in data.get("invariants", []):
		_validate_condition(invariant.get("condition", null),
			"invariant " + str(invariant.get("invariant_id", "")), errors)

	if not errors.is_empty():
		return {"ok": false, "errors": errors}
	return {"ok": true, "case": data, "errors": []}

static func _validate_condition(condition, context: String, errors: Array) -> void:
	if condition == null:
		return
	if typeof(condition) != TYPE_DICTIONARY:
		errors.append("CONDITION_NOT_OBJECT in " + context)
		return
	var type := str(condition.get("type", ""))
	if not Evaluator.CONDITION_TYPES.has(type):
		errors.append("CONDITION_TYPE_UNKNOWN '%s' in %s" % [type, context])
		return
	if type == "and":
		for sub in condition.get("conditions", []):
			_validate_condition(sub, context, errors)
	elif type == "not":
		_validate_condition(condition.get("condition", null), context, errors)

static func _validate_effect(effect, context: String, errors: Array) -> void:
	if typeof(effect) != TYPE_DICTIONARY:
		errors.append("EFFECT_NOT_OBJECT in " + context)
		return
	var type := str(effect.get("type", ""))
	if not Evaluator.EFFECT_TYPES.has(type):
		errors.append("EFFECT_TYPE_UNKNOWN '%s' in %s" % [type, context])
		return
	match type:
		"set_global":
			if not effect.has("key"):
				errors.append("EFFECT_MISSING_KEY in " + context)
		"create_entity":
			for f in ["instance_id", "lineage_id"]:
				if not effect.has(f):
					errors.append("EFFECT_MISSING_%s in %s" % [f.to_upper(), context])
		"set_entity_state":
			if not effect.has("field"):
				errors.append("EFFECT_MISSING_FIELD in " + context)
		"move_entity":
			if not effect.has("location"):
				errors.append("EFFECT_MISSING_LOCATION in " + context)
		"add_knowledge":
			if not effect.has("token"):
				errors.append("EFFECT_MISSING_TOKEN in " + context)

## Builds the tick_start world state: templates, initial instances, globals.
static func build_initial_state(case_data: Dictionary):
	var state = WorldState.new()
	state.templates = case_data.get("entity_templates", {})
	var gkeys: Array = case_data.get("initial_globals", {}).keys()
	gkeys.sort()
	for key in gkeys:
		state.globals[key] = case_data["initial_globals"][key]
	for spec in case_data.get("initial_instances", []):
		var lineage := str(spec.get("lineage_id", ""))
		var template: Dictionary = case_data.get("entity_templates", {}).get(lineage, {})
		var inst = preload("res://engine/entity_instance.gd").new()
		inst.instance_id = str(spec.get("instance_id", lineage + ":BASE"))
		inst.lineage_id = lineage
		inst.entity_type = str(template.get("entity_type", "UNKNOWN"))
		inst.exists = true
		inst.location = str(spec.get("location", ""))
		inst.state = template.get("default_state", {}).duplicate(true)
		for field in spec.get("state", {}).keys():
			inst.state[field] = spec["state"][field]
		inst.origin = [{"kind": K.ORIGIN_INITIAL, "id": inst.instance_id, "tick": int(case_data["tick_start"])}]
		for token in spec.get("knowledge", []):
			inst.knowledge[str(token)] = [{
				"kind": K.ORIGIN_INITIAL, "id": inst.instance_id,
				"tick": int(case_data["tick_start"])}]
		state.instances[inst.instance_id] = inst
	return state
