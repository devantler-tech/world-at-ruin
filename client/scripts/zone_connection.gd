class_name ZoneConnection
extends RefCounted
## The client half of the live replication link (issue #244, epic #4).
##
## `WireCodec` decodes the zone server's frames and `ReplicaStore` folds them
## into an entity table, but until now nothing opened a socket, so neither was
## reachable from the running game. This is that missing pump: it owns the
## connection lifecycle, drains whatever the transport delivers, and drives
## every frame through `WireCodec.decode` then `ReplicaStore.apply`.
##
## It adds NO wire or fold semantics of its own. Both of those contracts are
## settled and pinned by cross-tier goldens; this class only decides WHEN to
## feed them and WHAT to do when they refuse.
##
## ## The transport seam
##
## The transport is injected, and its contract is deliberately the subset of
## `WebSocketPeer` this class uses — `connect_to_url`, `poll`,
## `get_ready_state`, `get_available_packet_count`, `get_packet`, `close`.
## Because that IS the engine's own API, the shipped transport is a plain
## `WebSocketPeer` with no adapter in between (nothing can drift between an
## adapter and the real socket), while a test can pass a scripted fake that
## yields chosen frames and ready-states with no server and no network. The
## same path-injection pivot `character_store.gd` uses for saves.
##
## A transport missing any of those methods is refused at construction rather
## than failing later inside `poll`, where the cause would be far from the
## mistake.
##
## ## Fail-closed
##
## A refusal from either the decoder or the store means the stream and our
## view of the world have diverged. There is no safe way to keep folding
## across that: the wire contract is ordered, so every later frame is stated
## relative to a base we no longer share. So ANY refusal is terminal for the
## connection — the socket is closed, the error class is recorded, and the
## table is left exactly as it was (`ReplicaStore.apply` is atomic, proven by
## its own suite).
##
## Terminal is not wedged. `FAILED` and `CLOSED` are both observable, and
## `connect_to` may be called again from either: a reconnect starts a FRESH
## store, because recovery means receiving a new join snapshot as the new
## base, never resuming against a stale table.
##
## ## Default-off
##
## Off unless `WAR_ZONE_URL` names a zone. With it unset — every shipped boot
## today — nothing here runs and the client behaves exactly as it did before.

## Opt-in environment variable. Its VALUE is the zone URL, so naming a zone
## is itself the opt-in; unset or empty means disabled.
const ZONE_URL_ENV := "WAR_ZONE_URL"

## Lifecycle. `LIVE` is the only state in which frames are consumed.
enum State {
	DISCONNECTED,  ## constructed, never connected
	CONNECTING,    ## handshake in flight
	LIVE,          ## open; frames are being folded
	CLOSED,        ## closed cleanly, by us or by the peer
	FAILED,        ## terminal: see error()/error_detail()
}

## Error classes. String constants like `WireCodec.ERR_*` / `ReplicaStore.ERR_*`
## so a caller can classify a failure without string-matching details. A
## refusal from the decoder or the store is surfaced under ITS OWN class, not
## re-labelled here — the caller learns what actually diverged.
const ERR_TRANSPORT := "transport"  # transport does not satisfy the contract
const ERR_URL := "url"              # empty/blank url
const ERR_STATE := "state"          # connect_to while already connecting/live
const ERR_OPEN := "open"            # transport refused to open the url

## The transport contract: exactly the `WebSocketPeer` methods used below.
const REQUIRED_TRANSPORT_METHODS: Array[String] = [
	"connect_to_url",
	"poll",
	"get_ready_state",
	"get_available_packet_count",
	"get_packet",
	"close",
]

var _transport: Object = null
var _store: ReplicaStore = null
var _state: State = State.DISCONNECTED
var _error := ""
var _error_detail := ""
var _frames_applied := 0


## Whether a zone was named, i.e. whether the client should connect at all.
static func is_enabled() -> bool:
	return not zone_url().is_empty()


## The configured zone URL, or "" when the feature is off.
static func zone_url() -> String:
	return OS.get_environment(ZONE_URL_ENV).strip_edges()


## `transport` defaults to a real `WebSocketPeer`; tests inject a fake with the
## same six methods. A transport that does not satisfy the contract puts the
## connection straight into `FAILED` — loudly, at the point of the mistake.
func _init(transport: Object = null) -> void:
	_transport = transport if transport != null else WebSocketPeer.new()
	_store = ReplicaStore.new()
	var missing := _missing_transport_methods(_transport)
	if not missing.is_empty():
		_enter_failed(ERR_TRANSPORT, "transport is missing %s" % ", ".join(missing))


## Open a connection to `url`. Returns false and records an error class when
## refused. Legal from DISCONNECTED, CLOSED and FAILED; a reconnect discards
## the previous table, because the new stream carries its own base snapshot.
func connect_to(url: String) -> bool:
	if _state == State.FAILED and _error == ERR_TRANSPORT:
		return false  # an unusable transport cannot be retried into working
	var target := url.strip_edges()
	if target.is_empty():
		_enter_failed(ERR_URL, "no zone url")
		return false
	if _state == State.CONNECTING or _state == State.LIVE:
		_enter_failed(ERR_STATE, "already connected — close() first")
		return false

	_store = ReplicaStore.new()
	_error = ""
	_error_detail = ""
	_frames_applied = 0

	var result: int = _transport.call("connect_to_url", target)
	if result != OK:
		_enter_failed(ERR_OPEN, "transport refused %s (error %d)" % [target, result])
		return false
	_state = State.CONNECTING
	return true


## Advance the connection: pump the transport, track its ready state, and fold
## every frame it has delivered. Safe and cheap to call every frame; a no-op
## unless the connection is CONNECTING or LIVE.
func poll() -> void:
	if _state != State.CONNECTING and _state != State.LIVE:
		return
	_transport.call("poll")
	var ready: int = _transport.call("get_ready_state")
	match ready:
		WebSocketPeer.STATE_CONNECTING:
			_state = State.CONNECTING
		WebSocketPeer.STATE_OPEN:
			_state = State.LIVE
			_drain()
		WebSocketPeer.STATE_CLOSING:
			# Draining here would fold frames sent after the peer began
			# closing; the close handshake is not a delivery guarantee.
			pass
		_:
			_state = State.CLOSED


## Close the connection. Idempotent, and never turns a FAILED connection into
## a clean CLOSED one — the failure is what the caller needs to see.
func close() -> void:
	if _state == State.FAILED:
		return
	if _state == State.CONNECTING or _state == State.LIVE:
		_transport.call("close")
	_state = State.CLOSED


## Current lifecycle state.
func state() -> State:
	return _state


## Whether frames are currently being consumed.
func is_live() -> bool:
	return _state == State.LIVE


## The error class of a failure, or "" when there has been none. One of this
## class's `ERR_*`, or the `WireCodec`/`ReplicaStore` class that refused.
func error() -> String:
	return _error


## Human-readable detail for the recorded error class.
func error_detail() -> String:
	return _error_detail


## Number of frames folded into the table since the current connection began.
func frames_applied() -> int:
	return _frames_applied


## The replicated entity table. Read-only from a caller's point of view: it is
## only ever mutated by this class's fold.
func store() -> ReplicaStore:
	return _store


## Fold every frame the transport has already delivered, stopping at the first
## refusal. Draining the whole queue keeps a slow frame from accumulating
## latency across polls.
func _drain() -> void:
	while true:
		var available: int = _transport.call("get_available_packet_count")
		if available <= 0:
			return
		var bytes: PackedByteArray = _transport.call("get_packet")
		var decoded: Dictionary = WireCodec.decode(bytes)
		if decoded.get("ok") != true:
			_fail_stream(decoded, "decode")
			return
		var applied: Dictionary = _store.apply(decoded)
		if applied.get("ok") != true:
			_fail_stream(applied, "fold")
			return
		_frames_applied += 1


## Record a refusal under its own error class and close the socket. The table
## keeps whatever it held before the refused frame.
func _fail_stream(refusal: Dictionary, stage: String) -> void:
	var error_class: String = str(refusal.get("error", "unknown"))
	var detail: String = str(refusal.get("detail", ""))
	_transport.call("close")
	_enter_failed(error_class, "%s refused frame %d: %s" % [stage, _frames_applied, detail])


func _enter_failed(error_class: String, detail: String) -> void:
	_state = State.FAILED
	_error = error_class
	_error_detail = detail


func _missing_transport_methods(transport: Object) -> Array[String]:
	var missing: Array[String] = []
	for method: String in REQUIRED_TRANSPORT_METHODS:
		if not transport.has_method(method):
			missing.append(method)
	return missing
