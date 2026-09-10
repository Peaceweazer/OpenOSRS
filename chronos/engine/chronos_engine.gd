extends RefCounted
## CHRONOS — deterministic causal reconciliation engine.
##
## PARADOXES ARE ALLOWED. CONTRADICTIONS ARE NOT.
##
## A closed causal loop is legal if it is self-consistent. The engine fails only
## when no deterministic self-consistent timeline can be reached (oscillation,
## non-convergence) or when an explicit logical rule is violated (write
## conflict, invariant violation).
##
## Reconciliation is a fixed-point search over the canonical set of temporal
## arrivals A:  A0 = {} ; A(n+1) = Phi(A(n)) ; stable when A(n+1) == A(n).

const K = preload("res://engine/constants.gd")
const Canon = preload("res://engine/canonicalizer.gd")
const CaseLoader = preload("res://engine/case_loader.gd")
const Evaluator = preload("res://engine/event_evaluator.gd")
const Intervention = preload("res://engine/intervention.gd")
const WorldState = preload("res://engine/world_state.gd")

# ---------------------------------------------------------------------------
# Public entry point
# ---------------------------------------------------------------------------

## options:
##   max_iterations : override MAX_RECONCILIATION_ITERATIONS (tests only)
static func run(case_path: String, raw_interventions: Array, options := {}) -> Dictionary:
	var loaded := CaseLoader.load_case(case_path)
	if not loaded["ok"]:
		return {
			"classification": "CASE_LOAD_ERROR",
			"case_id": "",
			"case_path": case_path,
			"errors": loaded["errors"],
		}
	return run_case(loaded["case"], raw_interventions, options)

static func run_case(case_data: Dictionary, raw_interventions: Array, options := {}) -> Dictionary:
	var parsed := Intervention.parse_all(raw_interventions, case_data)
	if not parsed["ok"]:
		return _structurally_invalid(case_data, parsed)

	var interventions: Array = parsed["interventions"]
	var max_iterations := int(options.get("max_iterations", K.MAX_RECONCILIATION_ITERATIONS))

	var arrivals := []
	var seen := {}                 ## signature -> iteration index
	var iteration_log := []
	var termination := ""
	var instability = null
	var sim := {}
	var iterations_run := 0

	for i in range(max_iterations):
		sim = simulate(case_data, interventions, arrivals)
		iterations_run = i + 1
		var payload := {
			"input_arrivals": arrivals,
			"produced_arrivals": sim["produced_arrivals"],
			"intervention_statuses": sim["intervention_statuses"],
			"event_outcomes": sim["event_outcomes"],
			"world_state_summary": sim["world_state_summary"],
		}
		var signature := Canon.signature(payload)
		iteration_log.append({
			"iteration": i,
			"signature": signature,
			"input_arrival_count": arrivals.size(),
			"produced_arrival_count": sim["produced_arrivals"].size(),
		})
		if not sim["ok"]:
			termination = "CONTRADICTION"
			instability = sim["instability"]
			break
		if seen.has(signature):
			termination = "OSCILLATION"
			instability = {
				"reason": K.OSCILLATING_CAUSALITY,
				"period": i - int(seen[signature]),
				"first_iteration": int(seen[signature]),
				"repeat_iteration": i,
				"message": "reconciliation signature repeated after %d iterations" % [
					i - int(seen[signature])],
			}
			break
		seen[signature] = i
		if Canon.canonical(sim["produced_arrivals"]) == Canon.canonical(arrivals):
			termination = "FIXED_POINT"
			break
		arrivals = sim["produced_arrivals"]

	if termination == "":
		termination = "ITERATION_LIMIT"
		instability = {
			"reason": K.NO_CONVERGENCE,
			"max_iterations": max_iterations,
			"message": "no fixed point within %d reconciliation iterations" % [max_iterations],
		}

	return _build_result(case_data, interventions, sim, termination, instability,
		iteration_log, iterations_run)

# ---------------------------------------------------------------------------
# Phi : one forward simulation with an assumed arrival set
# ---------------------------------------------------------------------------

static func simulate(case_data: Dictionary, interventions: Array, arrival_set: Array) -> Dictionary:
	var state = CaseLoader.build_initial_state(case_data)
	var tick_start := int(case_data["tick_start"])
	var tick_end := int(case_data["tick_end"])

	var arrivals_by_tick := {}
	for arrival in arrival_set:
		var t := int(arrival["arrival_tick"])
		if not arrivals_by_tick.has(t):
			arrivals_by_tick[t] = []
		arrivals_by_tick[t].append(arrival)

	var departures_by_tick := {}
	for intervention in interventions:
		var t2 := int(intervention["departure_tick"])
		if not departures_by_tick.has(t2):
			departures_by_tick[t2] = []
		departures_by_tick[t2].append(intervention)

	var events_by_slot := {}
	for event in case_data["events"]:
		var slot := "%d:%s" % [int(event["tick"]), str(event["phase"])]
		if not events_by_slot.has(slot):
			events_by_slot[slot] = []
		events_by_slot[slot].append(event)

	var statuses := {}
	for intervention in interventions:
		statuses[intervention["transfer_id"]] = {
			"transfer_id": intervention["transfer_id"],
			"type": intervention["type"],
			"departure_tick": intervention["departure_tick"],
			"arrival_tick": intervention["arrival_tick"],
			"source_status": "NOT_REACHED",
			"delivery_status": "NO_ARRIVAL_ASSUMED",
			"detail": "",
			"source_instance_id": "",
			"candidates": [],
		}

	var event_outcomes := []
	var produced := []
	var snapshots := {}
	var arrival_log := []

	for tick in range(tick_start, tick_end + 1):
		for phase in K.PHASES:
			var snapshot = state.clone()
			var writes := []
			match phase:
				K.PHASE_TEMPORAL_ARRIVAL:
					var pending: Array = arrivals_by_tick.get(tick, [])
					for arrival in Canon.sorted_records(pending):
						_apply_arrival(arrival, snapshot, writes, statuses, arrival_log, tick)
				K.PHASE_ENVIRONMENT, K.PHASE_ACTOR:
					var slot2 := "%d:%s" % [tick, phase]
					var slot_events: Array = events_by_slot.get(slot2, []).duplicate()
					slot_events.sort_custom(func(a, b): return str(a["event_id"]) < str(b["event_id"]))
					for event in slot_events:
						_evaluate_event(event, snapshot, writes, event_outcomes, tick, phase)
				K.PHASE_TEMPORAL_DEPARTURE:
					_process_departures(departures_by_tick.get(tick, []), snapshot, writes,
						statuses, produced, tick)
				K.PHASE_CLEANUP:
					pass

			var commit := state.commit(writes)
			if not commit["ok"]:
				return _abort(state, statuses, event_outcomes, produced, snapshots, arrival_log, {
					"reason": K.WRITE_CONFLICT,
					"tick": tick,
					"phase": phase,
					"conflicts": commit["conflicts"],
					"message": "incompatible simultaneous writes at T%d/%s" % [tick, phase],
				})
			snapshots["T%d:%s" % [tick, phase]] = state.clone()

		for invariant in case_data.get("invariants", []):
			var check := Evaluator.evaluate(invariant.get("condition", null), state)
			if not check["ok"]:
				return _abort(state, statuses, event_outcomes, produced, snapshots, arrival_log, {
					"reason": K.INVARIANT_VIOLATION,
					"invariant_id": str(invariant.get("invariant_id", "")),
					"tick": tick,
					"reasons": check["reasons"],
					"message": "invariant %s violated at end of T%d" % [
						str(invariant.get("invariant_id", "")), tick],
				})

	return {
		"ok": true,
		"instability": null,
		"produced_arrivals": Canon.sorted_records(produced),
		"intervention_statuses": statuses,
		"event_outcomes": event_outcomes,
		"arrival_log": arrival_log,
		"snapshots": snapshots,
		"final_state": state,
		"world_state_summary": state.summary(),
	}

static func _abort(state, statuses, event_outcomes, produced, snapshots, arrival_log, instability) -> Dictionary:
	return {
		"ok": false,
		"instability": instability,
		"produced_arrivals": Canon.sorted_records(produced),
		"intervention_statuses": statuses,
		"event_outcomes": event_outcomes,
		"arrival_log": arrival_log,
		"snapshots": snapshots,
		"final_state": state,
		"world_state_summary": state.summary(),
	}

# ---------------------------------------------------------------------------
# Phase handlers
# ---------------------------------------------------------------------------

static func _apply_arrival(arrival: Dictionary, snapshot, writes: Array, statuses: Dictionary,
		arrival_log: Array, tick: int) -> void:
	var transfer_id := str(arrival["transfer_id"])
	var source := {
		"kind": K.ORIGIN_TEMPORAL_ARRIVAL,
		"id": transfer_id,
		"transfer_id": transfer_id,
		"tick": tick,
		"phase": K.PHASE_TEMPORAL_ARRIVAL,
	}
	if str(arrival["kind"]) == K.TRANSFER_PHYSICAL:
		var spec := {
			"instance_id": str(arrival["instance_id"]),
			"lineage_id": str(arrival["lineage_id"]),
			"location": str(arrival["location"]),
			"state": arrival["state"],
			"knowledge": arrival["knowledge"],
			"temporal": true,
			"transfer_id": transfer_id,
		}
		writes.append(WorldState.write_materialize(spec, source))
		writes.append(WorldState.write_location(spec["instance_id"], spec["location"], source))
		for field in spec["state"].keys():
			writes.append(WorldState.write_state(spec["instance_id"], str(field),
				spec["state"][field], source))
		for token in spec["knowledge"]:
			writes.append(WorldState.write_knowledge(spec["instance_id"], str(token), source))
		if statuses.has(transfer_id):
			statuses[transfer_id]["delivery_status"] = "DELIVERED"
		arrival_log.append({
			"transfer_id": transfer_id, "tick": tick, "kind": K.TRANSFER_PHYSICAL,
			"instance_id": spec["instance_id"], "status": "DELIVERED",
		})
	else:
		var receivers: Array = snapshot.select({"lineage_id": str(arrival["receiver_lineage"])})
		if receivers.size() == 1:
			writes.append(WorldState.write_knowledge(receivers[0].instance_id,
				str(arrival["token"]), source))
			if statuses.has(transfer_id):
				statuses[transfer_id]["delivery_status"] = "DELIVERED"
			arrival_log.append({
				"transfer_id": transfer_id, "tick": tick, "kind": K.TRANSFER_INFORMATION,
				"instance_id": receivers[0].instance_id, "token": str(arrival["token"]),
				"status": "DELIVERED",
			})
		else:
			var status := K.RECEIVER_UNAVAILABLE if receivers.is_empty() else K.RECEIVER_AMBIGUOUS
			if statuses.has(transfer_id):
				statuses[transfer_id]["delivery_status"] = status
			arrival_log.append({
				"transfer_id": transfer_id, "tick": tick, "kind": K.TRANSFER_INFORMATION,
				"token": str(arrival["token"]), "status": status,
			})

static func _evaluate_event(event: Dictionary, snapshot, writes: Array, outcomes: Array,
		tick: int, phase: String) -> void:
	var event_id := str(event["event_id"])
	var source := {"kind": K.ORIGIN_EVENT, "id": event_id, "tick": tick, "phase": phase}
	var check := Evaluator.evaluate(event.get("condition", null), snapshot)
	if not check["ok"]:
		outcomes.append({
			"event_id": event_id, "tick": tick, "phase": phase,
			"outcome": K.BLOCKED, "reasons": check["reasons"],
			"description": str(event.get("description", "")),
		})
		return
	var effects := Evaluator.compute_effects(event.get("effects", []), snapshot, source)
	if not effects["ok"]:
		outcomes.append({
			"event_id": event_id, "tick": tick, "phase": phase,
			"outcome": K.BLOCKED, "reasons": effects["reasons"],
			"description": str(event.get("description", "")),
		})
		return
	for w in effects["writes"]:
		writes.append(w)
	outcomes.append({
		"event_id": event_id, "tick": tick, "phase": phase,
		"outcome": K.EXECUTED, "reasons": [],
		"description": str(event.get("description", "")),
	})

## Temporal departures. MOVE semantics: the resolved source leaves the local
## timeline after all normal events at that tick, and produces exactly one
## arrival record for the earlier tick.
static func _process_departures(departures: Array, snapshot, writes: Array,
		statuses: Dictionary, produced: Array, tick: int) -> void:
	var ordered: Array = departures.duplicate()
	ordered.sort_custom(func(a, b): return str(a["transfer_id"]) < str(b["transfer_id"]))

	var resolutions := []
	for intervention in ordered:
		resolutions.append(_resolve_source(intervention, snapshot))

	# A single source instance cannot serve two physical departures.
	var claims := {}
	for r in resolutions:
		if r["status"] == K.SOURCE_RESOLVED and r["intervention"]["type"] == K.TRANSFER_PHYSICAL:
			var id: String = r["instance"].instance_id
			claims[id] = int(claims.get(id, 0)) + 1
	for r in resolutions:
		if r["status"] == K.SOURCE_RESOLVED and r["intervention"]["type"] == K.TRANSFER_PHYSICAL:
			if int(claims.get(r["instance"].instance_id, 0)) > 1:
				r["status"] = K.SOURCE_CONTESTED
				r["detail"] = "instance %s claimed by several transfers at T%d" % [
					r["instance"].instance_id, tick]

	for r in resolutions:
		var intervention: Dictionary = r["intervention"]
		var transfer_id: String = intervention["transfer_id"]
		var status: Dictionary = statuses[transfer_id]
		status["source_status"] = r["status"]
		status["detail"] = str(r.get("detail", ""))
		status["candidates"] = r.get("candidates", [])
		if r["status"] != K.SOURCE_RESOLVED:
			continue
		var inst = r["instance"]
		status["source_instance_id"] = inst.instance_id
		var source := {
			"kind": "TEMPORAL_DEPARTURE",
			"id": transfer_id,
			"transfer_id": transfer_id,
			"tick": tick,
			"phase": K.PHASE_TEMPORAL_DEPARTURE,
		}
		if intervention["type"] == K.TRANSFER_PHYSICAL:
			var captured: Dictionary = inst.transferable_snapshot()
			var arrival_location := str(intervention.get("arrival_location", captured["location"]))
			produced.append({
				"transfer_id": transfer_id,
				"kind": K.TRANSFER_PHYSICAL,
				"arrival_tick": int(intervention["arrival_tick"]),
				"departure_tick": int(intervention["departure_tick"]),
				"lineage_id": inst.lineage_id,
				"instance_id": Intervention.temporal_instance_id(inst.lineage_id, transfer_id),
				"location": arrival_location,
				"state": captured["state"],
				"knowledge": captured["knowledge"],
				"source_instance_id": inst.instance_id,
			})
			writes.append(WorldState.write_exists(inst.instance_id, false, source))
		else:
			produced.append({
				"transfer_id": transfer_id,
				"kind": K.TRANSFER_INFORMATION,
				"arrival_tick": int(intervention["arrival_tick"]),
				"departure_tick": int(intervention["departure_tick"]),
				"receiver_lineage": str(intervention["receiver_lineage"]),
				"token": str(intervention["knowledge_token"]),
				"source_instance_id": inst.instance_id,
			})

static func _resolve_source(intervention: Dictionary, snapshot) -> Dictionary:
	var selector := Intervention.source_selector(intervention)
	var matches: Array = snapshot.select(selector)
	var ids := []
	for m in matches:
		ids.append(m.instance_id)
	if matches.is_empty():
		return {"intervention": intervention, "status": K.SOURCE_UNAVAILABLE, "candidates": [],
			"detail": "no active instance matches %s" % [Evaluator.describe_selector(selector)]}
	if matches.size() > 1:
		return {"intervention": intervention, "status": K.SOURCE_AMBIGUOUS, "candidates": ids,
			"detail": "%d candidate sources: %s" % [matches.size(), ", ".join(ids)]}
	if intervention["type"] == K.TRANSFER_INFORMATION:
		var token := str(intervention["knowledge_token"])
		if not matches[0].knowledge.has(token):
			return {"intervention": intervention, "status": K.SOURCE_UNAVAILABLE, "candidates": ids,
				"detail": "SENDER_LACKS_KNOWLEDGE: %s does not know %s" % [
					matches[0].instance_id, token]}
	return {"intervention": intervention, "status": K.SOURCE_RESOLVED, "candidates": ids,
		"instance": matches[0], "detail": ""}

# ---------------------------------------------------------------------------
# Result assembly
# ---------------------------------------------------------------------------

static func _structurally_invalid(case_data: Dictionary, parsed: Dictionary) -> Dictionary:
	var statuses := {}
	var keys: Array = parsed["errors"].keys()
	keys.sort()
	for tid in keys:
		statuses[tid] = {
			"transfer_id": tid,
			"source_status": K.STRUCTURALLY_INVALID,
			"delivery_status": "NO_ARRIVAL_ASSUMED",
			"detail": ", ".join(parsed["errors"][tid]),
		}
	return {
		"case_id": str(case_data.get("case_id", "")),
		"case_title": str(case_data.get("title", "")),
		"classification": K.INVALID_INTERVENTION,
		"instability": null,
		"termination": "STRUCTURAL_VALIDATION",
		"iterations": 0,
		"iteration_log": [],
		"final_arrivals": [],
		"intervention_statuses": statuses,
		"event_outcomes": [],
		"objectives": [],
		"causal_loops": [],
		"chronal_load": {"total": 0, "transfers": [], "person_overlap_ticks": 0},
		"world_state_summary": {},
		"arrival_log": [],
	}

static func _build_result(case_data: Dictionary, interventions: Array, sim: Dictionary,
		termination: String, instability, iteration_log: Array, iterations_run: int) -> Dictionary:
	var stable := termination == "FIXED_POINT"
	var objectives := _evaluate_objectives(case_data, sim, stable)
	var statuses: Dictionary = sim.get("intervention_statuses", {})

	var interventions_valid := true
	var status_keys: Array = statuses.keys()
	status_keys.sort()
	for tid in status_keys:
		var s: Dictionary = statuses[tid]
		if str(s["source_status"]) != K.SOURCE_RESOLVED or str(s["delivery_status"]) != "DELIVERED":
			interventions_valid = false

	var classification := ""
	if not stable:
		classification = K.UNSTABLE
	elif not interventions_valid:
		classification = K.INVALID_INTERVENTION
	else:
		var all_met := true
		for objective in objectives:
			if not bool(objective["satisfied"]):
				all_met = false
		classification = K.STABLE_SOLVED if all_met else K.STABLE_UNSOLVED

	var loops := _causal_loops(interventions, sim, stable)
	var load := _chronal_load(case_data, interventions, sim, stable)

	var ordered_statuses := {}
	for tid in status_keys:
		ordered_statuses[tid] = statuses[tid]

	var result := {
		"case_id": str(case_data.get("case_id", "")),
		"case_title": str(case_data.get("title", "")),
		"classification": classification,
		"termination": termination,
		"instability": instability,
		"iterations": iterations_run,
		"iteration_log": iteration_log,
		"final_arrivals": sim.get("produced_arrivals", []),
		"intervention_statuses": ordered_statuses,
		"event_outcomes": sim.get("event_outcomes", []),
		"arrival_log": sim.get("arrival_log", []),
		"objectives": objectives,
		"causal_loops": loops,
		"chronal_load": load,
		"world_state_summary": sim.get("world_state_summary", {}),
	}
	result["signature"] = Canon.signature(result)
	return result

static func _evaluate_objectives(case_data: Dictionary, sim: Dictionary, stable: bool) -> Array:
	var out := []
	var snapshots: Dictionary = sim.get("snapshots", {})
	for objective in case_data.get("objectives", []):
		var key := "T%d:%s" % [int(objective["tick"]), str(objective["phase"])]
		var record := {
			"objective_id": str(objective.get("objective_id", "")),
			"description": str(objective.get("description", "")),
			"evaluated_at": key,
			"satisfied": false,
			"reasons": [],
		}
		if not stable:
			record["reasons"] = [{"code": "NOT_EVALUATED",
				"message": "timeline never reached a fixed point"}]
		elif not snapshots.has(key):
			record["reasons"] = [{"code": "SNAPSHOT_MISSING",
				"message": "no state snapshot for " + key}]
		else:
			var check := Evaluator.evaluate(objective.get("condition", null), snapshots[key])
			record["satisfied"] = check["ok"]
			record["reasons"] = check["reasons"]
		out.append(record)
	return out

## Detects closed causal loops at the fixed point.
##
## Object bootstrap : the departing source instance owes its existence to this
##                    same transfer's arrival.
## Information bootstrap : the sender knows the token only because of this same
##                    transfer's arrival.
## The walk uses a visited set, so a cycle is reported as a cycle and never
## expanded into an infinite chain.
static func _causal_loops(interventions: Array, sim: Dictionary, stable: bool) -> Array:
	if not stable:
		return []
	var loops := []
	var statuses: Dictionary = sim.get("intervention_statuses", {})
	var final_state = sim.get("final_state", null)
	if final_state == null:
		return []
	for intervention in interventions:
		var tid: String = intervention["transfer_id"]
		var status: Dictionary = statuses.get(tid, {})
		if str(status.get("source_status", "")) != K.SOURCE_RESOLVED:
			continue
		var source_id := str(status.get("source_instance_id", ""))
		if intervention["type"] == K.TRANSFER_PHYSICAL:
			var trace := _trace_origin(source_id, final_state, tid)
			if trace["loop"]:
				loops.append({
					"transfer_id": tid,
					"kind": K.LOOP_OBJECT_BOOTSTRAP,
					"lineage_id": intervention["lineage_id"],
					"chain": trace["chain"],
					"message": "%s exists only because of transfer %s: no manufacturing origin" % [
						intervention["lineage_id"], tid],
				})
		else:
			var sender = final_state.get_instance(source_id)
			if sender == null:
				continue
			var token := str(intervention["knowledge_token"])
			for acquisition in sender.knowledge.get(token, []):
				if str(acquisition.get("kind", "")) == K.ORIGIN_TEMPORAL_ARRIVAL \
						and str(acquisition.get("transfer_id", "")) == tid:
					loops.append({
						"transfer_id": tid,
						"kind": K.LOOP_INFORMATION_BOOTSTRAP,
						"token": token,
						"chain": [source_id, "ARRIVAL:" + tid, source_id],
						"message": "%s knows %s only because of transfer %s: no original author" % [
							sender.lineage_id, token, tid],
					})
					break
	return Canon.sorted_records(loops)

static func _trace_origin(instance_id: String, final_state, transfer_id: String) -> Dictionary:
	var chain := []
	var visited := {}
	var current := instance_id
	while current != "" and not visited.has(current):
		visited[current] = true
		chain.append(current)
		var inst = final_state.get_instance(current)
		if inst == null:
			break
		var next := ""
		for origin in inst.origin:
			if str(origin.get("kind", "")) == K.ORIGIN_TEMPORAL_ARRIVAL:
				chain.append("ARRIVAL:" + str(origin.get("transfer_id", "")))
				if str(origin.get("transfer_id", "")) == transfer_id:
					return {"loop": true, "chain": chain}
				next = ""
		current = next
	return {"loop": false, "chain": chain}

## Chronal Load — DIAGNOSTIC ONLY. Never gates a solution.
##
##   load = sum over valid transfers of (temporal_distance * type_weight + 2)
##          + 1 per tick of additional PERSON temporal self-overlap
static func _chronal_load(case_data: Dictionary, interventions: Array, sim: Dictionary,
		stable: bool) -> Dictionary:
	var transfers := []
	var total := 0
	var statuses: Dictionary = sim.get("intervention_statuses", {})
	for intervention in interventions:
		var tid: String = intervention["transfer_id"]
		if str(statuses.get(tid, {}).get("source_status", "")) != K.SOURCE_RESOLVED:
			continue
		var distance := Intervention.temporal_distance(intervention)
		var weight := K.CHRONAL_TYPE_WEIGHTS["INFORMATION"]
		if intervention["type"] == K.TRANSFER_PHYSICAL:
			var lineage: String = intervention["lineage_id"]
			var entity_type := str(case_data.get("entity_templates", {}).get(lineage, {}).get(
				"entity_type", ""))
			weight = int(K.CHRONAL_TYPE_WEIGHTS.get(entity_type, K.CHRONAL_DEFAULT_TYPE_WEIGHT))
		var contribution := distance * weight + K.CHRONAL_TRANSFER_OVERHEAD
		total += contribution
		transfers.append({
			"transfer_id": tid,
			"temporal_distance": distance,
			"type_weight": weight,
			"load": contribution,
		})
	var overlap := _person_overlap_ticks(sim)
	total += overlap * K.CHRONAL_PERSON_OVERLAP_PER_TICK
	return {
		"total": total,
		"transfers": Canon.sorted_records(transfers),
		"person_overlap_ticks": overlap,
	}

## Counts additional simultaneous PERSON instances per tick, measured after the
## ACTOR phase of each tick.
static func _person_overlap_ticks(sim: Dictionary) -> int:
	var snapshots: Dictionary = sim.get("snapshots", {})
	var keys: Array = snapshots.keys()
	keys.sort()
	var overlap := 0
	for key in keys:
		if not key.ends_with(":" + K.PHASE_ACTOR):
			continue
		var counts := {}
		for inst in snapshots[key].active_instances():
			if inst.entity_type != "PERSON":
				continue
			counts[inst.lineage_id] = int(counts.get(inst.lineage_id, 0)) + 1
		for lineage in counts.keys():
			if int(counts[lineage]) > 1:
				overlap += int(counts[lineage]) - 1
	return overlap
