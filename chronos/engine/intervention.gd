extends RefCounted
## Player interventions.
##
## Interventions exist OUTSIDE simulated causal time: CHRONOS operators are
## causally insulated. Once submitted, an intervention participates in every
## reconciliation iteration, even if the timeline erases the reason the operator
## had for choosing it.
##
## Only backwards transfer is supported: arrival_tick < departure_tick.

const K = preload("res://engine/constants.gd")

## Deterministic temporal instance identity.
##
## An arrival's identity is derived ONLY from the lineage and the transfer that
## produced it. It is NEVER derived from the source instance_id, so a bootstrap
## loop cannot produce nested identities such as KEY:TR:X:TR:X.
static func temporal_instance_id(lineage_id: String, transfer_id: String) -> String:
	return "%s:TR:%s" % [lineage_id, transfer_id]

static func parse_all(raw_list: Array, case_data: Dictionary) -> Dictionary:
	var parsed := []
	var errors := {}
	var seen := {}
	for raw in raw_list:
		var result := parse(raw, case_data)
		var tid := str(raw.get("transfer_id", ""))
		if seen.has(tid):
			result["ok"] = false
			result["errors"] = result.get("errors", []) + ["DUPLICATE_TRANSFER_ID"]
		seen[tid] = true
		if result["ok"]:
			parsed.append(result["intervention"])
		else:
			errors[tid] = result["errors"]
	parsed.sort_custom(func(a, b): return a["transfer_id"] < b["transfer_id"])
	return {"ok": errors.is_empty(), "interventions": parsed, "errors": errors}

static func parse(raw: Dictionary, case_data: Dictionary) -> Dictionary:
	var errors := []
	var tid := str(raw.get("transfer_id", ""))
	if tid == "":
		errors.append("MISSING_TRANSFER_ID")
	var type := str(raw.get("type", ""))
	if type != K.TRANSFER_PHYSICAL and type != K.TRANSFER_INFORMATION:
		errors.append("UNKNOWN_TRANSFER_TYPE: " + type)
	if not raw.has("departure_tick") or not raw.has("arrival_tick"):
		errors.append("MISSING_TICKS")
		return {"ok": false, "errors": errors}
	var departure := int(raw["departure_tick"])
	var arrival := int(raw["arrival_tick"])
	var tick_start := int(case_data["tick_start"])
	var tick_end := int(case_data["tick_end"])
	if arrival >= departure:
		errors.append("NOT_A_BACKWARDS_TRANSFER: arrival_tick must be < departure_tick")
	if departure < tick_start or departure > tick_end:
		errors.append("DEPARTURE_TICK_OUT_OF_RANGE")
	if arrival < tick_start or arrival > tick_end:
		errors.append("ARRIVAL_TICK_OUT_OF_RANGE")

	var intervention := {
		"transfer_id": tid,
		"type": type,
		"departure_tick": departure,
		"arrival_tick": arrival,
	}
	if type == K.TRANSFER_PHYSICAL:
		var lineage := str(raw.get("lineage_id", ""))
		if lineage == "":
			errors.append("MISSING_LINEAGE_ID")
		elif not case_data.get("entity_templates", {}).has(lineage):
			errors.append("UNKNOWN_LINEAGE: " + lineage)
		intervention["lineage_id"] = lineage
		if raw.has("required_departure_location"):
			intervention["required_departure_location"] = str(raw["required_departure_location"])
		if raw.has("source_instance_id"):
			intervention["source_instance_id"] = str(raw["source_instance_id"])
		if raw.has("arrival_location"):
			intervention["arrival_location"] = str(raw["arrival_location"])
	elif type == K.TRANSFER_INFORMATION:
		var sender := str(raw.get("sender_lineage", ""))
		var receiver := str(raw.get("receiver_lineage", ""))
		var token := str(raw.get("knowledge_token", ""))
		if sender == "":
			errors.append("MISSING_SENDER_LINEAGE")
		if receiver == "":
			errors.append("MISSING_RECEIVER_LINEAGE")
		if token == "":
			errors.append("MISSING_KNOWLEDGE_TOKEN")
		intervention["sender_lineage"] = sender
		intervention["receiver_lineage"] = receiver
		intervention["knowledge_token"] = token
		if raw.has("required_departure_location"):
			intervention["required_departure_location"] = str(raw["required_departure_location"])
		if raw.has("source_instance_id"):
			intervention["source_instance_id"] = str(raw["source_instance_id"])

	if not errors.is_empty():
		return {"ok": false, "errors": errors}
	return {"ok": true, "intervention": intervention}

## Selector used to resolve the departing source at the departure tick.
static func source_selector(intervention: Dictionary) -> Dictionary:
	var selector := {}
	if intervention["type"] == K.TRANSFER_PHYSICAL:
		selector["lineage_id"] = intervention["lineage_id"]
	else:
		selector["lineage_id"] = intervention["sender_lineage"]
	if intervention.has("source_instance_id"):
		selector["instance_id"] = intervention["source_instance_id"]
	if intervention.has("required_departure_location"):
		selector["location"] = intervention["required_departure_location"]
	return selector

static func temporal_distance(intervention: Dictionary) -> int:
	return int(intervention["departure_tick"]) - int(intervention["arrival_tick"])
