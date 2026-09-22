extends Node
## PirateWorld PoC-01 client bridge.
## F sends pickup intent; the server validates distance, instance and bag state.

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
	label.text = "Mochila de %s" % str(payload.get("owner_name", "Desconocido"))
	label.position = Vector2(-45, 18)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	node.add_child(label)
	node.global_position = payload.get("position", Vector2.ZERO)
	instance.instance_map.add_child(node)
	_bags[bag_id] = node


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
    _opened_bag_id = nearest_id
    var contents: Dictionary = payload.get("contents", {})
    if contents.is_empty():
        Toaster.toast("La mochila está vacía.")
        return
    var lines: Array[String] = []
    for slot_uid in contents:
        var slot = contents[slot_uid]
        if slot is Dictionary:
            lines.append("%s: ID %d x%d" % [str(slot_uid), int(slot.get("id", 0)), int(slot.get("a", 0))])
    Toaster.toast("Mochila de %s | %s" % [str(payload.get("owner_name", "Desconocido")), " | ".join(lines)])
    Toaster.toast("PoC-02: F abre el contenido; loot selectivo/UI detallada será el siguiente paso.")


func _clear_bags() -> void:
	for bag_id: int in _bags:
		var node: Node2D = _bags[bag_id]
		if is_instance_valid(node):
			node.queue_free()
	_bags.clear()
