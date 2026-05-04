extends Node2D

@export var N := 16				# Amount of cells in rows and columns (size of the grid)
@export var cell_size := 32		# Size of a single cell in pixels

@export var density_fade_rate := 0.1			# Strength of density fade effect
@export var density_diffuse_rate := 0.006		# Strength of density diffusion effect
@export var density_diffuse_iterations := 20	# How many iterations when diffusing density

@export var velocity_draw_scale := 20.0
@export var velocity_add_scale := 0.06
@export var velocity_fade_rate := 0.2			# Strength of velocity fade effect
@export var velocity_diffuse_rate := 0.001		# Strength of velocity diffusion effect
@export var velocity_diffuse_iterations := 20	# How many iterations when diffusing velocity

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

# TODO: What are those?
# Helper fields for projection
var pressure: PackedFloat32Array
var divergence: PackedFloat32Array

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
	pressure.resize(size)
	divergence.resize(size)

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

func copy_density_to_prev() -> void:
	for idx in range(size):
		density_prev[idx] = density[idx]

func copy_velocity_to_prev() -> void:
	for idx in range(size):
		u_prev[idx] = u[idx]
		v_prev[idx] = v[idx]

# Advection of density means "moving density through the velocity field"
# With this function we make our density react to the velocity and move along it
# Your first instinct on implementing such a function might be to go through each cell and check
# where its velocity points to and then move the density there - but this is not performant
# We do something else here - we move BACKWARDS THROUGH TIME. For each grid cell we make use
# of the velocity there to deduce where the density in that cell probably came from.
# You might think that's incorrect, because the velocity in a cell might point to the right
# but that doesn't mean that the density it contains came from the left - it might have just as well
# came from the top cell, why not? You would be right! But we need to recognize two things here:
# one is that we are dealing with a FIELD of velocities, which is unlikely to do such harsh turns;
# two is that we need to sacrifice accuracy for performance at some point - this is one of those points
func advect_density(delta: float) -> void:
	# Multiply delta by N to scale the time by grid size
	var dt0 := delta * N

	for j in range(1, N + 1):
		for i in range(1, N + 1):
			var idx := IX(i, j)

			# Notice this tracks backwards through time
			# First we subtract the velocity in this cell (multiplied by delta)
			# from the cell index
			# That tells us where the density in this cell came from (probably)
			# Then we clamp to make sure we don't go outside the grid
			# The result will be a position of where the density probably came from, lying somewhere
			# between other grid cells
			var x := i - dt0 * u[idx]
			var y := j - dt0 * v[idx]
			x = clamp(x, 0.5, N + 0.5)
			y = clamp(y, 0.5, N + 0.5)

			# This grabs the four cells surrounding the point that we end at above
			# Imagine we end at a point (7.3, 4.8)
			# The four cells around this point (including the one it is part of)
			# will be: (7,4) (8,4) (7,5) (8,5), because
			# i0 = 7
			# i1 = 8
			# j0 = 4
			# j1 = 5
			# (it's a combination of all "i" with all "j")
			var i0 := int(floor(x))
			var i1 := i0 + 1
			var j0 := int(floor(y))
			var j1 := j0 + 1

			# These are fractional weights
			# They tell us how close the point is to each side
			# Consider example where our point is at (7.3, 4.8)
			# That gives us: s1 = 0.3, s0 = 0.7, t1 = 0.8, t0 = 0.2
			# Basically we extract the decimal part into s1 and t1
			# And then we put "the rest that is missing to 1.0" into s0 and t0
			# ---
			# What this tells us, is basically that:
			# the point is at 30% distance from left side and 70% distance from right side
			# which means it should be influenced stronger by the left side and less by the right side
			# Same for y dimension, the point is at 80% distance towards bottom and 20% towards top
			var s1 := x - i0
			var s0 := 1.0 - s1
			var t1 := y - j0
			var t0 := 1.0 - t1

			# With neighbouring tiles and the fractional weights calculated,
			# we now need to decide how much density we should grab from each neighbouring tile
			# based on how close we are to it (fractional weights tells us that)
			# This function does exactly that. It's a standard mathematical operation called
			# "bilinear interpolation". You might be familiar with "linear interpolation", often
			# called "lerp" in the gamedev world, which interpolates between values in a single
			# dimension (line). Bilinear interpolation does the same, except in two dimensions (lines)
			# ---
			# Notice also that we make use of the density_prev array here. That's because we
			# keep updating the density array as we iterate, so we need to "snapshot" the densities
			# before we start iterating - otherwise we would mess up results as they would keep changing
			# So density_prev is pretty much a "snapshot of density before we start modifying it"
			density[idx] = (
				s0 * (t0 * density_prev[IX(i0, j0)] + t1 * density_prev[IX(i0, j1)]) +
				s1 * (t0 * density_prev[IX(i1, j0)] + t1 * density_prev[IX(i1, j1)])
			)
	set_bnd(BoundaryType.SCALAR, density)

# When we advect density, we move density along the velocity field
# Here we do the same but with the velocity itself - so we move velocity along the velocity field
# This simulates sort of "momentum"
# It works exactly the same way as advecting density, with one caveat - we have to snapshot the
# velocity arrays and use the snapshot as source (because we modify the actual velocity array in this function,
# which doesn't happen for density)
# See "advect_density" function for details
func advect_velocity(delta: float) -> void:
	var dt0 := delta * N

	for j in range(1, N + 1):
		for i in range(1, N + 1):
			var idx := IX(i, j)

			# Go backwards through time
			# Notice we are using u_prev and v_prev here - we need stable values
			# The rest of the function is the same as for advecting density
			var x := i - dt0 * u_prev[idx]
			var y := j - dt0 * v_prev[idx]
			x = clamp(x, 0.5, N + 0.5)
			y = clamp(y, 0.5, N + 0.5)

			# Find cell neighborus for the point we arrive at
			var i0 := int(floor(x))
			var i1 := i0 + 1
			var j0 := int(floor(y))
			var j1 := j0 + 1

			# Calculate fractional weights
			var s1 := x - i0
			var s0 := 1.0 - s1
			var t1 := y - j0
			var t0 := 1.0 - t1

			# Approximate the values using bilinear interpolation
			u[idx] = (
				s0 * (t0 * u_prev[IX(i0, j0)] + t1 * u_prev[IX(i0, j1)]) +
				s1 * (t0 * u_prev[IX(i1, j0)] + t1 * u_prev[IX(i1, j1)])
			)

			v[idx] = (
				s0 * (t0 * v_prev[IX(i0, j0)] + t1 * v_prev[IX(i0, j1)]) +
				s1 * (t0 * v_prev[IX(i1, j0)] + t1 * v_prev[IX(i1, j1)])
			)

	set_bnd(BoundaryType.VELOCITY_HORIZONTAL, u)
	set_bnd(BoundaryType.VELOCITY_VERTICAL, v)

# Projection is what makes the simulation behave natural
# We want to simulate an incompressible fluid, which means that density should neither magically
# "pile-up" (compress) or "vanish" (decompress) - basically we want it to conserve mass
# The problem is that both velocity diffusion and velocity advection cause these "artifacts"
# To solve this, we need to perform projection with two helper arrays: divergence and pressure
# I call them "helper" arrays because we don't render them (like we do density and velocity arrays)
# We just use them for calculation and correction
# Divergence measures how much density flows out and into the cell. Positive divergence means
# more density is flowing out than is flowing in. Negative - the opposite. Zero divergence means
# there's balance - and that's what we want.
# Pressure is calculated from divergence and tells us "how much correction should be applied to 
# counteract the divergence"
# High pressure pushes velocity away, low pressure pulls velocity in, pressure gradient tells us
# the direction and strength of the flow - that can counteract the divergence effects and make the fluid behave realistically
# This is what projection is - a way of finding such a pressure field that will cancel out the
# divergence, in effect making the simulated fluid conserve mass
# We want to answer the question: "What pressure field p should I subtract so the result velocity has no divergence?"
# This basically gives us a Poisson equation: laplacian(pressure) = divergence
# Solving this exactly is way too expensive computation-wise, so we will use the tool we already know -
# - Gauss-Seidel relaxation - to approximate a good-enough answer
func project_velocity() -> void:
	var h := 1.0 / N	# This is a scaling factor for our grid (basically the distance between one cell center and a neighbouring cell center)

	for j in range(1, N + 1):
		for i in range(1, N + 1):
			
			# We calculate divergence by observing the velocities of neghbouring cells
			# Remember - we want to check if the fluid flowing in and out of this cell is in balance or not
			# Velocity of the neighbours will tell us that. For vertical velocity we look one cell down and one cell up
			# For horzontal velocity - one cell to the left and one to the right
			divergence[IX(i, j)] = -0.5 * h * (			# Multiplying by 0.5 centers the difference because we are looking at two neighbours
														# The negative sign is just for convenience - it matches the later equation of where pressure is added to the Poisson solve
				u[IX(i + 1, j)] - u[IX(i - 1, j)] +		# Horizontal velocity to the left and right
				v[IX(i, j + 1)] - v[IX(i, j - 1)]		# Vertical velocity to the up and down
			)
			pressure[IX(i, j)] = 0.0	# Initialize pressure to 0 at each cell, we will approximate it later

	# As with any other field, we need to calculate the boundaries
	# Both divergence and pressure are simple scalar fields, same as density, so we treat them the same
	set_bnd(BoundaryType.SCALAR, divergence)
	set_bnd(BoundaryType.SCALAR, pressure)

	# This is the same familiar Gauss-Seidel relaxation equation that we have used before
	# Calculating exact pressure is too expensive, so we approximate with Gauss-Seidel relaxation
	# Iterating 20 times should be good enough
	# Once we are finished, we get a pressure field to correct the effect of divergence
	for k in range(20):
		for j in range(1, N + 1):
			for i in range(1, N + 1):
				
				# New pressure at this cell = local divergence + average of neighbouring pressures
				# Notice how the divergence stays static (this loop doesn't modify the divergence array)
				# But the pressure array changes in each iteration
				# After repeating that 20 times we arrive at a solution that is good enough - an approximation
				pressure[IX(i, j)] = (
					divergence[IX(i, j)] +		# Local divergence
					pressure[IX(i - 1, j)] +	# Neighbouring pressures
					pressure[IX(i + 1, j)] +
					pressure[IX(i, j - 1)] +
					pressure[IX(i, j + 1)]
				) / 4.0							# Four neighbours so we divide to get an average

		set_bnd(BoundaryType.SCALAR, pressure)

	# Here we subtract the pressure gradient from velocity to eliminate the "unnatural" part
	# The right hand side is the gradient calculation
	# Technically, a gradient of a scalar field (which pressure is) is a vector field
	# Such field contains vectors which point in the direction where pressure increases the fastest
	# And the magnitude of those vectors tells us how steep that increase is
	# We operate on a grid, so we can approximate this with neighbours - left and right for horizontal
	# velocity and top and down for vertical velocity.
	# We need to divide by 2h because the distance between the neighbours is 2h
	# So we arrive at equation: (p[i+1] - p[i-1]) / (2h)
	# After simplification it becomes: 0.5 * (p[i+1] - p[i-1]) / h
	for j in range(1, N + 1):
		for i in range(1, N + 1):
			u[IX(i, j)] -= 0.5 * (pressure[IX(i + 1, j)] - pressure[IX(i - 1, j)]) / h
			v[IX(i, j)] -= 0.5 * (pressure[IX(i, j + 1)] - pressure[IX(i, j - 1)]) / h

	set_bnd(BoundaryType.VELOCITY_HORIZONTAL, u)
	set_bnd(BoundaryType.VELOCITY_VERTICAL, v)

# Diffusion simply means spreading the density to the neighbouring cells
# Think of it like putting a drop of paint in water - it will spread
# This uses what is called "Gauss-Seidel relaxation", which basically means
# we keep "guessing" (or rather approximating) the value density_diffuse_rate times
# With enough iterations, this is close enough for the simulation to be believable
func diffuse_density(delta: float) -> void:
	
	# This is the strength of diffusion effect for this frame
	# Delta is how much time passed
	# Then we have the density diffusion strength parameter
	# Finally we multiply by N squared so it scales with cell size
	var a := delta * density_diffuse_rate * N * N

	for k in range(density_diffuse_iterations):
		for j in range(1, N + 1):
			for i in range(1, N + 1):
				var idx := IX(i, j)

				density[idx] = (
					density_prev[idx] +				# This is the "anchor" - the original value at this cell, which stays constant throughout iterations (hence called "anchor")
					a * (							# Here we multiple the strength of the effect with the sum of densities of all neighbours - this is the heart of "Gauss-Seidel" relaxation
						density[IX(i - 1, j)] +		# These are
						density[IX(i + 1, j)] +		# the four
						density[IX(i, j - 1)] +		# neighbours
						density[IX(i, j + 1)]		# :)
					)
				) / (1.0 + 4.0 * a)					# This balances the math, since we add densities from 5 cells (this one + 4 neighbours). Without this, the density would grow too much (try it!)
		set_bnd(BoundaryType.SCALAR, density)

# Diffusion here can be understood as "spreading among neighbour cells"
# Just as we diffuse density, we now do the same for velocity
# This is pretty much exactly the same as density diffusion, except it does it for two arrays
# (because we store horizontal and vertical velocity separately)
# It uses the same "Gauss-Seidel relaxation" formula
func diffuse_velocity(delta: float) -> void:
	
	# This is the strength of diffusion effect for this frame
	# Delta is how much time passed
	# Then we have the velocity diffusion strength parameter
	# Finally we multiply by N squared so it scales with cell size
	var a := delta * velocity_diffuse_rate * N * N

	for k in range(velocity_diffuse_iterations):
		for j in range(1, N + 1):
			for i in range(1, N + 1):
				var idx := IX(i, j)

				# Those are exactly the same formulas as for density
				# See density diffusion function for explanations :)
				u[idx] = (
					u_prev[idx] +
					a * (
						u[IX(i - 1, j)] +
						u[IX(i + 1, j)] +
						u[IX(i, j - 1)] +
						u[IX(i, j + 1)]
					)
				) / (1.0 + 4.0 * a)

				v[idx] = (
					v_prev[idx] +
					a * (
						v[IX(i - 1, j)] +
						v[IX(i + 1, j)] +
						v[IX(i, j - 1)] +
						v[IX(i, j + 1)]
					)
				) / (1.0 + 4.0 * a)
		set_bnd(BoundaryType.VELOCITY_HORIZONTAL, u)
		set_bnd(BoundaryType.VELOCITY_VERTICAL, v)

# This is the "original" function as defined in the Stam paper
# It is NOT USED by this program. I left it only for reference
# It is much more performant because it doesn't declare needless variables
# But that also make is harder to understand what is going on here
func set_bnd_original(b: int, grid: PackedFloat32Array) -> void:
	for i in range(1, N + 1):
		grid[IX(0, i)] = -grid[IX(1, i)] if b == 1 else grid[IX(1, i)]
		grid[IX(N + 1, i)] = -grid[IX(N, i)] if b == 1 else grid[IX(N, i)]

		grid[IX(i, 0)] = -grid[IX(i, 1)] if b == 2 else grid[IX(i, 1)]
		grid[IX(i, N + 1)] = -grid[IX(i, N)] if b == 2 else grid[IX(i, N)]

	grid[IX(0, 0)] = 0.5 * (grid[IX(1, 0)] + grid[IX(0, 1)])
	grid[IX(0, N + 1)] = 0.5 * (grid[IX(1, N + 1)] + grid[IX(0, N)])
	grid[IX(N + 1, 0)] = 0.5 * (grid[IX(N, 0)] + grid[IX(N + 1, 1)])
	grid[IX(N + 1, N + 1)] = 0.5 * (grid[IX(N, N + 1)] + grid[IX(N + 1, N)])

enum BoundaryType {
	SCALAR,
	VELOCITY_HORIZONTAL,
	VELOCITY_VERTICAL
}

# This function handles boundary cells, which are not part of the simulation. It effectively
# establishes a "wall". We do this by making each boundary cell copy values of their simulated neighbour,
# modifying them accordingly if needed.
# For density, we simply copy the value, simulating fluid spilling out of the box.
# This happens for both density advection (moving along velocity field) and for diffusion
# For velocity, we also copy the value of a simulated neighbour but we invert part of it.
# For top/bottom walls, we invert the vertical values, for left/right we invert the horizontal values
# This makes the boundaries behave as "walls" for velocity
# Note: I realize declaring so many needless variables is bad for performance. This is done on purpose
# to make it easier to understand what is going on here. Original function included, see "set_bnd_original"
func set_bnd(boundary: BoundaryType, grid: PackedFloat32Array) -> void:
	
	# We iterate from 1 to N+1 because we want to tackle boundaries, which are a single row/column
	for i in range(1, N + 1):
		
		# These define the indexes of boundary cells (the red ones)
		# We will set values for those
		var left_boundary_cell_index = IX(0, i)
		var right_boundary_cell_index = IX(N + 1, i)
		var bottom_boundary_cell_index = IX(i, 0)
		var top_boundary_cell_index = IX(i, N + 1)
		
		# These define the nearest cell neighbour of a boundary cell that is a real cell
		# We will copy values from those
		var leftmost_simulated_cell_index = IX(1, i)
		var rightmost_simulated_cell_index = IX(N, i)
		var bottommost_simulated_cell_index = IX(i, 1)
		var topmost_simulated_cell_index = IX(i, N)
		
		# For density, we simply copy the value of the nearest simulated cell
		if boundary == BoundaryType.SCALAR:
			grid[left_boundary_cell_index] = grid[leftmost_simulated_cell_index]
			grid[right_boundary_cell_index] = grid[rightmost_simulated_cell_index]
			grid[bottom_boundary_cell_index] = grid[bottommost_simulated_cell_index]
			grid[top_boundary_cell_index] = grid[topmost_simulated_cell_index]
		
		# For horizontal velocity, we flip the values on the horizontal axis (the boundary wall
		# "reflects" the velocity) and just copy the vertical values
		elif boundary == BoundaryType.VELOCITY_HORIZONTAL:
			grid[left_boundary_cell_index] = -grid[leftmost_simulated_cell_index]
			grid[right_boundary_cell_index] = -grid[rightmost_simulated_cell_index]
			grid[bottom_boundary_cell_index] = grid[bottommost_simulated_cell_index]
			grid[top_boundary_cell_index] = grid[topmost_simulated_cell_index]
		
		# For vertical velocity, we flip the values on the vertical axis (the boundary wall
		# "reflects" the velocity) and just copy the horizontal values
		elif boundary == BoundaryType.VELOCITY_VERTICAL:
			grid[left_boundary_cell_index] = grid[leftmost_simulated_cell_index]
			grid[right_boundary_cell_index] = grid[rightmost_simulated_cell_index]
			grid[bottom_boundary_cell_index] = -grid[bottommost_simulated_cell_index]
			grid[top_boundary_cell_index] = -grid[topmost_simulated_cell_index]

	# Corners
	# Boundary corner cells are a special case because they have two neighbours (both of which are boundary cells as well)
	# Since we already set the values for all the other boundary cells in the loop above,
	# here we just set each corner to an average of their two neighbours
	# For ease of understanding I labeled the vars with SW like South-West, etc.
	var corner_SW = IX(0, 0)
	var corner_SW_right_neighbour = IX(1, 0)
	var corner_SW_top_neighbour = IX(0, 1)
	var corner_NW = IX(0, N + 1)
	var corner_NW_right_neighbour = IX(1, N + 1)
	var corner_NW_bottom_neighbour = IX(0, N)
	var corner_SE = IX(N + 1, 0)
	var corner_SE_left_neighbour = IX(N, 0)
	var corner_SE_top_neighbour = IX(N + 1, 1)
	var corner_NE = IX(N + 1, N + 1)
	var corner_NE_left_neighbour = IX(N, N + 1)
	var corner_NE_bottom_neighbour = IX(N + 1, N)
	
	grid[corner_SW] = 0.5 * (grid[corner_SW_right_neighbour] + grid[corner_SW_top_neighbour])		# SW corner = right neighbour + top neighbour
	grid[corner_NW] = 0.5 * (grid[corner_NW_right_neighbour] + grid[corner_NW_bottom_neighbour])	# NW corner = right neighbour + bottom neighbour
	grid[corner_SE] = 0.5 * (grid[corner_SE_left_neighbour] + grid[corner_SE_top_neighbour])		# SE corner = left neighbour + top neighbour
	grid[corner_NE] = 0.5 * (grid[corner_NE_left_neighbour] + grid[corner_NE_bottom_neighbour])		# NE corner = left neighbour + bottom neighbour

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
func _process(delta: float) -> void:
	copy_velocity_to_prev()
	diffuse_velocity(delta)
	project_velocity()
	
	copy_velocity_to_prev()
	advect_velocity(delta)
	project_velocity()
	
	copy_density_to_prev()
	diffuse_density(delta)
	
	copy_density_to_prev()
	advect_density(delta)
	
	fade_density(delta)
	#fade_velocity(delta)
	
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
