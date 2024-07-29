import numpy as np
import matplotlib.pyplot as plt
from mpl_toolkits.mplot3d import Axes3D

def translate(points, translation_vector):
    return points - translation_vector

def rotate(points, axis_vector):
    axis_vector = axis_vector / np.linalg.norm(axis_vector)
    z_axis = np.array([0, 0, 1])
    rotation_axis = np.cross(axis_vector, z_axis)
    rotation_angle = np.arccos(np.dot(axis_vector, z_axis))
    
    if np.linalg.norm(rotation_axis) != 0:
        rotation_axis = rotation_axis / np.linalg.norm(rotation_axis)
        ux, uy, uz = rotation_axis
        c = np.cos(rotation_angle)
        s = np.sin(rotation_angle)
        R = np.array([
            [c + ux**2 * (1 - c),     ux * uy * (1 - c) - uz * s, ux * uz * (1 - c) + uy * s],
            [uy * ux * (1 - c) + uz * s, c + uy**2 * (1 - c),     uy * uz * (1 - c) - ux * s],
            [uz * ux * (1 - c) - uy * s, uz * uy * (1 - c) + ux * s, c + uz**2 * (1 - c)]
        ])
    else:
        R = np.eye(3)

    return np.dot(points, R.T)

def cartesian_to_cylindrical(points):
    x, y, z = points[:, 0], points[:, 1], points[:, 2]
    r = np.sqrt(x**2 + y**2)
    theta = np.arctan2(y, x)
    return np.stack((theta, r, z), axis=-1)

def change_to_cylindrical(points, point1, point2):
    points = np.array(points, dtype=float)
    point1 = np.array(point1, dtype=float)
    point2 = np.array(point2, dtype=float)
    
    translation_vector = point1
    axis_vector = point2 - point1
    
    translated_points = translate(points, translation_vector)
    rotated_points = rotate(translated_points, axis_vector)
    cylindrical_points = cartesian_to_cylindrical(rotated_points)
    
    return cylindrical_points

def draw_points_cartesian(points, ax, color='b', label='Cartesian'):
    points = np.array(points)
    ax.scatter(points[:, 0], points[:, 1], points[:, 2], c=color, label=label)

def draw_points_cylindrical(points, ax, color='r', label='Cylindrical'):
    points = np.array(points)
    x = points[:, 1] * np.cos(points[:, 0])
    y = points[:, 1] * np.sin(points[:, 0])
    z = points[:, 2]
    ax.scatter(x, y, z, c=color, label=label)

def plot_points(points, point1, point2):
    fig = plt.figure()
    ax = fig.add_subplot(111, projection='3d')
    
    # Draw Cartesian points
    draw_points_cartesian(points, ax, color='b', label='Cartesian')
    
    # Convert to cylindrical and draw cylindrical points
    cylindrical_points = change_to_cylindrical(points, point1, point2)
    draw_points_cylindrical(cylindrical_points, ax, color='r', label='Cylindrical')
    
    # Draw axis line
    ax.plot([point1[0], point2[0]], [point1[1], point2[1]], [point1[2], point2[2]], 'g-', label='Axis')
    
    ax.set_xlabel('X')
    ax.set_ylabel('Y')
    ax.set_zlabel('Z')
    ax.legend()
    plt.show()
    
    return cylindrical_points

def sort_points(points, point1, point2):
    cylindrical_points = change_to_cylindrical(points, point1, point2)
    
    # Exclude point1 and point2 from sorting
    mask = np.all(np.isclose(points, point1), axis=1) | np.all(np.isclose(points, point2), axis=1)
    
    points_to_sort = cylindrical_points[~mask]
    sorted_indices = np.lexsort((points_to_sort[:, 2], points_to_sort[:, 1], points_to_sort[:, 0]))
    # Sort based on theta, r, then z
    sorted_points = points_to_sort[sorted_indices]
    
    # Combine the sorted points with point1 and point2
    final_points = np.vstack((cylindrical_points[mask], sorted_points))
    
    return final_points

def generate_perpendicular_points(point, point1, point2, num_points=5, f_r=lambda r: 0.25*r):
    point = np.array(point, dtype=float)
    point1 = np.array(point1, dtype=float)
    point2 = np.array(point2, dtype=float)
    
    # Calculate the direction vector of the line
    line_vector = point2 - point1
    line_vector = line_vector.astype(float)  # Ensure float type
    line_vector /= np.linalg.norm(line_vector)
    
    # Find a vector perpendicular to the line
    if line_vector[0] != 0 or line_vector[1] != 0:
        perp_vector = np.array([-line_vector[1], line_vector[0], 0], dtype=float)
    else:
        perp_vector = np.array([0, 1, 0], dtype=float)
    perp_vector /= np.linalg.norm(perp_vector)
    
    # Calculate distances for n points
    r = np.linalg.norm(point1 - point)
    distances = np.linspace(0, r, num=num_points)  # Distances from 0 to r
    distances = [f_r(d) for d in distances]  # Apply the function f(r) to each distance
    
    # Generate points along the perpendicular line
    perpendicular_points = [point + d * perp_vector for d in distances]
    
    return np.array(perpendicular_points)

# Generate 100 random points in 3D space
np.random.seed(42)  # For reproducibility
points = np.random.rand(100, 3) * 10  # Scale points to be within a 10x10x10 cube

# Define point1 and point2 for the cylindrical coordinate system axis
point1 = [0, 0, 0]
point2 = [0, 0, 10]

# Sort points
sorted_cylindrical_points = sort_points(points, point1, point2)

# Generate and print new points along perpendicular lines
for point in sorted_cylindrical_points:
    # Convert cylindrical point to Cartesian for generating perpendicular points
    theta = point[0]
    r = point[1]
    z = point[2]
    original_point = np.array([r * np.cos(theta), r * np.sin(theta), z], dtype=float)
    
    perpendicular_points = generate_perpendicular_points(original_point, point1, point2, num_points=5)
    print(f"Original point: {original_point}")
    print("Perpendicular points:")
    for perp_point in perpendicular_points:
        print(f"  {perp_point}")

# Plot the original and sorted points
plot_points(points, point1, point2)
