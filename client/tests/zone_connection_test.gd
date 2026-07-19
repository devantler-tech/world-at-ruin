extends Node
## Zone connection: the live replication pump (issue #244).
##
## `ZoneConnection` adds no wire or fold semantics — those are pinned by the
## cross-tier goldens that `wire_codec_test` and `replica_store_test` already
## assert. What is unproven, and what this suite pins, is the PUMP: when
## frames are consumed, and what happens when one is refused.
##
## The happy path is proven against the SAME committed stream golden the store
## suite folds by hand (`res://tests/data/wire_goldens.json`), delivered
## through the transport seam instead. If the connection is a faithful pump,
## it must land on exactly the server's authoritative end state — so this is a
## real end-to-end proof of the seam, not a restatement of the fold.
##
## Every refusal law gets a negative control isolated to ONE law, asserting
## the EXACT error class (a control failing for the wrong reason proves
## nothing):
##   * transport  — a transport missing a contract method, refused at
##                  construction rather than deep inside poll()
##   * url        — an empty/blank zone url
##   * scheme     — a plaintext ws:// url, which the transport ADR forbids
##   * token      — no allocation token, which zone admission answers 401 to
##   * state      — connect_to while the transport is busy: already live, or
##                  still finishing a close handshake
##   * open       — the transport refusing to open the url
##   * handshake  — the peer closing before the socket ever opened, which is
##                  what a 401 from admission looks like from here
##   * <decoder>  — a corrupt frame, surfaced under WireCodec's OWN class
##   * <store>    — a delta before any base, under ReplicaStore's OWN class
##
## Three laws beyond the classes themselves:
##   * FAIL-CLOSED — after a refused fold the table is byte-identical to what
##     it held before, and the drain STOPS: a valid frame queued behind a bad
##     one must NOT be applied (proven by queueing exactly that).
##   * TERMINAL IS NOT WEDGED — a failed connection can reconnect, and does so
##     onto a FRESH store (a stale table must never survive a desync) — but
##     only once the socket it hung up has finished its close handshake.
##   * ADMISSION — the bearer header the zone hub demands is actually present,
##     and its absence is refused here rather than as a 401 later.
##   * DEFAULT-OFF — with WAR_ZONE_URL unset the feature reports disabled, and
##     with it set it reports enabled with that url (both states, per the
##     feature-flag-first rule).
##
## Pure logic and a res:// read only — no socket, no server, no scene, no
## save — so it is deterministic in CI and safe to run locally.
##
## Run: godot --headless --path client res://tests/zone_connection_test.tscn

const FIXTURE := "res://tests/data/wire_goldens.json"
const URL := "wss://zone.example/replicate"
## A stand-in allocation token. Not a credential — no server verifies it; it
## exists so the header the real hub demands can be asserted.
const TOKEN := "test-allocation-token"

var _failed := false


## A scripted stand-in for WebSocketPeer implementing exactly the methods
## ZoneConnection uses. Ready-states and packets are queued by the test, so
## every ordering below is chosen rather than raced.
##
## `close()` models the REAL close handshake instead of snapping straight to
## STATE_CLOSED: a `WebSocketPeer` enters STATE_CLOSING and only reaches
## STATE_CLOSED under further polls. A fake that closed instantly could not
## tell a connection that keeps polling a closing socket apart from one that
## abandons the handshake and reconnects onto a transport still in use — so it
## would let exactly that bug through green.
class FakeTransport:
	extends RefCounted

	var ready_state: int = WebSocketPeer.STATE_CONNECTING
	var packets: Array[PackedByteArray] = []
	var open_result: int = OK
	var connected_url := ""
	var handshake_headers: PackedStringArray = PackedStringArray()
	var polls := 0
	var closes := 0
	## Polls the close handshake takes to complete, as a real peer's does.
	var closing_polls := 1
	## Whether close() finishes instantly instead of handshaking — what a real
	## peer does when the connection is already gone (the server hung up, or we
	## closed while still CONNECTING and no socket was ever open).
	var closes_instantly := false

	var _closing_left := 0

	func connect_to_url(url: String) -> int:
		connected_url = url
		return open_result

	func poll() -> void:
		polls += 1
		if ready_state == WebSocketPeer.STATE_CLOSING:
			_closing_left -= 1
			if _closing_left <= 0:
				ready_state = WebSocketPeer.STATE_CLOSED

	func get_ready_state() -> int:
		return ready_state

	func get_available_packet_count() -> int:
		return packets.size()

	func get_packet() -> PackedByteArray:
		return packets.pop_front()

	func set_handshake_headers(headers: PackedStringArray) -> void:
		handshake_headers = headers

	func close() -> void:
		closes += 1
		if closes_instantly:
			ready_state = WebSocketPeer.STATE_CLOSED
			return
		ready_state = WebSocketPeer.STATE_CLOSING
		_closing_left = closing_polls


## A transport missing get_packet — every other method present, so the control
## is isolated to the contract check and cannot fail for another reason.
class IncompleteTransport:
	extends RefCounted

	func connect_to_url(_url: String) -> int:
		return OK

	func poll() -> void:
		pass

	func get_ready_state() -> int:
		return WebSocketPeer.STATE_OPEN

	func get_available_packet_count() -> int:
		return 0

	func set_handshake_headers(_headers: PackedStringArray) -> void:
		pass

	func close() -> void:
		pass


func _ready() -> void:
	# Admission is mandatory, so every connect below needs a token; the token
	# law itself clears it deliberately and restores it.
	var original_token := OS.get_environment(ZoneConnection.ZONE_TOKEN_ENV)
	OS.set_environment(ZoneConnection.ZONE_TOKEN_ENV, TOKEN)

	var stream := _load_stream()
	if _failed:
		return
	if not _check_cross_tier_pump(stream):
		return
	if not _check_connect_lifecycle(stream):
		return
	if not _check_transport_contract_law():
		return
	if not _check_shipped_transport_satisfies_the_contract():
		return
	if not _check_url_and_state_laws():
		return
	if not _check_scheme_law():
		return
	if not _check_admission_token_law():
		return
	if not _check_failed_handshake_is_not_a_clean_close():
		return
	if not _check_open_refusal_law():
		return
	if not _check_decode_refusal_law():
		return
	if not _check_fold_refusal_is_fail_closed(stream):
		return
	if not _check_close_completes_its_handshake():
		return
	if not _check_close_of_an_already_gone_peer_completes():
		return
	if not _check_reconnect_is_not_wedged(stream):
		return
	if not _check_default_off():
		return

	OS.set_environment(ZoneConnection.ZONE_TOKEN_ENV, original_token)
	print("TEST PASS — zone connection pumps the cross-tier stream golden to the server's authoritative end state, presents its admission token over TLS, completes its close handshake before reconnecting, and every stream refusal is terminal, classified and fail-closed")
	get_tree().quit(0)


func _fail(message: String) -> void:
	_failed = true
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)


func _load_stream() -> Dictionary:
	var text := FileAccess.get_file_as_string(FIXTURE)
	if text.is_empty():
		_fail("fixture %s is missing or empty — the pump has no stream to carry" % FIXTURE)
		return {}
	var parsed: Variant = JSON.parse_string(text)
	if parsed is not Dictionary:
		_fail("fixture %s did not parse as a JSON object" % FIXTURE)
		return {}
	var root: Dictionary = parsed
	if root.get("stream") is not Dictionary:
		_fail("fixture has no 'stream' section")
		return {}
	var stream: Dictionary = root["stream"]
	if stream.get("frames") is not Array or (stream["frames"] as Array).is_empty():
		_fail("fixture stream has no frames")
		return {}
	if stream.get("end_state") is not Dictionary:
		_fail("fixture stream has no end_state")
		return {}
	return stream


func _frame_bytes(stream: Dictionary) -> Array[PackedByteArray]:
	var out: Array[PackedByteArray] = []
	for frame: Variant in (stream["frames"] as Array):
		out.append(((frame as Dictionary)["hex"] as String).hex_decode())
	return out


## Deliver the whole committed stream through the seam and require the SAME
## authoritative end state the store suite folds to by hand. This is what
## proves the pump faithful rather than merely quiet.
func _check_cross_tier_pump(stream: Dictionary) -> bool:
	var frames := _frame_bytes(stream)
	var transport := FakeTransport.new()
	var conn := ZoneConnection.new(transport)
	if not conn.connect_to(URL):
		_fail("connect_to refused a good url: %s / %s" % [conn.error(), conn.error_detail()])
		return false
	if transport.connected_url != URL:
		_fail("transport received url %s, expected %s" % [transport.connected_url, URL])
		return false

	transport.ready_state = WebSocketPeer.STATE_OPEN
	transport.packets = frames.duplicate()
	conn.poll()

	if conn.error() != "":
		_fail("pumping the committed stream failed with %s: %s — the server-emitted stream must always fold" % [conn.error(), conn.error_detail()])
		return false
	if not conn.is_live():
		_fail("connection is not live after an open transport delivered the stream (state %d)" % conn.state())
		return false
	if conn.frames_applied() != frames.size():
		_fail("applied %d frames, stream has %d — the drain must consume the whole queue" % [conn.frames_applied(), frames.size()])
		return false

	var end_state: Dictionary = stream["end_state"]
	var store: ReplicaStore = conn.store()
	var want_tick := int(end_state["tick"] as float)
	var want_observer := int(end_state["observer"] as float)
	if store.tick() != want_tick:
		_fail("pumped tick = %d, fixture end_state says %d" % [store.tick(), want_tick])
		return false
	if store.observer() != want_observer:
		_fail("pumped observer = %d, fixture end_state says %d" % [store.observer(), want_observer])
		return false
	if not store.has_base():
		_fail("store has no base after folding the whole stream")
		return false
	if store.count() == 0:
		_fail("store is empty after folding the whole stream — the pump delivered nothing")
		return false
	return true


## The handshake and partial delivery: frames arriving across several polls
## must fold exactly as one batch did, and nothing may be consumed before the
## socket is open.
func _check_connect_lifecycle(stream: Dictionary) -> bool:
	var frames := _frame_bytes(stream)
	if frames.size() < 2:
		_fail("fixture stream has %d frame(s) — cannot pin partial delivery" % frames.size())
		return false
	var transport := FakeTransport.new()
	var conn := ZoneConnection.new(transport)
	conn.connect_to(URL)

	# Still handshaking, with a frame already queued: nothing may be folded.
	transport.packets = [frames[0]]
	conn.poll()
	if conn.state() != ZoneConnection.State.CONNECTING:
		_fail("state is %d while the transport is still CONNECTING" % conn.state())
		return false
	if conn.frames_applied() != 0:
		_fail("folded %d frame(s) before the socket was open" % conn.frames_applied())
		return false

	# Open, delivering one frame per poll.
	transport.ready_state = WebSocketPeer.STATE_OPEN
	var applied_ticks: Array[int] = []
	for i in frames.size():
		transport.packets = [frames[i]]
		conn.poll()
		if conn.error() != "":
			_fail("frame %d refused during incremental delivery: %s" % [i, conn.error()])
			return false
		applied_ticks.append(conn.store().tick())
	if conn.frames_applied() != frames.size():
		_fail("incremental delivery folded %d of %d frames" % [conn.frames_applied(), frames.size()])
		return false

	var end_state: Dictionary = stream["end_state"]
	if conn.store().tick() != int(end_state["tick"] as float):
		_fail("incremental delivery landed on tick %d, batch delivery on %d — the pump is delivery-order sensitive" % [conn.store().tick(), int(end_state["tick"] as float)])
		return false

	# A poll with nothing queued must be a no-op, not a state change.
	var before := conn.frames_applied()
	conn.poll()
	if conn.frames_applied() != before or conn.error() != "":
		_fail("an empty poll changed state (frames %d -> %d, error %s)" % [before, conn.frames_applied(), conn.error()])
		return false

	# Peer closes: the connection follows it to CLOSED, not to FAILED.
	transport.ready_state = WebSocketPeer.STATE_CLOSED
	conn.poll()
	if conn.state() != ZoneConnection.State.CLOSED:
		_fail("state is %d after the peer closed, expected CLOSED" % conn.state())
		return false
	if conn.error() != "":
		_fail("a clean peer close recorded error %s — a close is not a failure" % conn.error())
		return false
	return true


func _check_transport_contract_law() -> bool:
	var conn := ZoneConnection.new(IncompleteTransport.new())
	if conn.state() != ZoneConnection.State.FAILED:
		_fail("a transport missing get_packet was accepted (state %d)" % conn.state())
		return false
	if conn.error() != ZoneConnection.ERR_TRANSPORT:
		_fail("incomplete transport reported %s, expected %s" % [conn.error(), ZoneConnection.ERR_TRANSPORT])
		return false
	if not conn.error_detail().contains("get_packet"):
		_fail("contract failure did not name the missing method: %s" % conn.error_detail())
		return false
	if conn.connect_to(URL):
		_fail("an unusable transport was allowed to connect")
		return false
	if conn.error() != ZoneConnection.ERR_TRANSPORT:
		_fail("retrying an unusable transport relabelled the error as %s" % conn.error())
		return false
	return true


## The control every other test here cannot give: each one injects a FAKE, so
## the SHIPPED transport is otherwise never checked against the contract list.
## If `WebSocketPeer` ever loses or renames one of those six methods, the
## default constructor would fail on the player's machine while every fake
## kept passing. Constructing a peer opens nothing, so this is headless-safe.
##
## RED-proven by adding to the contract a method the fake HAS and the real peer
## does not: every fake-driven check above stays green and only this one fails.
func _check_shipped_transport_satisfies_the_contract() -> bool:
	var conn := ZoneConnection.new()
	if conn.state() == ZoneConnection.State.FAILED:
		_fail("the real WebSocketPeer does not satisfy the transport contract: %s — every fake-driven test above is testing a seam the shipped client cannot use" % conn.error_detail())
		return false
	var peer := WebSocketPeer.new()
	for method: String in ZoneConnection.REQUIRED_TRANSPORT_METHODS:
		if not peer.has_method(method):
			_fail("WebSocketPeer has no %s — the contract list has drifted from the engine" % method)
			return false
	return true


func _check_url_and_state_laws() -> bool:
	var blank := ZoneConnection.new(FakeTransport.new())
	if blank.connect_to("   "):
		_fail("a blank url was accepted")
		return false
	if blank.error() != ZoneConnection.ERR_URL:
		_fail("blank url reported %s, expected %s" % [blank.error(), ZoneConnection.ERR_URL])
		return false

	var transport := FakeTransport.new()
	var conn := ZoneConnection.new(transport)
	conn.connect_to(URL)
	transport.ready_state = WebSocketPeer.STATE_OPEN
	conn.poll()
	if not conn.is_live():
		_fail("connection did not go live before the double-connect control")
		return false
	if conn.connect_to(URL):
		_fail("connect_to succeeded while already live")
		return false
	if conn.error() != ZoneConnection.ERR_STATE:
		_fail("double connect reported %s, expected %s" % [conn.error(), ZoneConnection.ERR_STATE])
		return false
	# Refusing the CALL is not enough: the socket that was live is now
	# unreferenced, and an unreferenced open socket leaves the zone server
	# holding an observer and buffering for a client that will never read
	# again. Refusing must also hang up.
	if transport.closes != 1:
		_fail("a refused duplicate connect left the live socket open (closes=%d) — the zone server would hold its observer until timeout" % transport.closes)
		return false
	return true


## Only `wss://` is a legal zone url. A plaintext endpoint would carry the
## admission token and the whole authoritative stream in clear.
func _check_scheme_law() -> bool:
	var transport := FakeTransport.new()
	var conn := ZoneConnection.new(transport)
	if conn.connect_to("ws://zone.example/replicate"):
		_fail("a plaintext ws:// zone url was accepted — the transport ADR settles TLS")
		return false
	if conn.error() != ZoneConnection.ERR_SCHEME:
		_fail("plaintext url reported %s, expected %s" % [conn.error(), ZoneConnection.ERR_SCHEME])
		return false
	if transport.connected_url != "":
		_fail("the transport was asked to open a plaintext url (%s)" % transport.connected_url)
		return false
	# The refusal must not leak the url it rejected: a zone url may carry
	# userinfo, and error details are printed.
	if conn.error_detail().contains("zone.example"):
		_fail("the scheme refusal echoed the url into its detail: %s" % conn.error_detail())
		return false
	return true


## `server/zonesock/hub.go` refuses any upgrade without a bearer token, so a
## connection without one can never reach LIVE. Refuse it here, at the point
## of the mistake, and present it as a handshake header when it is there.
func _check_admission_token_law() -> bool:
	var original := OS.get_environment(ZoneConnection.ZONE_TOKEN_ENV)

	OS.set_environment(ZoneConnection.ZONE_TOKEN_ENV, "")
	var bare := FakeTransport.new()
	var without := ZoneConnection.new(bare)
	if without.connect_to(URL):
		_fail("connect_to succeeded with no allocation token — zone admission answers 401, so this can never reach LIVE")
		OS.set_environment(ZoneConnection.ZONE_TOKEN_ENV, original)
		return false
	if without.error() != ZoneConnection.ERR_TOKEN:
		_fail("missing token reported %s, expected %s" % [without.error(), ZoneConnection.ERR_TOKEN])
		OS.set_environment(ZoneConnection.ZONE_TOKEN_ENV, original)
		return false
	if bare.connected_url != "":
		_fail("the transport was asked to open a url with no token to present")
		OS.set_environment(ZoneConnection.ZONE_TOKEN_ENV, original)
		return false

	OS.set_environment(ZoneConnection.ZONE_TOKEN_ENV, TOKEN)
	var transport := FakeTransport.new()
	var conn := ZoneConnection.new(transport)
	if not conn.connect_to(URL):
		_fail("connect_to refused a good url with a token present: %s" % conn.error())
		OS.set_environment(ZoneConnection.ZONE_TOKEN_ENV, original)
		return false

	# The exact header the hub parses — `bearerToken(r.Header.Get(...))`.
	var want := "Authorization: Bearer %s" % TOKEN
	var got := Array(transport.handshake_headers)
	if not got.has(want):
		_fail("handshake headers %s carry no %s — the hub refuses the upgrade with 401" % [str(got), want])
		OS.set_environment(ZoneConnection.ZONE_TOKEN_ENV, original)
		return false

	OS.set_environment(ZoneConnection.ZONE_TOKEN_ENV, original)
	return true


## A handshake can fail LONG after `connect_to()` returned true: admission
## answers 401 to a stale token, or TLS/DNS never completes. The peer then goes
## straight to STATE_CLOSED without ever opening. That must NOT read as a clean
## shutdown — the opt-in would sit silently offline, and an operator could not
## tell a refused admission from a deliberate stop.
##
## The isolating pair for this law is the clean close already asserted in
## `_check_connect_lifecycle`: the SAME transport state (STATE_CLOSED) must
## produce CLOSED-with-no-error from LIVE, and FAILED here from CONNECTING. A
## test for either alone would pass a wrapper that ignored the distinction.
func _check_failed_handshake_is_not_a_clean_close() -> bool:
	var transport := FakeTransport.new()
	var conn := ZoneConnection.new(transport)
	if not conn.connect_to(URL):
		_fail("connect_to refused a good url before the handshake control: %s" % conn.error())
		return false

	# Never opened: the peer closes while the handshake is still in flight.
	transport.ready_state = WebSocketPeer.STATE_CLOSED
	conn.poll()

	if conn.state() != ZoneConnection.State.FAILED:
		_fail("a handshake that closed before opening left state %d, expected FAILED — a refused admission would look like a clean shutdown" % conn.state())
		return false
	if conn.error() != ZoneConnection.ERR_HANDSHAKE:
		_fail("failed handshake reported %s, expected %s" % [conn.error(), ZoneConnection.ERR_HANDSHAKE])
		return false
	if conn.frames_applied() != 0:
		_fail("a connection that never opened folded %d frame(s)" % conn.frames_applied())
		return false
	return true


func _check_open_refusal_law() -> bool:
	var transport := FakeTransport.new()
	transport.open_result = ERR_CANT_CONNECT
	var conn := ZoneConnection.new(transport)
	if conn.connect_to(URL):
		_fail("connect_to reported success while the transport refused the url")
		return false
	if conn.error() != ZoneConnection.ERR_OPEN:
		_fail("open refusal reported %s, expected %s" % [conn.error(), ZoneConnection.ERR_OPEN])
		return false
	if conn.state() != ZoneConnection.State.FAILED:
		_fail("state is %d after an open refusal, expected FAILED" % conn.state())
		return false
	return true


## A corrupt frame must surface under the DECODER's own error class, not a
## class invented here — the caller needs to know what actually diverged.
func _check_decode_refusal_law() -> bool:
	var transport := FakeTransport.new()
	var conn := ZoneConnection.new(transport)
	conn.connect_to(URL)
	transport.ready_state = WebSocketPeer.STATE_OPEN
	transport.packets = [PackedByteArray([0xFF, 0xFF, 0xFF])]
	conn.poll()

	if conn.state() != ZoneConnection.State.FAILED:
		_fail("state is %d after a corrupt frame, expected FAILED" % conn.state())
		return false
	if conn.error() != WireCodec.ERR_VERSION:
		_fail("corrupt frame reported %s, expected the decoder's own %s" % [conn.error(), WireCodec.ERR_VERSION])
		return false
	if transport.closes != 1:
		_fail("socket was closed %d time(s) after a refusal, expected exactly 1" % transport.closes)
		return false
	return true


## The fail-closed law, with the strongest available control: a VALID frame is
## queued behind the bad one. If the drain kept going, the table would move —
## so this pins both atomicity and the stop.
func _check_fold_refusal_is_fail_closed(stream: Dictionary) -> bool:
	var frames := _frame_bytes(stream)
	var transport := FakeTransport.new()
	var conn := ZoneConnection.new(transport)
	conn.connect_to(URL)
	transport.ready_state = WebSocketPeer.STATE_OPEN

	# A delta before any base snapshot: refused by the STORE, not the decoder.
	var delta_first := PackedByteArray()
	for frame: PackedByteArray in frames:
		var decoded := WireCodec.decode(frame)
		if decoded.get("ok") == true and decoded["kind"] == WireCodec.KIND_SNAPSHOT_DELTA:
			delta_first = frame
			break
	if delta_first.is_empty():
		_fail("fixture stream carries no delta frame — cannot control the no_base law")
		return false

	transport.packets = [delta_first, frames[0]]
	conn.poll()

	if conn.error() != ReplicaStore.ERR_NO_BASE:
		_fail("a delta before any base reported %s, expected the store's own %s" % [conn.error(), ReplicaStore.ERR_NO_BASE])
		return false
	if conn.frames_applied() != 0:
		_fail("folded %d frame(s) despite the first being refused" % conn.frames_applied())
		return false
	if conn.store().has_base() or conn.store().count() != 0:
		_fail("the refused fold mutated the table (base=%s count=%d)" % [conn.store().has_base(), conn.store().count()])
		return false
	if conn.state() != ZoneConnection.State.FAILED:
		_fail("state is %d after a refused fold, expected FAILED" % conn.state())
		return false
	return true


## Closing is a HANDSHAKE, not an instant. `WebSocketPeer.close()` leaves the
## peer in STATE_CLOSING, and only further polls carry it to STATE_CLOSED — so
## a connection that declares itself CLOSED and stops polling abandons the
## socket mid-hangup, and a reconnect would then call connect_to_url on a
## transport still in use.
func _check_close_completes_its_handshake() -> bool:
	var transport := FakeTransport.new()
	transport.closing_polls = 2  # >1, so a single courtesy poll cannot pass this
	var conn := ZoneConnection.new(transport)
	conn.connect_to(URL)
	transport.ready_state = WebSocketPeer.STATE_OPEN
	conn.poll()
	if not conn.is_live():
		_fail("connection did not go live before the close-handshake control")
		return false

	conn.close()
	if conn.state() != ZoneConnection.State.CLOSING:
		_fail("state is %d immediately after close(), expected CLOSING — the peer's handshake has not finished" % conn.state())
		return false

	# A reconnect now would reuse a transport that is still hanging up.
	if conn.connect_to(URL):
		_fail("reconnect was allowed while the close handshake was still in flight")
		return false
	if conn.error() != ZoneConnection.ERR_STATE:
		_fail("reconnect during close reported %s, expected %s" % [conn.error(), ZoneConnection.ERR_STATE])
		return false

	# Only polling advances it, and it takes as many polls as the peer wants.
	var polls_before := transport.polls
	conn.poll()
	if transport.polls == polls_before:
		_fail("poll() did not pump a closing transport — its handshake can never complete")
		return false
	if conn.state() == ZoneConnection.State.CLOSED:
		_fail("state reached CLOSED after one poll, but the peer needed two — the wrapper is not tracking the peer's real ready state")
		return false
	conn.poll()
	if conn.state() != ZoneConnection.State.CLOSED:
		_fail("state is %d after the peer finished closing, expected CLOSED" % conn.state())
		return false

	# And a closed socket is free again.
	transport.ready_state = WebSocketPeer.STATE_CONNECTING
	if not conn.connect_to(URL):
		_fail("reconnect after a COMPLETED close was refused (%s: %s)" % [conn.error(), conn.error_detail()])
		return false
	return true


## The OTHER close: a peer whose connection is already gone reports CLOSED the
## moment it is asked to close, so there is no handshake to wait for. `CLOSING`
## has to mean "still hanging up" — if the wrapper assumes a handshake that
## never happens, nothing polls it back out (poll() only pumps a transport it
## believes is closing) and the connection reports CLOSING forever. A caller
## following this class's own advice — "poll() until CLOSED, then reconnect" —
## would spin without end.
func _check_close_of_an_already_gone_peer_completes() -> bool:
	var transport := FakeTransport.new()
	transport.closes_instantly = true
	var conn := ZoneConnection.new(transport)
	conn.connect_to(URL)
	transport.ready_state = WebSocketPeer.STATE_OPEN
	conn.poll()
	if not conn.is_live():
		_fail("connection did not go live before the instant-close control")
		return false

	conn.close()
	if conn.state() != ZoneConnection.State.CLOSED:
		_fail("state is %d after closing an already-gone peer, expected CLOSED — there was no handshake to wait for, so nothing will ever poll it out of CLOSING" % conn.state())
		return false

	# Polling must not undo that, and must not resurrect a closing state.
	conn.poll()
	conn.poll()
	if conn.state() != ZoneConnection.State.CLOSED:
		_fail("state drifted to %d after polling a fully closed peer, expected CLOSED" % conn.state())
		return false
	return true


## Terminal must not mean wedged: a failed connection reconnects, and onto a
## FRESH store — resuming a stale table across a desync is exactly the bug
## fail-closed exists to prevent.
func _check_reconnect_is_not_wedged(stream: Dictionary) -> bool:
	var frames := _frame_bytes(stream)
	var transport := FakeTransport.new()
	var conn := ZoneConnection.new(transport)
	conn.connect_to(URL)
	transport.ready_state = WebSocketPeer.STATE_OPEN

	# Get a real base in, then desync.
	transport.packets = [frames[0]]
	conn.poll()
	if not conn.store().has_base():
		_fail("no base after the first frame — cannot set up the reconnect control")
		return false
	var populated := conn.store().count()
	transport.packets = [PackedByteArray([0xFF, 0xFF, 0xFF])]
	conn.poll()
	if conn.state() != ZoneConnection.State.FAILED:
		_fail("connection did not fail on the corrupt frame; reconnect control is void")
		return false

	# The refusal hung the socket up, so the same close handshake has to
	# finish before the transport is free — a failure does not exempt it.
	if conn.connect_to(URL):
		_fail("reconnect was allowed while the socket closed by the refusal was still hanging up")
		return false
	conn.poll()
	if conn.state() != ZoneConnection.State.FAILED:
		_fail("completing the close handshake changed a FAILED connection to %d — the failure is what the caller needs to see" % conn.state())
		return false

	transport.ready_state = WebSocketPeer.STATE_CONNECTING
	if not conn.connect_to(URL):
		_fail("reconnect after a failure was refused (%s: %s) — terminal must not mean wedged" % [conn.error(), conn.error_detail()])
		return false
	if conn.error() != "":
		_fail("reconnect left the previous error %s in place" % conn.error())
		return false
	if conn.store().has_base() or conn.store().count() != 0:
		_fail("reconnect resumed a STALE table (base=%s count=%d, was %d) — recovery needs a new base snapshot" % [conn.store().has_base(), conn.store().count(), populated])
		return false
	if conn.frames_applied() != 0:
		_fail("reconnect carried %d applied frames over from the dead connection" % conn.frames_applied())
		return false
	return true


## Both flag states, per the feature-flag-first rule.
func _check_default_off() -> bool:
	var original := OS.get_environment(ZoneConnection.ZONE_URL_ENV)

	OS.set_environment(ZoneConnection.ZONE_URL_ENV, "")
	if ZoneConnection.is_enabled():
		_fail("feature reports enabled with %s unset" % ZoneConnection.ZONE_URL_ENV)
		return false
	if not ZoneConnection.zone_url().is_empty():
		_fail("zone_url() returned %s with the flag unset" % ZoneConnection.zone_url())
		return false

	OS.set_environment(ZoneConnection.ZONE_URL_ENV, URL)
	if not ZoneConnection.is_enabled():
		_fail("feature reports disabled with %s set" % ZoneConnection.ZONE_URL_ENV)
		return false
	if ZoneConnection.zone_url() != URL:
		_fail("zone_url() returned %s, expected %s" % [ZoneConnection.zone_url(), URL])
		return false

	OS.set_environment(ZoneConnection.ZONE_URL_ENV, original)
	return true
