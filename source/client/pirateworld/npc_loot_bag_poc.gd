extends Node
## Client bridge for temporary NPC loot bags.
## Uses the same interaction pattern as Death Bags but has independent server storage.

const BAG_ICON_PATH: String = "res://assets/sprites/items/icons/Icon271.png"
const PICKUP_ACTION: StringName = &"player_interact"
const PICKUP_RANGE: float = 96.0
const LOOT_ICON_SIZE: Vector2 = Vector2(44, 44)

var _bags: Dictionary[int, Node2D] = {}
var _instance_name: String = ""
var _instance_ref: InstanceClient = null
var _syncing: bool = false
var _opened_bag_id: int = 0
var _loot_window: Window = null
var _loot_window_epoch: int = 0

# One bridge per persistent Client object. This is stronger than a scene-group
# check because duplicate bridge instances can be created before either one
# becomes discoverable through the scene tree.
static var _bridges_by_client_id: Dictionary = {}


func _ready() -> void:
	if not GameMode.is_client():
		queue_free()
		return
	var client_id := Client.get_instance_id()
	var existing = _bridges_by_client_id.get(client_id)
	if existing is Node and is_instance_valid(existing) and existing != self:
		print("[NPC_LOOT_BAG_CLIENT] duplicate_bridge_rejected client_id=%d existing_id=%d self_id=%d" % [client_id, existing.get_instance_id(), get_instance_id()])
		set_process(false)
		queue_free()
		return
	_bridges_by_client_id[client_id] = self
	tree_exiting.connect(_on_tree_exiting)
	add_to_group("npc_loot_bag_client_bridge")
	print("[NPC_LOOT_BAG_CLIENT] ready client_id=%d bridge_id=%d" % [client_id, get_instance_id()])
	if not GameMode.is_client():
		queue_free()
		return
	Client.subscribe(&"pirateworld.npc_loot_bag.spawn", _on_bag_spawn)
	Client.subscribe(&"pirateworld.npc_loot_bag.remove", _on_bag_remove)
	Client.subscribe(&"pirateworld.npc_loot_bag.changed", _on_bag_changed)
	call_deferred("_refresh_instance")


func _on_tree_exiting() -> void:
	if is_instance_valid(Client):
		var client_id := Client.get_instance_id()
		if _bridges_by_client_id.get(client_id) == self:
			_bridges_by_client_id.erase(client_id)


func _process(_delta: float) -> void:
	var instance: InstanceClient = InstanceClient.current
	if instance == null or instance.instance_map == null:
		return
	# Use the InstanceClient object as the lifecycle key; its logical name
	# is not sufficient to detect instance replacement reliably.
	if _instance_ref != instance:
		_instance_ref = instance
		_instance_name = instance.name
		_clear_bags()
		_refresh_instance()
	if Input.is_action_just_pressed(PICKUP_ACTION):
		_try_pickup(instance)


func _refresh_instance() -> void:
	if _syncing:
		return
	var instance: InstanceClient = InstanceClient.current
	if instance == null or instance.instance_map == null:
		return
	_instance_name = instance.name
	_instance_ref = instance
	_syncing = true
	var result: Array = await Client.request_data_await(&"npc_loot_bag.list", {}, instance.name)
	_syncing = false
	if epoch != _loot_window_epoch or _opened_bag_id != bag_id:
		return
	if result.size() < 2 or result[1] != OK:
		return
	var payload: Dictionary = result[0]
	if not bool(payload.get("ok", false)):
		return

	# Reconcile server state instead of destroying/recreating every client node.
	var server_ids: Dictionary[int, bool] = {}
	for bag: Dictionary in payload.get("bags", []):
		var bag_id := int(bag.get("bag_id", 0))
		if bag_id <= 0:
			continue
		server_ids[bag_id] = true
		_on_bag_spawn(bag)

	for bag_id: int in _bags.keys():
		if not server_ids.has(bag_id):
			_remove_bag_node(bag_id)

func _remove_bag_node(bag_id: int) -> void:
	if _opened_bag_id == bag_id:
		_close_loot_window()
	if not _bags.has(bag_id):
		return
	var node: Node2D = _bags[bag_id]
	if is_instance_valid(node):
		node.queue_free()
	_bags.erase(bag_id)


func _on_bag_spawn(payload: Dictionary) -> void:
	var bag_id := int(payload.get("bag_id", 0))
	var instance := InstanceClient.current
	if bag_id <= 0 or instance == null or instance.instance_map == null:
		return
	if _bags.has(bag_id):
		_bags[bag_id].global_position = payload.get("position", Vector2.ZERO)
		return
	var node := Node2D.new()
	node.name = "NpcLootBag_%d" % bag_id
	node.z_index = 2
	var sprite := Sprite2D.new()
	sprite.texture = load(BAG_ICON_PATH)
	sprite.scale = Vector2(1.35, 1.35)
	node.add_child(sprite)
	var label := Label.new()
	label.text = "%s [#%d]" % [str(payload.get("owner_name", "Enemigo")), bag_id]
	label.position = Vector2(-45, 18)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	node.add_child(label)
	node.global_position = payload.get("position", Vector2.ZERO)
	instance.instance_map.add_child(node)
	_bags[bag_id] = node
	print("[NPC_LOOT_BAG_CLIENT] node_created bag_id=%d position=%s map=%s" % [bag_id, str(node.global_position), str(instance.instance_map.name)])


func _on_bag_remove(payload: Dictionary) -> void:
	var bag_id := int(payload.get("bag_id", 0))
	_remove_bag_node(bag_id)
	if _opened_bag_id == bag_id:
		_close_loot_window()


func _on_bag_changed(payload: Dictionary) -> void:
	var bag_id := int(payload.get("bag_id", 0))
	if _opened_bag_id <= 0 or bag_id != _opened_bag_id:
		return
	var epoch := _loot_window_epoch
	var instance := InstanceClient.current
	if instance == null:
		return
	var result: Array = await Client.request_data_await(
		&"npc_loot_bag.open", {"bag_id": bag_id}, instance.name
	)
	if epoch != _loot_window_epoch or _opened_bag_id != bag_id:
		return
	if result.size() >= 2 and result[1] == OK and bool(result[0].get("ok", false)):
		_open_loot_window(instance, result[0])
	else:
		_close_loot_window()


func _try_pickup(instance: InstanceClient) -> void:
	if instance.local_player == null:
		return
	var nearest_id := 0
	var nearest_distance := PICKUP_RANGE + 0.01
	for bag_id: int in _bags:
		var bag: Node2D = _bags[bag_id]
		if not is_instance_valid(bag):
			continue
		var distance := instance.local_player.global_position.distance_to(bag.global_position)
		if distance <= nearest_distance:
			nearest_distance = distance
			nearest_id = bag_id
	if nearest_id <= 0:
		return

	var result: Array = await Client.request_data_await(
		&"npc_loot_bag.open", {"bag_id": nearest_id}, instance.name
	)
	if result.size() < 2 or result[1] != OK:
		return
	var payload: Dictionary = result[0]
	if not bool(payload.get("ok", false)):
		match str(payload.get("reason", "")):
			"in_use": Toaster.toast("La mochila está siendo saqueada.")
			"too_far": Toaster.toast("La mochila está demasiado lejos.")
			_: Toaster.toast("No se pudo abrir la mochila.")
		return
	_open_loot_window(instance, payload)


func _open_loot_window(instance: InstanceClient, payload: Dictionary) -> void:
	_close_loot_window()
	_opened_bag_id = int(payload.get("bag_id", 0))
	_loot_window_epoch += 1

	var window := Window.new()
	_loot_window = window
	window.name = "NpcLootBagWindow"
	window.title = "Botín de %s" % str(payload.get("owner_name", "Enemigo"))
	window.size = Vector2i(360, 420)
	window.position = Vector2i(120, 120)
	window.close_requested.connect(_close_loot_window)

	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 8)
	window.add_child(root)

	var title := Label.new()
	title.text = window.title
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(title)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, 300)
	root.add_child(scroll)
	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(list)

	var contents: Dictionary = payload.get("contents", {})
	if contents.is_empty():
		var empty := Label.new()
		empty.text = "No queda botín."
		empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		list.add_child(empty)

	for slot_uid in contents:
		var slot = contents[slot_uid]
		if slot is Dictionary:
			list.add_child(_make_loot_row(slot_uid, slot, func(uid: String) -> void:
				_loot_slot(instance.name, _opened_bag_id, uid)
			))

	var actions := HBoxContainer.new()
	root.add_child(actions)
	var loot_all := Button.new()
	loot_all.text = "LOOT ALL"
	loot_all.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	loot_all.pressed.connect(_loot_all.bind(instance.name, _opened_bag_id))
	actions.add_child(loot_all)
	var close := Button.new()
	close.text = "Cerrar"
	close.pressed.connect(_close_loot_window)
	actions.add_child(close)

	add_child(window)
	window.popup_centered()


func _make_loot_row(slot_uid: Variant, slot: Dictionary, take_callback: Callable) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.custom_minimum_size = Vector2(0, 60)

	var icon_panel := PanelContainer.new()
	icon_panel.custom_minimum_size = LOOT_ICON_SIZE
	var icon := TextureRect.new()
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var item_id := int(slot.get("id", 0))
	var item: Item = ContentRegistryHub.load_by_id(&"items", item_id) as Item
	if item != null:
		icon.texture = item.item_icon
	icon_panel.add_child(icon)
	row.add_child(icon_panel)

	var details := VBoxContainer.new()
	details.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var name := Label.new()
	name.text = str(item.item_name) if item != null else "Objeto #%d" % item_id
	details.add_child(name)
	var amount := Label.new()
	amount.text = "Cantidad: %d" % int(slot.get("a", 0))
	details.add_child(amount)
	row.add_child(details)

	var take := Button.new()
	take.text = "Tomar"
	take.custom_minimum_size = Vector2(76, 44)
	take.pressed.connect(func(): take_callback.call(str(slot_uid)))
	row.add_child(take)
	return row


func _loot_slot(instance_name: String, bag_id: int, slot_uid: String) -> void:
	var epoch := _loot_window_epoch
	var result: Array = await Client.request_data_await(
		&"npc_loot_bag.loot",
		{"bag_id": bag_id, "slot_uid": slot_uid},
		instance_name
	)
	if epoch != _loot_window_epoch or _opened_bag_id != bag_id:
		return
	if result.size() < 2 or result[1] != OK:
		return
	var payload: Dictionary = result[0]
	if not bool(payload.get("ok", false)):
		match str(payload.get("reason", "")):
			"inventory_full": Toaster.toast("No tienes espacio en el inventario.")
			"not_open", "not_found", "slot_gone": _close_loot_window()
		return
	if bool(payload.get("emptied", false)):
		_close_loot_window()
		Toaster.toast("Botín recogido.")
		return
	_close_loot_window()
	var refreshed: Array = await Client.request_data_await(
		&"npc_loot_bag.open", {"bag_id": bag_id}, instance_name
	)
	if epoch != _loot_window_epoch or _opened_bag_id != bag_id:
		return
	if refreshed.size() >= 2 and refreshed[1] == OK and bool(refreshed[0].get("ok", false)):
		_open_loot_window(InstanceClient.current, refreshed[0])


func _loot_all(instance_name: String, bag_id: int) -> void:
	var epoch := _loot_window_epoch
	var result: Array = await Client.request_data_await(
		&"npc_loot_bag.loot_all", {"bag_id": bag_id}, instance_name
	)
	if epoch != _loot_window_epoch or _opened_bag_id != bag_id:
		return
	if result.size() < 2 or result[1] != OK:
		return
	var payload: Dictionary = result[0]
	if bool(payload.get("ok", false)):
		if bool(payload.get("emptied", false)):
			_close_loot_window()
			Toaster.toast("Botín recogido.")
		else:
			_close_loot_window()
			var refreshed: Array = await Client.request_data_await(
				&"npc_loot_bag.open", {"bag_id": bag_id}, instance_name
			)
			if epoch != _loot_window_epoch or _opened_bag_id != bag_id:
				return
			if refreshed.size() >= 2 and refreshed[1] == OK and bool(refreshed[0].get("ok", false)):
				_open_loot_window(InstanceClient.current, refreshed[0])
			Toaster.toast("Se recuperó lo que cabía en el inventario.")
	elif str(payload.get("reason", "")) == "inventory_full":
		Toaster.toast("No tienes espacio en el inventario.")
	elif str(payload.get("reason", "")) in ["not_open", "not_found"]:
		_close_loot_window()


func _close_loot_window() -> void:
	var bag_id := _opened_bag_id
	_opened_bag_id = 0
	_loot_window_epoch += 1
	var window := _loot_window
	_loot_window = null
	if is_instance_valid(window):
		window.queue_free()
	if bag_id > 0:
		var instance := InstanceClient.current
		if instance != null:
			Client.request_data_await(&"npc_loot_bag.close", {"bag_id": bag_id}, instance.name)


func _clear_bags() -> void:
	for bag_id: int in _bags:
		var node: Node2D = _bags[bag_id]
		if is_instance_valid(node):
			node.queue_free()
	_bags.clear()
