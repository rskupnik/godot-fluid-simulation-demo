extends Node2D

@export var N := 16				# Amount of cells in rows and columns (size of the grid)
@export var cell_size := 32		# Size of a single cell in pixels

@export var density_fade_rate := 0.1

@export var velocity_draw_scale := 20.0
@export var velocity_add_scale := 0.06
@export var velocity_fade_rate := 0.2

var is_dragging := false
var last_mouse_cell := Vector2i.ZERO

var size := 0

# Density means "how much material does this cell contain"
var density: PackedFloat32Array
var density_prev: PackedFloat32Array

# "u" stores the horizontal velocity (x direction)
var u: PackedFloat32Array
var u_prev: PackedFloat32Array

# "v" stores the vertical velocity (y direction)
var v: PackedFloat32Array
var v_prev: PackedFloat32Array

func _ready():
	# Resize all the arrays properly
	# We use single array to store a grid, which is why we need to multiply N
	# The "+2" is added for borders, because there are two for each dimension (x, and y)
	# For x dimension, there's a single cell border on the left and on the right, hence "+2". Same for the y direction
	size = (N + 2) * (N + 2)

	density.resize(size)
	density_prev.resize(size)
	u.resize(size)
	v.resize(size)
	u_prev.resize(size)
	v_prev.resize(size)

	queue_redraw()

# This is a helper function that makes it easier to work with a grid when it is
# packed into a single-dimension array
# We can call it with the cell index (i and j) and it will translate it into
# an index in the single-dimension array
func IX(i: int, j: int) -> int:
	return i + (N + 2) * j

# This helper function translates the position we clicked on with the mouse
# into the cell coordinates
# So if we click somewhere in the grid, it will return a Vector2i, where the
# first element is the index of the cell in that grid in x dimension
# and the other element is the index of the cell in the y dimension
func cell_from_mouse(pos: Vector2) -> Vector2i:
	return Vector2i(floor(pos.x / cell_size), floor(pos.y / cell_size))

# Fade density as the time passes
func fade_density(delta: float) -> void:
	for j in range(1, N + 1):
		for i in range(1, N + 1):
			var idx := IX(i, j)
			# We need to multiply the rate of density fade through delta
			# to make it the same despite the framerate
			density[idx] = max(0.0, density[idx] - density_fade_rate * delta)

# Fade velocity as the time passes
func fade_velocity(delta: float) -> void:
	for j in range(1, N + 1):
		for i in range(1, N + 1):
			var idx := IX(i, j)
			# We need to multiply the rate of velocity fade through delta
			# to make it the same despite the framerate
			u[idx] = move_toward(u[idx], 0.0, velocity_fade_rate * delta)
			v[idx] = move_toward(v[idx], 0.0, velocity_fade_rate * delta)

# This is the standard Godot function for processing input
# We want to detect when a mouse is dragged while clicked and the inject
# both density and velocity at the relevant cells
func _input(event):
	if event is InputEventMouseButton:
		is_dragging = event.pressed
		last_mouse_cell = cell_from_mouse(to_local(event.position))

	if event is InputEventMouseMotion and is_dragging:
		var local_pos := to_local(event.position)
		var cell := cell_from_mouse(local_pos)

		var i := cell.x
		var j := cell.y

		if i >= 1 and i <= N and j >= 1 and j <= N:
			# event.relative stores the relative difference between last time
			# this function was called and this time
			# in this case, it tells us how far the mouse has travelled
			# we use that to decide how much velocity to add
			var delta_velocity : Vector2 = event.relative * velocity_add_scale
			var idx := IX(i, j)

			# Inject the velocity into the cell
			# u stores horizontal velocity, v stores vertical velocity
			u[idx] += delta_velocity.x
			v[idx] += delta_velocity.y

			# Inject density
			density[idx] += 1.0

			queue_redraw()

# This is the standard Godot function called every frame
# It's the heart of our simulation
# The "delta" variable hold the amount of time that passed since the last frame
# For now we use it to slowly fade the density and velocity
func _process(delta: float) -> void:
	fade_density(delta)
	fade_velocity(delta)
	queue_redraw()

# This is the standard Godot function used for drawing
# We want to draw a simple grid of (N+2)*(N+2) rectangles of size cell_size
# We also want to draw velocities at each cell as lines
func _draw():
	_draw_grid()
	_draw_velocity_arrows()

# Draw the grid of (N+2)*(N+2) with different colors for inner and boundary cells
func _draw_grid():
	for j in range(0, N + 2):
		for i in range(0, N + 2):
			var x := i * cell_size	# this translates the index into pixel position on screen
			var y := j * cell_size
			var rect := Rect2(x, y, cell_size, cell_size)

			var is_boundary := i == 0 or j == 0 or i == N + 1 or j == N + 1
			var fill := Color(0.08, 0.08, 0.08)
			if is_boundary:
				fill = Color(0.16, 0.08, 0.08)
			else:
				# Even though density can go above 1.0, we need to clamp it to values between 0.0 and 1.0 for drawing
				var d : float = clamp(density[IX(i, j)], 0.0, 1.0)
				fill = Color(d, d, d)

			draw_rect(rect, fill, true)
			draw_rect(rect, Color(0.35, 0.35, 0.35), false)

# Draw velocity arrows in inner cells with tiny circles as arrow tips
func _draw_velocity_arrows():
	for j in range(0, N + 2):
		for i in range(0, N + 2):
			var is_boundary := i == 0 or j == 0 or i == N + 1 or j == N + 1
			if not is_boundary:
				var idx := IX(i, j)
				var center := Vector2(
					i * cell_size + cell_size * 0.5,
					j * cell_size + cell_size * 0.5
				)

				var velocity := Vector2(u[idx], v[idx])
				var end := center + velocity * velocity_draw_scale

				draw_line(center, end, Color(0.2, 0.8, 1.0), 2.0)
				draw_circle(end, 2.5, Color(0.2, 0.8, 1.0))
