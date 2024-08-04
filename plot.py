import numpy as np
import matplotlib.pyplot as plt
from mpl_toolkits.mplot3d import Axes3D
import random

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

def inverse_rotate(points, axis_vector):
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
            [c + ux**2 * (1 - c),     uy * ux * (1 - c) + uz * s, uz * ux * (1 - c) - uy * s],
            [ux * uy * (1 - c) - uz * s, c + uy**2 * (1 - c),     uz * uy * (1 - c) + ux * s],
            [ux * uz * (1 - c) + uy * s, uy * uz * (1 - c) - ux * s, c + uz**2 * (1 - c)]
        ])
    else:
        R = np.eye(3)

    return np.dot(points, R.T)

def cartesian_to_cylindrical(points):
    x, y, z = points[:, 0], points[:, 1], points[:, 2]
    r = np.sqrt(x**2 + y**2)
    theta = np.arctan2(y, x)
    return np.stack((theta, r, z), axis=-1)

def cylindrical_to_cartesian(cylindrical_points):
    theta, r, z = cylindrical_points[:, 0], cylindrical_points[:, 1], cylindrical_points[:, 2]
    x = r * np.cos(theta)
    y = r * np.sin(theta)
    return np.stack((x, y, z), axis=-1)

def change_to_cylindrical(points, point1, point2):
    points = np.array(points, dtype=float)
    point1 = np.array(point1, dtype=float)
    point2 = np.array(point2, dtype=float)
    
    translation_vector = point2
    axis_vector = point1 - point2
    
    translated_points = translate(points, translation_vector)
    rotated_points = rotate(translated_points, axis_vector)
    cylindrical_points = cartesian_to_cylindrical(rotated_points)
    
    return cylindrical_points

def change_to_cartesian(points, point1, point2):
    points = np.array(points, dtype=float)
    point1 = np.array(point1, dtype=float)
    point2 = np.array(point2, dtype=float)
    
    axis_vector = point1 - point2
    rotated_points = inverse_rotate(points, axis_vector)
    translated_points = translate(rotated_points, -point2)
    
    return translated_points

def draw_points_cartesian(points, ax, color='b', label='Cartesian'):
    points = np.array(points)
    ax.scatter(points[:, 0], points[:, 1], points[:, 2], c=color, label=label)

def draw_points_cylindrical(points, ax, color='r', label='Cylindrical'):
    points = np.array(points)
    x = points[:, 1] * np.cos(points[:, 0])
    y = points[:, 1] * np.sin(points[:, 0])
    z = points[:, 2]
    ax.scatter(x, y, z, c=color, label=label)

def find_perpendicular_projection(point, line_start, line_end):
    line_vector = line_end - line_start
    point_vector = point - line_start
    line_unit_vector = line_vector / np.linalg.norm(line_vector)
    projection_length = np.dot(point_vector, line_unit_vector)
    projection_point = line_start + projection_length * line_unit_vector
    return projection_point
############################################################################################
def group_and_sort_points(cylindrical_points, tolerance=0.1):
    z = cylindrical_points[:, 2]
    groups = []
    
    while len(z) > 0:
        group_mask = np.abs(z - z[0]) <= tolerance
        group = cylindrical_points[group_mask]
        groups.append(group)
        cylindrical_points = cylindrical_points[~group_mask]
        z = cylindrical_points[:, 2]
    
    # Sort groups by z and within each group by theta
    sorted_groups = [group[np.argsort(group[:, 0])].tolist() for group in sorted(groups, key=lambda g: g[0, 2])]
    
    return sorted_groups

def generate_new_ids(base_id, num_points):
    return [base_id + i for i in range(1, num_points + 1)]

def assign_ids_to_points(sorted_groups, fractions):
    result = []
    
    for group_index, group in enumerate(sorted_groups):
        group_id = str(group_index + 1).zfill(2)  # Group ID (1-based index, zero-padded to 2 digits)
        
        for point_index, point in enumerate(group):
            theta_index = str(point_index + 1).zfill(3)  # Theta index (1-based index, zero-padded to 3 digits)
            base_point_id = f"10{group_id}{theta_index}00"
            
            # Assign IDs for the original points
            result.append((base_point_id, point))
            
            # Assign IDs for new points based on fractions
            for frac_index, fraction in enumerate(fractions):
                new_point_id = f"10{group_id}{theta_index}{str(frac_index + 1).zfill(2)}"
                # Generate new coordinates based on the fraction
                new_point = np.array(point)
                new_point[1] *= fraction  # Modify the radius for cylindrical coordinates
                
                # Convert to cylindrical, apply fraction, and convert back to Cartesian
                new_cylindrical = np.copy(cylindrical_points[np.where(cylindrical_points[:, 0] == point[0])[0]])
                new_cylindrical[:, 1] *= fraction
                new_cartesian = cylindrical_to_cartesian(new_cylindrical)
                new_cartesian = change_to_cartesian(new_cartesian, point1, point2)
                
                # Use the updated coordinates
                result.append((new_point_id, new_cartesian[0]))  # Append the first new point
                
    return result
############################################################################################
def plot_points(points, point1, point2, fractions):
    fig = plt.figure()
    ax = fig.add_subplot(111, projection='3d')
    
    # Draw Cartesian points
    draw_points_cartesian(points, ax, color='b', label='Cartesian')
    
    # Convert to cylindrical and draw cylindrical points
    cylindrical_points = change_to_cylindrical(points, point1, point2)
    # draw_points_cylindrical(cylindrical_points, ax, color='r', label='Cylindrical')
    
    # Draw axis line
    ax.plot([point1[0], point2[0]], [point1[1], point2[1]], [point1[2], point2[2]], 'g-', label='Axis')
    
    # Determine colors for each fraction
    n = len(fractions)
    colors = ['y', 'm', 'c', 'r', 'g']
    if n > len(colors):
        chosen_colors = [random.choice(colors) for _ in range(n)]
    else:
        chosen_colors = random.sample(colors, n)
    
    all_new_points = []
    for i, fraction in enumerate(fractions):
        new_points = []
        for point in points:
            projection_point = find_perpendicular_projection(point, point1, point2)
            new_point = point + fraction * (projection_point - point)
            new_points.append(new_point)
        new_points = np.array(new_points)
        all_new_points.append(new_points)
        draw_points_cartesian(new_points, ax, color=chosen_colors[i], label=f'New Points (fraction={fraction})')
    
    ax.set_xlabel('X')
    ax.set_ylabel('Y')
    ax.set_zlabel('Z')
    ax.legend()
    plt.show()
    
    return cylindrical_points, all_new_points

# Example usage
# points = np.array([[10, 0, 0], [-10, 0, 0]])
point1 = np.array([0, 0, 0])
point2 = np.array([0, 10, 0])
fractions = [0, 0.1, 0.2, 0.5]  # List of fractions

# # Plot points
# cylindrical_points, all_new_points = plot_points(points, point1, point2, fractions)
# print("Cylindrical coordinates:\n", cylindrical_points)
# for i, new_points in enumerate(all_new_points):
#     print(f"New points in Cartesian coordinates for fraction {fractions[i]}:\n", new_points)

# print(all_new_points)
points = [[0,0,-10],[0,5,-10],[7.04416,0,-7.04416],[7.04416,5,-7.04416],[10,5,0],[0,10,-10],[7.04416,10,-7.04416],[10,10,0],[-7.04416,5,7.04416],[7.04416,0,7.04416],[10,0,0],[-7.04416,10,7.04416],[7.04416,5,7.04416],[7.04416,10,7.04416],[0,5,10],[0,0,10],[0,10,10],[-7.04416,5,-7.04416],[-7.04416,10,-7.04416],[-7.04416,0,-7.04416],[-10,5,0],[-10,10,0],[-10,0,0],[-7.04416,0,7.04416]]


# cylindrical_points, new_points_cartesian = plot_points(points, point1, point2, fractions)
# sorted_groups = group_and_sort_points(cylindrical_points)
# id_points = assign_ids_to_points(sorted_groups, fractions)

def create_id_list(id_points):
    count = 0
    id_list = []
    for id_point in id_points:
        if count%(len(fractions)+1) != 0:
            point_id, coordinates = id_point
            x, y, z = coordinates
            id_list.append([int(point_id), float(x), float(y), float(z)])
        count += 1        
    return id_list
def interleave_sublists(original_list, n):
    # Calculate the number of sublists
    k = len(original_list) // n

    # Split the original list into k sublists
    sublists = [original_list[i*n:(i+1)*n] for i in range(k)]
    
    # Handle the case where the original list is not a multiple of n
    if len(original_list) % n != 0:
        sublists.append(original_list[k*n:])
    
    # Create the interleaved list
    interleaved_list = []
    for i in range(len(sublists) - 1):
        for j in range(len(sublists[i])):
            interleaved_list.append(sublists[i][j]+ sublists[i+1][j])
            # interleaved_list.append()
    
    return interleaved_list



# id_list = create_id_list(id_points)



cylindrical_points, new_points_cartesian = plot_points(points, point1, point2, fractions)
sorted_groups = group_and_sort_points(cylindrical_points)
id_points = assign_ids_to_points(sorted_groups, fractions)
id_list = create_id_list(id_points)


# Print the resulting list
for entry in id_list:
    print(entry)



el_list_r = []
el_list_theta = []
el_list_z = []

z = 3
theta = 6
r = 4


# print(len(id_list))
for i in range(-1, len(id_list)-1):
    if str(id_list[i][0])[6] == str(id_list[i+1][0])[6]:
        el_list_r.append([id_list[i][0], id_list[i+1][0]]) 
# for i in range(0, len(el_list_r)):
#     print(el_list_r[i])
#     print(el_list_r[i + r-1])
#     # print(el_list_r[len(el_list_r)/r)
#     # el_list_theta.append([el_list_r[i] + el_list_r[i+i*len(el_list_r)/r]]) 


group_size_z = theta*(r-1)
list_z = [el_list_r[i:i + group_size_z] for i in range(0, len(el_list_r), group_size_z)]

group_size = r-1
for list in list_z:
    grouped_lists = [list[i:i + group_size] for i in range(0, len(list), group_size)]

    # Create the new list of pairs
    new_list = []
    for i in range(len(grouped_lists) - 1):
        for j in range(group_size):
            new_list.append(grouped_lists[i][j] + grouped_lists[i + 1][j])
            # new_list.append()

    # Add the last group and connect it to the first
    for j in range(group_size):
        new_list.append(grouped_lists[-1][j] + grouped_lists[i + 1][j])
        # new_list.append(grouped_lists[0][j])

    # Print the result
    for pair in new_list:
        el_list_z.append(pair)

el_list_z_convert = []
for list in el_list_z:
    el_list_z_convert.append([list[0],list[3],list[1],list[2]])

print("xxxxxxxx")

el_solid = interleave_sublists(el_list_z_convert, group_size_z)

result = []
count = 0
for list in el_solid:
    result.append([count] + list)
    count += 1

for i in result:
    print(i)
