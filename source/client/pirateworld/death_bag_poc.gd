extends Node
## PirateWorld PoC-01 client bridge.
## F sends pickup intent; the server validates distance, instance and bag state.

const BAG_ICON_PATH: String = "res://assets/sprites/items/icons/Icon271.png"
const PICKUP_ACTION: StringName = &"player_interact"
const PICKUP_RANGE: float = 96.0

var _bags: Dictionary[int, Node2D] = {}
var _instance_name: String = ""
var _syncing: bool = false

func _ready() -> void:
\tif not GameMode.is_client():
\t\tqueue_free()
\t\treturn
\tClient.subscribe(&"pirateworld.death_bag.spawn", _on_bag_spawn)
\tClient.subscribe(&"pirateworld.death_bag.remove", _on_bag_remove)
\tcall_deferred("_refresh_instance")


func _process(_delta: float) -> void:
\tvar instance: InstanceClient = InstanceClient.current
\tif instance == null or instance.instance_map == null:
\t\treturn
\tvar current_name: String = instance.name
\tif current_name != _instance_name:
\t\t_instance_name = current_name
\t\t_clear_bags()
\t\t_refresh_instance()
\tif Input.is_action_just_pressed(PICKUP_ACTION):
\t\t_try_pickup(instance)


func _refresh_instance() -> void:
\tif _syncing:
\t\treturn
\tvar instance: InstanceClient = InstanceClient.current
\tif instance == null or instance.instance_map == null:
\t\tcall_deferred("_refresh_instance")
\t\treturn
\t_instance_name = instance.name
\t_syncing = true
\tvar result: Array = await Client.request_data_await(&"death_bag.list", {}, instance.name)
\t_syncing = false
\tif result.size() < 2 or result[1] != OK:
\t\treturn
\tvar payload: Dictionary = result[0]
\tif not bool(payload.get("ok", false)):
\t\treturn
\t_clear_bags()
\tfor bag: Dictionary in payload.get("bags", []):
\t\t_on_bag_spawn(bag)


func _on_bag_spawn(payload: Dictionary) -> void:
\tif payload.is_empty():
\t\treturn
\tvar bag_id: int = int(payload.get("bag_id", 0))
\tif bag_id <= 0:
\t\treturn
\tvar instance: InstanceClient = InstanceClient.current
\tif instance == null or instance.instance_map == null:
\t\treturn
\tif _bags.has(bag_id):
\t\t_bags[bag_id].global_position = payload.get("position", Vector2.ZERO)
\t\treturn
\tvar node := Node2D.new()
\tnode.name = "DeathBag_%d" % bag_id
\tnode.z_index = 2
\tvar sprite := Sprite2D.new()
\tsprite.texture = load(BAG_ICON_PATH)
\tsprite.scale = Vector2(1.5, 1.5)
\tnode.add_child(sprite)
\tvar label := Label.new()
\tlabel.text = "Death Bag %d" % bag_id
\tlabel.position = Vector2(-45, 18)
\tlabel.mouse_filter = Control.MOUSE_FILTER_IGNORE
\tnode.add_child(label)
\tnode.global_position = payload.get("position", Vector2.ZERO)
\tinstance.instance_map.add_child(node)
\t_bags[bag_id] = node


func _on_bag_remove(payload: Dictionary) -> void:
\tvar bag_id: int = int(payload.get("bag_id", 0))
\tif not _bags.has(bag_id):
\t\treturn
\t_bags[bag_id].queue_free()
\t_bags.erase(bag_id)


func _try_pickup(instance: InstanceClient) -> void:
\tif instance.local_player == null:
\t\treturn
\tvar nearest_id: int = 0
\tvar nearest_distance: float = PICKUP_RANGE + 0.01
\tfor bag_id: int in _bags:
\t\tvar bag: Node2D = _bags[bag_id]
\t\tif not is_instance_valid(bag):
\t\t\tcontinue
\t\tvar distance: float = instance.local_player.global_position.distance_to(bag.global_position)
\t\tif distance <= nearest_distance:
\t\t\tnearest_distance = distance
\t\t\tnearest_id = bag_id
\tif nearest_id <= 0:
\t\tToaster.toast("No Death Bag nearby.")
\t\treturn
\tvar result: Array = await Client.request_data_await(
\t\t&"death_bag.pickup",
\t\t{"bag_id": nearest_id},
\t\tinstance.name
\t)
\tif result.size() < 2 or result[1] != OK:
\t\treturn
\tvar payload: Dictionary = result[0]
\tif bool(payload.get("ok", false)):
\t\tToaster.toast("Death Bag recovered.")
\telse:
\t\tmatch str(payload.get("reason", "")):
\t\t\t"too_far": Toaster.toast("That Death Bag is too far away.")
\t\t\t"not_found": Toaster.toast("That Death Bag is already gone.")
\t\t\t_: Toaster.toast("Couldn't recover the Death Bag.")
\nfunc _clear_bags() -> void:
\tfor bag_id: int in _bags:
\t\tvar node: Node2D = _bags[bag_id]
\t\tif is_instance_valid(node):
\t\t\tnode.queue_free()
\t_bags.clear()
