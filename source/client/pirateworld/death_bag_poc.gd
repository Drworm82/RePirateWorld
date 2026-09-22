extends Node
## PirateWorld PoC-02 client bridge.
## F opens a server-authoritative Death Bag loot window.

const BAG_ICON_PATH: String = "res://assets/sprites/items/icons/Icon271.png"
const PICKUP_ACTION: StringName = &"player_interact"
const PICKUP_RANGE: float = 96.0

var _bags: Dictionary[int, Node2D] = {}
var _instance_name: String = ""
var _syncing: bool = false
var _opened_bag_id: int = 0

func _ready() -> void:
	if not GameMode.is_client():
		queue_free()
		return
	Client.subscribe(&"pirateworld.death_bag.spawn", _on_bag_spawn)
	Client.subscribe(&"pirateworld.death_bag.remove", _on_bag_remove)
	Client.subscribe(&"pirateworld.death_bag.changed", _on_bag_changed)
	Client.subscribe(&"pirateworld.death_bag.state", _on_bag_state)
	call_deferred("_refresh_instance")


func _process(_delta: float) -> void:
	var instance: InstanceClient = InstanceClient.current
	if instance == null or instance.instance_map == null:
		return
	var current_name: String = instance.name
	if current_name != _instance_name:
		_instance_name = current_name
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
	_syncing = true
	var result: Array = await Client.request_data_await(&"death_bag.list", {}, instance.name)
	_syncing = false
	if result.size() < 2 or result[1] != OK:
		return
	var payload: Dictionary = result[0]
	if not bool(payload.get("ok", false)):
		return
	_clear_bags()
	for bag: Dictionary in payload.get("bags", []):
		_on_bag_spawn(bag)


func _on_bag_spawn(payload: Dictionary) -> void:
	if payload.is_empty():
		return
	var bag_id: int = int(payload.get("bag_id", 0))
	if bag_id <= 0:
		return
	var instance: InstanceClient = InstanceClient.current
	if instance == null or instance.instance_map == null:
		return
	if _bags.has(bag_id):
		_bags[bag_id].global_position = payload.get("position", Vector2.ZERO)
		return
	var node := Node2D.new()
	node.name = "DeathBag_%d" % bag_id
	node.z_index = 2
	var sprite := Sprite2D.new()
	sprite.texture = load(BAG_ICON_PATH)
	sprite.scale = Vector2(1.5, 1.5)
	node.add_child(sprite)
	var label := Label.new()
	var owner_name := str(payload.get("owner_name", "Desconocido"))
	var state := str(payload.get("state", "floating"))
	var label_prefix := "Mochila hundida de %s" if state == "sunk" else "Mochila de %s"
	label.text = (label_prefix % owner_name) + " [#%d]" % bag_id
	label.position = Vector2(-45, 18)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	node.add_child(label)
	node.global_position = payload.get("position", Vector2.ZERO)
	node.set_meta("owner_name", owner_name)
	node.set_meta("state", state)
	instance.instance_map.add_child(node)
	_bags[bag_id] = node


func _on_bag_state(payload: Dictionary) -> void:
	var bag_id: int = int(payload.get("bag_id", 0))
	if bag_id <= 0 or not _bags.has(bag_id):
		return
	var node: Node2D = _bags[bag_id]
	if not is_instance_valid(node):
		return
	var state := str(payload.get("state", "floating"))
	var owner_name := str(node.get_meta("owner_name", "Desconocido"))
	node.set_meta("state", state)
	var label := node.get_node_or_null("Label") as Label
	if label != null:
		if state == "sunk":
			label.text = ("Mochila hundida de %s" % owner_name) + " [#%d]" % bag_id
		else:
			label.text = ("Mochila de %s" % owner_name) + " [#%d]" % bag_id
	if _opened_bag_id == bag_id:
		_close_loot_window()


func _on_bag_changed(payload: Dictionary) -> void:
	if _opened_bag_id <= 0 or int(payload.get("bag_id", 0)) != _opened_bag_id:
		return
	_close_loot_window()
	if bool(payload.get("contents", {}).is_empty()):
		return
	var instance := InstanceClient.current
	if instance == null:
		return
	var bag_node: Node2D = _bags.get(_opened_bag_id)
	if bag_node != null and str(bag_node.get_meta("state", "floating")) == "sunk":
		var sunk_refreshed: Array = await Client.request_data_await(&"death_bag.sunk_open", {"bag_id": _opened_bag_id}, instance.name)
		if sunk_refreshed.size() >= 2 and sunk_refreshed[1] == OK and bool(sunk_refreshed[0].get("ok", false)):
			_open_sunk_loot_window(instance, sunk_refreshed[0])
		return
	var refreshed: Array = await Client.request_data_await(&"death_bag.open", {"bag_id": _opened_bag_id}, instance.name)
	if refreshed.size() >= 2 and refreshed[1] == OK and bool(refreshed[0].get("ok", false)):
		_open_loot_window(instance, refreshed[0])


func _on_bag_remove(payload: Dictionary) -> void:
	var bag_id: int = int(payload.get("bag_id", 0))
	if not _bags.has(bag_id):
		return
	_bags[bag_id].queue_free()
	_bags.erase(bag_id)


func _try_pickup(instance: InstanceClient) -> void:
	if instance.local_player == null:
		return
	var nearest_id: int = 0
	var nearest_distance: float = PICKUP_RANGE + 0.01
	for bag_id: int in _bags:
		var bag: Node2D = _bags[bag_id]
		if not is_instance_valid(bag):
			continue
		var distance: float = instance.local_player.global_position.distance_to(bag.global_position)
		if distance <= nearest_distance:
			nearest_distance = distance
			nearest_id = bag_id
	if nearest_id <= 0:
		Toaster.toast("No hay una Death Bag cerca.")
		return
	var bag_node: Node2D = _bags[nearest_id]
	var bag_state := str(bag_node.get_meta("state", "floating"))
	if bag_state == "sunk":
		_open_sunk_access_window(instance, nearest_id, bag_node)
		return

	var result: Array = await Client.request_data_await(&"death_bag.open", {"bag_id": nearest_id}, instance.name)
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


func _open_sunk_access_window(instance: InstanceClient, bag_id: int, bag_node: Node2D) -> void:
	var window := Window.new()
	window.name = "DeathBagSunkAccessWindow"
	window.title = "Restos sumergidos"
	window.size = Vector2i(360, 240)
	window.close_requested.connect(func(): window.queue_free())

	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 10)
	window.add_child(root)

	var title := Label.new()
	title.text = "Mochila hundida de %s" % str(bag_node.get_meta("owner_name", "Desconocido"))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(title)

	var info := Label.new()
	info.text = "Los restos están sumergidos.\nAcceder requiere un anuncio en producción."
	info.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(info)

	var access := Button.new()
	access.text = "ACCEDER — VER ANUNCIO"
	access.custom_minimum_size = Vector2(0, 48)
	access.pressed.connect(_sunk_access.bind(instance, bag_id, window))
	root.add_child(access)

	var close := Button.new()
	close.text = "Cerrar"
	close.pressed.connect(window.queue_free)
	root.add_child(close)

	add_child(window)
	window.popup_centered()


func _sunk_access(instance: InstanceClient, bag_id: int, window: Window) -> void:
	var result: Array = await Client.request_data_await(&"death_bag.sunk_open", {"bag_id": bag_id}, instance.name)
	if result.size() < 2 or result[1] != OK:
		return
	var payload: Dictionary = result[0]
	if not bool(payload.get("ok", false)):
		match str(payload.get("reason", "")):
			"in_use": Toaster.toast("La mochila está siendo saqueada.")
			"too_far": Toaster.toast("La mochila está demasiado lejos.")
			"not_sunk": Toaster.toast("La mochila ya no está hundida.")
			_: Toaster.toast("No se pudo acceder a los restos.")
		window.queue_free()
		return
	window.queue_free()
	_open_sunk_loot_window(instance, payload)


func _open_sunk_loot_window(instance: InstanceClient, payload: Dictionary) -> void:
	_close_loot_window()
	_opened_bag_id = int(payload.get("bag_id", 0))
	var window := Window.new()
	window.name = "DeathBagLootWindow"
	window.title = "Restos de %s" % str(payload.get("owner_name", "Desconocido"))
	window.size = Vector2i(360, 420)
	window.position = Vector2i(120, 120)
	window.close_requested.connect(_close_loot_window)
	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 8)
	window.add_child(root)

	var title := Label.new()
	title.text = "Mochila hundida de %s" % str(payload.get("owner_name", "Desconocido"))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(title)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, 300)
	root.add_child(scroll)
	var list := VBoxContainer.new()
	list.name = "LootList"
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(list)

	var capacity := Label.new()
	capacity.text = "Espacio: %d / %d" % [int(payload.get("inventory_slots_used", 0)), int(payload.get("inventory_slot_capacity", 36))]
	capacity.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(capacity)

	var contents: Dictionary = payload.get("contents", {})
	if contents.is_empty():
		var empty := Label.new()
		empty.text = "No queda nada en los restos."
		empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		list.add_child(empty)

	for slot_uid in contents:
		var slot = contents[slot_uid]
		if not slot is Dictionary:
			continue
		list.add_child(_make_loot_row(slot_uid, slot, func(uid: String) -> void:
			_sunk_loot_slot(instance.name, _opened_bag_id, uid)
		))

	var actions := HBoxContainer.new()
	root.add_child(actions)
	var loot_all := Button.new()
	loot_all.text = "LOOT ALL"
	loot_all.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	loot_all.pressed.connect(_sunk_loot_all.bind(instance.name, _opened_bag_id))
	actions.add_child(loot_all)
	var close := Button.new()
	close.text = "Cerrar"
	close.pressed.connect(_close_loot_window)
	actions.add_child(close)

	add_child(window)
	window.popup_centered()


func _make_loot_row(slot_uid: Variant, slot: Dictionary, take_callback: Callable) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.custom_minimum_size = Vector2(0, 56)

	var icon_host := TextureRect.new()
	icon_host.custom_minimum_size = Vector2(48, 48)
	icon_host.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon_host.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	var item_id := int(slot.get("id", 0))
	var item: Item = ContentRegistryHub.load_by_id(&"items", item_id) as Item
	if item != null:
		icon_host.texture = item.item_icon
	row.add_child(icon_host)

	var details := VBoxContainer.new()
	details.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	details.add_theme_constant_override("separation", 0)
	var name := Label.new()
	name.text = str(item.item_name) if item != null else "Objeto #%d" % item_id
	name.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	details.add_child(name)
	var amount := Label.new()
	amount.text = "Cantidad: %d" % int(slot.get("a", 0))
	details.add_child(amount)
	row.add_child(details)

	var take := Button.new()
	take.text = "Tomar"
	take.custom_minimum_size = Vector2(72, 44)
	take.pressed.connect(func() -> void:
		take_callback.call(str(slot_uid))
	)
	row.add_child(take)
	return row


func _sunk_loot_slot(instance_name: String, bag_id: int, slot_uid: String) -> void:
	var result: Array = await Client.request_data_await(&"death_bag.sunk_loot", {"bag_id": bag_id, "slot_uid": slot_uid}, instance_name)
	if result.size() < 2 or result[1] != OK:
		return
	var payload: Dictionary = result[0]
	if not bool(payload.get("ok", false)):
		match str(payload.get("reason", "")):
			"inventory_full": Toaster.toast("No tienes espacio en el inventario.")
			_: Toaster.toast("No se pudo recuperar ese objeto.")
		return
	if bool(payload.get("contents", {}).is_empty()):
		_close_loot_window()
		return
	_close_loot_window()
	var refreshed: Array = await Client.request_data_await(&"death_bag.sunk_open", {"bag_id": bag_id}, instance_name)
	if refreshed.size() >= 2 and refreshed[1] == OK and bool(refreshed[0].get("ok", false)):
		_open_sunk_loot_window(InstanceClient.current, refreshed[0])


func _sunk_loot_all(instance_name: String, bag_id: int) -> void:
	var result: Array = await Client.request_data_await(&"death_bag.sunk_loot_all", {"bag_id": bag_id}, instance_name)
	if result.size() < 2 or result[1] != OK:
		return
	if bool(result[0].get("ok", false)):
		_close_loot_window()
		Toaster.toast("Recuperación completa.")
	else:
		match str(result[0].get("reason", "")):
			"inventory_full": Toaster.toast("No tienes espacio en el inventario.")
			_: Toaster.toast("No se pudo recuperar el contenido.")


func _open_loot_window(instance: InstanceClient, payload: Dictionary) -> void:
	_close_loot_window()
	_opened_bag_id = int(payload.get("bag_id", 0))
	var window := Window.new()
	window.name = "DeathBagLootWindow"
	window.title = "Mochila de %s" % str(payload.get("owner_name", "Desconocido"))
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
	list.name = "LootList"
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(list)

	var capacity := Label.new()
	capacity.text = "Espacio: %d / %d" % [int(payload.get("inventory_slots_used", 0)), int(payload.get("inventory_slot_capacity", 36))]
	capacity.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(capacity)

	var contents: Dictionary = payload.get("contents", {})
	for slot_uid in contents:
		var slot = contents[slot_uid]
		if not slot is Dictionary:
			continue
		list.add_child(_make_loot_row(slot_uid, slot, func(uid: String) -> void:
			_loot_slot(instance.name, _opened_bag_id, uid, window)
		))

	var actions := HBoxContainer.new()
	root.add_child(actions)
	var loot_all := Button.new()
	loot_all.text = "LOOT ALL"
	loot_all.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	loot_all.pressed.connect(_loot_all.bind(instance.name, _opened_bag_id, window))
	actions.add_child(loot_all)
	var close := Button.new()
	close.text = "Cerrar"
	close.pressed.connect(_close_loot_window)
	actions.add_child(close)

	add_child(window)
	window.popup_centered()


func _loot_slot(instance_name: String, bag_id: int, slot_uid: String, window: Window) -> void:
	var result: Array = await Client.request_data_await(&"death_bag.loot", {"bag_id": bag_id, "slot_uid": slot_uid}, instance_name)
	if result.size() < 2 or result[1] != OK:
		return
	var payload: Dictionary = result[0]
	if bool(payload.get("ok", false)):
		if bool(payload.get("contents", {}).is_empty()):
			_close_loot_window()
		else:
			_close_loot_window()
			var refreshed: Array = await Client.request_data_await(&"death_bag.open", {"bag_id": bag_id}, instance_name)
			if refreshed.size() >= 2 and refreshed[1] == OK and bool(refreshed[0].get("ok", false)):
				_open_loot_window(InstanceClient.current, refreshed[0])
	else:
		Toaster.toast("No se pudo tomar ese objeto.")


func _loot_all(instance_name: String, bag_id: int, window: Window) -> void:
	var result: Array = await Client.request_data_await(&"death_bag.loot_all", {"bag_id": bag_id}, instance_name)
	if result.size() < 2 or result[1] != OK:
		return
	if bool(result[0].get("ok", false)):
		_close_loot_window()
		Toaster.toast("Loot All completado.")
	else:
		match str(result[0].get("reason", "")):
			"inventory_full": Toaster.toast("No tienes espacio en el inventario.")
			_: Toaster.toast("No se pudo ejecutar Loot All.")


func _close_loot_window() -> void:
	var bag_id := _opened_bag_id
	_opened_bag_id = 0
	var window := get_node_or_null("DeathBagLootWindow")
	if window != null:
		window.queue_free()
	if bag_id > 0:
		var instance := InstanceClient.current
		if instance != null:
			Client.request_data_await(&"death_bag.close", {"bag_id": bag_id}, instance.name)


func _clear_bags() -> void:
	for bag_id: int in _bags:
		var node: Node2D = _bags[bag_id]
		if is_instance_valid(node):
			node.queue_free()
	_bags.clear()
