extends RefCounted
## Deterministic discrete world state for one simulated tick sequence.
##
## Two storage areas:
##   globals   : flat "OBJECT.field" -> bool/int/String
##   instances : instance_id -> EntityInstance
##
## All mutation goes through writes committed at the end of a phase, so that
## every event in a phase reads the same phase-start state and simultaneous
## conflicting writes are detectable instead of order-dependent.

const K = preload("res://engine/constants.gd")
const Canon = preload("res://engine/canonicalizer.gd")
const Instance = preload("res://engine/entity_instance.gd")

var globals := {}
var instances := {}
var templates := {}   ## lineage_id -> template dictionary (read-only)

func clone():
	var c = get_script().new()
	c.globals = globals.duplicate(true)
	c.templates = templates
	for id in instances.keys():
		c.instances[id] = instances[id].clone()
	return c

func active_instances() -> Array:
	var ids := instances.keys()
	ids.sort()
	var out := []
	for id in ids:
		if instances[id].exists:
			out.append(instances[id])
	return out

func all_instances_sorted() -> Array:
	var ids := instances.keys()
	ids.sort()
	var out := []
	for id in ids:
		out.append(instances[id])
	return out

func get_instance(instance_id: String):
	return instances.get(instance_id, null)

func entity_type_for(lineage_id: String) -> String:
	var tpl = templates.get(lineage_id, null)
	if tpl == null:
		return "UNKNOWN"
	return str(tpl.get("entity_type", "UNKNOWN"))

## Resolves a selector to every matching ACTIVE instance, sorted by instance_id.
##
## Selector fields (all optional, all ANDed):
##   instance_id, lineage_id, entity_type, location, temporal (bool),
##   state {field: value}, knows [tokens]
func select(selector: Dictionary) -> Array:
	var out := []
	for inst in active_instances():
		if selector.has("instance_id") and inst.instance_id != selector["instance_id"]:
			continue
		if selector.has("lineage_id") and inst.lineage_id != selector["lineage_id"]:
			continue
		if selector.has("entity_type") and inst.entity_type != selector["entity_type"]:
			continue
		if selector.has("location") and inst.location != selector["location"]:
			continue
		if selector.has("temporal") and inst.temporal != bool(selector["temporal"]):
			continue
		var ok := true
		if selector.has("state"):
			for field in selector["state"].keys():
				if not inst.state.has(field):
					ok = false
					break
				if Canon.canonical(inst.state[field]) != Canon.canonical(selector["state"][field]):
					ok = false
					break
		if ok and selector.has("knows"):
			for token in selector["knows"]:
				if not inst.knowledge.has(token):
					ok = false
					break
		if ok:
			out.append(inst)
	return out

# ---------------------------------------------------------------------------
# Writes
# ---------------------------------------------------------------------------

static func write_global(key: String, value, source: Dictionary) -> Dictionary:
	return {"key": "GLOBAL:" + key, "op": "SET_GLOBAL", "global_key": key,
		"value": value, "source": source}

static func write_state(instance_id: String, field: String, value, source: Dictionary) -> Dictionary:
	return {"key": "INSTANCE:%s:STATE:%s" % [instance_id, field], "op": "SET_STATE",
		"instance_id": instance_id, "field": field, "value": value, "source": source}

static func write_location(instance_id: String, location: String, source: Dictionary) -> Dictionary:
	return {"key": "INSTANCE:%s:LOCATION" % instance_id, "op": "SET_LOCATION",
		"instance_id": instance_id, "value": location, "source": source}

static func write_exists(instance_id: String, value: bool, source: Dictionary) -> Dictionary:
	return {"key": "INSTANCE:%s:EXISTS" % instance_id, "op": "SET_EXISTS",
		"instance_id": instance_id, "value": value, "source": source}

static func write_knowledge(instance_id: String, token: String, source: Dictionary) -> Dictionary:
	return {"key": "INSTANCE:%s:KNOWLEDGE:%s" % [instance_id, token], "op": "ADD_KNOWLEDGE",
		"instance_id": instance_id, "token": token, "value": true, "source": source}

## Materialization carries the identity fields needed to construct an instance
## that may not exist yet. Its conflict key is the instance's EXISTS slot, so a
## creation and a destruction in the same phase collide as a WRITE_CONFLICT.
static func write_materialize(spec: Dictionary, source: Dictionary) -> Dictionary:
	return {"key": "INSTANCE:%s:EXISTS" % spec["instance_id"], "op": "MATERIALIZE",
		"instance_id": spec["instance_id"], "value": true, "spec": spec, "source": source}

## Commits a phase's writes simultaneously.
##
## Returns {"ok": true} or {"ok": false, "conflicts": [...]}.
## Two writes to the same location are a WRITE_CONFLICT unless their canonical
## values are identical; identical simultaneous writes are explicitly permitted
## (documented in README, section "Same-phase semantics").
func commit(writes: Array) -> Dictionary:
	var groups := {}
	for w in writes:
		var key: String = w["key"]
		if not groups.has(key):
			groups[key] = []
		groups[key].append(w)

	var keys := groups.keys()
	keys.sort()
	var conflicts := []
	for key in keys:
		var distinct := {}
		for w in groups[key]:
			distinct[Canon.canonical(w["value"])] = true
		if distinct.size() > 1:
			var values := distinct.keys()
			values.sort()
			var sources := []
			for w in groups[key]:
				sources.append({"value": Canon.canonical(w["value"]), "source": w["source"]})
			conflicts.append({
				"location": key,
				"values": values,
				"writers": Canon.sorted_records(sources),
			})
	if not conflicts.is_empty():
		return {"ok": false, "conflicts": conflicts}

	# Pass 1: materialize instances so later writes have a target.
	for key in keys:
		for w in groups[key]:
			if w["op"] == "MATERIALIZE":
				_materialize(w)
	# Pass 2: everything else, in canonical key order.
	for key in keys:
		for w in groups[key]:
			_apply(w)
	return {"ok": true}

func _materialize(w: Dictionary) -> void:
	var spec: Dictionary = w["spec"]
	var id: String = spec["instance_id"]
	var inst = instances.get(id, null)
	if inst == null:
		inst = Instance.new()
		inst.instance_id = id
		inst.lineage_id = str(spec.get("lineage_id", ""))
		inst.entity_type = entity_type_for(inst.lineage_id)
		inst.temporal = bool(spec.get("temporal", false))
		inst.transfer_id = str(spec.get("transfer_id", ""))
		instances[id] = inst
	inst.exists = true
	inst.removal = null
	if spec.has("location"):
		inst.location = str(spec["location"])
	if spec.has("state"):
		for field in spec["state"].keys():
			inst.state[field] = spec["state"][field]
	if spec.has("knowledge"):
		for token in spec["knowledge"]:
			_record_knowledge(inst, str(token), w["source"])
	# An instance may legally have several contributing origins (two identical
	# simultaneous creations). Origins are a sorted, deduplicated set.
	var origins: Array = inst.origin.duplicate(true)
	origins.append(w["source"])
	inst.origin = _dedup_records(origins)

func _apply(w: Dictionary) -> void:
	match w["op"]:
		"SET_GLOBAL":
			globals[w["global_key"]] = w["value"]
		"MATERIALIZE":
			pass  # handled in pass 1
		"SET_EXISTS":
			var inst = instances.get(w["instance_id"], null)
			if inst == null:
				return
			inst.exists = bool(w["value"])
			if not inst.exists:
				inst.removal = w["source"]
		"SET_LOCATION":
			var inst2 = instances.get(w["instance_id"], null)
			if inst2 != null:
				inst2.location = str(w["value"])
		"SET_STATE":
			var inst3 = instances.get(w["instance_id"], null)
			if inst3 != null:
				inst3.state[w["field"]] = w["value"]
		"ADD_KNOWLEDGE":
			var inst4 = instances.get(w["instance_id"], null)
			if inst4 != null:
				_record_knowledge(inst4, str(w["token"]), w["source"])

func _record_knowledge(inst, token: String, source: Dictionary) -> void:
	if not inst.knowledge.has(token):
		inst.knowledge[token] = []
	var acquisitions: Array = inst.knowledge[token]
	acquisitions.append(source)
	inst.knowledge[token] = _dedup_records(acquisitions)

static func _dedup_records(records: Array) -> Array:
	var seen := {}
	var unique := []
	for r in records:
		var c := Canon.canonical(r)
		if not seen.has(c):
			seen[c] = true
			unique.append(r)
	return Canon.sorted_records(unique)

## Provenance-free causal summary used for signatures and diagnostics.
func summary() -> Dictionary:
	var gkeys := globals.keys()
	gkeys.sort()
	var g := {}
	for k in gkeys:
		g[k] = globals[k]
	var insts := []
	for inst in all_instances_sorted():
		insts.append(inst.summary())
	return {"globals": g, "instances": insts}
