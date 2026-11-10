class_name SoulsPlayer2D
extends CharacterBody2D
## Soul Tether — Godot 4.7 2D Souls-Like Player Controller

signal health_changed(current_hp: int, max_hp: int)
signal stamina_changed(current_stamina: float, max_stamina: float)
signal iframe_state_changed(is_invulnerable: bool)
signal player_dodged(is_backstep: bool)

enum State { IDLE, RUN, JUMP, FALL, ROLL, BACKSTEP, HURT }

@export_group("Movement")
@export var max_speed: float = 240.0
@export var ground_accel: float = 1800.0
@export var ground_decel: float = 2200.0
@export var air_accel: float = 1100.0
@export var air_decel: float = 900.0

@export_group("Jump & Gravity")
@export var jump_velocity: float = -460.0
@export var jump_cut_multiplier: float = 0.5
@export var gravity_up: float = 1250.0
@export var gravity_down: float = 1650.0
@export var max_fall_speed: float = 920.0
@export var coyote_time_duration: float = 0.11
@export var jump_buffer_duration: float = 0.12

@export_group("Souls Dodge, Roll & i-Frames")
@export var roll_speed: float = 380.0
@export var backstep_speed: float = 270.0
@export var roll_duration: float = 0.42
@export var backstep_duration: float = 0.30
@export var iframe_start_delay: float = 0.04
@export var iframe_duration: float = 0.26
@export var roll_cooldown_duration: float = 0.12
@export var roll_stamina_cost: float = 28.0
@export var backstep_stamina_cost: float = 18.0

@export_group("Stats & Stamina")
@export var max_health: int = 100
@export var max_stamina: float = 100.0
@export var stamina_regen_rate: float = 32.0
@export var stamina_regen_delay: float = 0.65

@export_group("Collision Layers (1-Indexed)")
@export var world_layer_bit: int = 1
@export var enemy_obstacle_layer_bit: int = 3

var current_state: State = State.IDLE
var facing_direction: int = 1
var current_health: int = max_health
var current_stamina: float = max_stamina

var _coyote_timer: float = 0.0
var _jump_buffer_timer: float = 0.0
var _dodge_timer: float = 0.0
var _dodge_elapsed: float = 0.0
var _roll_cooldown_timer: float = 0.0
var _stamina_delay_timer: float = 0.0
var _hurt_timer: float = 0.0

var is_invulnerable: bool = false
var _active_dodge_direction: int = 1
var _active_dodge_speed: float = 0.0
var _spawn_position: Vector2 = Vector2.ZERO

var hurtbox: Area2D = null
var visual_poly: Polygon2D = null
var body_collider: CollisionShape2D = null

func _ready() -> void:
	_spawn_position = global_position
	current_health = max_health
	current_stamina = max_stamina
	hurtbox = get_node_or_null("Hurtbox") as Area2D
	visual_poly = get_node_or_null("VisualPolygon") as Polygon2D
	body_collider = get_node_or_null("CollisionShape2D") as CollisionShape2D
	if hurtbox and not hurtbox.area_entered.is_connected(_on_hurtbox_area_entered):
		hurtbox.area_entered.connect(_on_hurtbox_area_entered)
	health_changed.emit(current_health, max_health)
	stamina_changed.emit(current_stamina, max_stamina)

func _physics_process(delta: float) -> void:
	_update_timers(delta)
	_regenerate_stamina(delta)
	var input_axis: float = Input.get_axis("move_left", "move_right")
	if not is_zero_approx(input_axis) and current_state not in [State.ROLL, State.BACKSTEP, State.HURT]:
		facing_direction = 1 if input_axis > 0.0 else -1
	if Input.is_action_just_pressed("jump"):
		_jump_buffer_timer = jump_buffer_duration
	if Input.is_action_just_pressed("dodge"):
		_try_start_dodge(input_axis)
	match current_state:
		State.IDLE, State.RUN, State.JUMP, State.FALL:
			_process_standard_locomotion(delta, input_axis)
		State.ROLL, State.BACKSTEP:
			_process_dodge_state(delta)
		State.HURT:
			_process_hurt_state(delta)
	move_and_slide()
	_update_visual_feedback()

func _update_timers(delta: float) -> void:
	_coyote_timer = coyote_time_duration if is_on_floor() else maxf(0.0, _coyote_timer - delta)
	_jump_buffer_timer = maxf(0.0, _jump_buffer_timer - delta)
	_roll_cooldown_timer = maxf(0.0, _roll_cooldown_timer - delta)
	_stamina_delay_timer = maxf(0.0, _stamina_delay_timer - delta)

func _regenerate_stamina(delta: float) -> void:
	if current_state in [State.ROLL, State.BACKSTEP] or _stamina_delay_timer > 0.0:
		return
	if current_stamina < max_stamina:
		current_stamina = minf(max_stamina, current_stamina + stamina_regen_rate * delta)
		stamina_changed.emit(current_stamina, max_stamina)

func _process_standard_locomotion(delta: float, input_axis: float) -> void:
	if not is_on_floor():
		var active_gravity: float = gravity_up if velocity.y < 0.0 else gravity_down
		velocity.y = minf(max_fall_speed, velocity.y + active_gravity * delta)
	if _jump_buffer_timer > 0.0 and _coyote_timer > 0.0:
		velocity.y = jump_velocity
		_jump_buffer_timer = 0.0
		_coyote_timer = 0.0
		current_state = State.JUMP
	if Input.is_action_just_released("jump") and velocity.y < 0.0:
		velocity.y *= jump_cut_multiplier
	var target_speed: float = input_axis * max_speed
	var accel_rate: float = (ground_accel if not is_zero_approx(input_axis) else ground_decel) if is_on_floor() else (air_accel if not is_zero_approx(input_axis) else air_decel)
	velocity.x = move_toward(velocity.x, target_speed, accel_rate * delta)
	if is_on_floor():
		current_state = State.IDLE if is_zero_approx(velocity.x) else State.RUN
	else:
		current_state = State.JUMP if velocity.y < 0.0 else State.FALL

func _try_start_dodge(input_axis: float) -> void:
	if current_state in [State.ROLL, State.BACKSTEP, State.HURT] or _roll_cooldown_timer > 0.0:
		return
	var is_directional_roll: bool = absf(input_axis) > 0.15
	var stamina_needed: float = roll_stamina_cost if is_directional_roll else backstep_stamina_cost
	if current_stamina < stamina_needed:
		return
	current_stamina = maxf(0.0, current_stamina - stamina_needed)
	_stamina_delay_timer = stamina_regen_delay
	stamina_changed.emit(current_stamina, max_stamina)
	_dodge_elapsed = 0.0
	if is_directional_roll:
		current_state = State.ROLL
		_dodge_timer = roll_duration
		_active_dodge_direction = 1 if input_axis > 0.0 else -1
		facing_direction = _active_dodge_direction
		_active_dodge_speed = roll_speed
		player_dodged.emit(false)
	else:
		current_state = State.BACKSTEP
		_dodge_timer = backstep_duration
		_active_dodge_direction = -facing_direction
		_active_dodge_speed = backstep_speed
		player_dodged.emit(true)

func _process_dodge_state(delta: float) -> void:
	_dodge_elapsed += delta
	_dodge_timer -= delta
	if not is_on_floor():
		velocity.y = minf(max_fall_speed, velocity.y + gravity_down * delta)
	var progress: float = clampf(_dodge_elapsed / maxf(0.01, _dodge_elapsed + _dodge_timer), 0.0, 1.0)
	var speed_curve: float = 1.0 if progress < 0.72 else lerpf(1.0, 0.35, (progress - 0.72) / 0.28)
	velocity.x = _active_dodge_direction * _active_dodge_speed * speed_curve
	var should_have_iframes: bool = (_dodge_elapsed >= iframe_start_delay and _dodge_elapsed <= (iframe_start_delay + iframe_duration))
	if should_have_iframes != is_invulnerable:
		_set_iframes(should_have_iframes)
	if _dodge_timer <= 0.0:
		_set_iframes(false)
		_roll_cooldown_timer = roll_cooldown_duration
		current_state = State.IDLE if is_on_floor() else State.FALL

func _process_hurt_state(delta: float) -> void:
	_hurt_timer -= delta
	if not is_on_floor():
		velocity.y = minf(max_fall_speed, velocity.y + gravity_down * delta)
	velocity.x = move_toward(velocity.x, 0.0, ground_decel * 0.7 * delta)
	if _hurt_timer <= 0.0:
		current_state = State.IDLE if is_on_floor() else State.FALL

func _set_iframes(active: bool) -> void:
	is_invulnerable = active
	iframe_state_changed.emit(is_invulnerable)
	if hurtbox:
		hurtbox.set_deferred("monitoring", not active)
		hurtbox.set_deferred("monitorable", not active)
	set_collision_mask_value(enemy_obstacle_layer_bit, not active)

func apply_damage(amount: int, source_position: Vector2) -> void:
	if is_invulnerable or current_state == State.HURT:
		return
	current_health = maxi(0, current_health - amount)
	health_changed.emit(current_health, max_health)
	var knock_dir: int = -1 if source_position.x > global_position.x else 1
	velocity = Vector2(knock_dir * 210.0, -240.0)
	current_state = State.HURT
	_hurt_timer = 0.25
	if current_health <= 0:
		respawn_at_checkpoint()

func respawn_at_checkpoint() -> void:
	_set_iframes(false)
	global_position = _spawn_position
	velocity = Vector2.ZERO
	current_health = max_health
	current_stamina = max_stamina
	current_state = State.IDLE
	health_changed.emit(current_health, max_health)
	stamina_changed.emit(current_stamina, max_stamina)

func _on_hurtbox_area_entered(area: Area2D) -> void:
	if area.is_in_group("kill_zone"):
		respawn_at_checkpoint()
	elif area.is_in_group("hazard_hitbox") and not is_invulnerable:
		apply_damage(20, area.global_position)

func _update_visual_feedback() -> void:
	if not visual_poly:
		return
	visual_poly.scale.x = float(facing_direction)
	visual_poly.scale.y = 0.62 if current_state == State.ROLL else 1.0
	visual_poly.position.y = 11.0 if current_state == State.ROLL else 0.0
	if is_invulnerable:
		visual_poly.color = Color(0.25, 0.95, 1.0, 0.78)
	elif current_state in [State.ROLL, State.BACKSTEP]:
		visual_poly.color = Color(0.95, 0.78, 0.25, 1.0)
	elif current_state == State.HURT:
		visual_poly.color = Color(1.0, 0.28, 0.28, 1.0)
	else:
		visual_poly.color = Color(0.88, 0.90, 0.95, 1.0)
