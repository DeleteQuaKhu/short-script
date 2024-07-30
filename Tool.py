import numpy as np
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

def plot_points(points, point1, point2, fractions):
    cylindrical_points = change_to_cylindrical(points, point1, point2)
    
    new_points_cartesian = []
    count = 0
    for i, fraction in enumerate(fractions):
        if count < 2:
            new_points_cylindrical = cylindrical_points.copy()
            new_points_cylindrical[:, 1] = new_points_cylindrical[:, 1] - fraction
            new_points_cartesian_temp = cylindrical_to_cartesian(new_points_cylindrical)
            new_points_cartesian_temp = change_to_cartesian(new_points_cartesian_temp, point1, point2)
            new_points_cartesian.extend(new_points_cartesian_temp)
        else:
            # Calculate and draw new points
            new_points_cylindrical = cylindrical_points.copy()
            new_points_cylindrical[:, 1] *= fraction  # Adjust the radius by the given fraction
            new_points_cartesian_temp = cylindrical_to_cartesian(new_points_cylindrical)
            new_points_cartesian_temp = change_to_cartesian(new_points_cartesian_temp, point1, point2)
            new_points_cartesian.extend(new_points_cartesian_temp)
        count += 1
    
    return cylindrical_points, new_points_cartesian

# Example usage
point1 = [0, 0, 0]
point2 = [0, 10, 0]
points = [[-3.567636,0,9.328176],[-9.848078,0,1.736482],[9.890612,0,-1.250311],[6.161364,0,7.847059],[-19.717422,20,3.229878],[-6.29462,0,-7.753751],[3.71507,0,-9.259427],[19.759957,10,-2.743708],[19.759957,20,-2.743708],[12.389355,20,15.647464],[12.389355,10,15.647464],[-7.208989,20,18.621978],[-7.208989,10,18.621978],[-19.717422,10,3.229878],[-12.522611,20,-15.554157],[-12.522611,10,-15.554157],[7.356423,20,-18.553228],[7.356423,10,-18.553228]]

fractions = [1, 2, 0.3, 0.4]

cylindrical_points, new_points_cartesian = plot_points(points, point1, point2, fractions)
sorted_groups = group_and_sort_points(cylindrical_points)
id_points = assign_ids_to_points(sorted_groups, fractions)

def create_id_list(id_points):
    id_list = []
    for id_point in id_points:
        point_id, coordinates = id_point
        x, y, z = coordinates
        id_list.append([int(point_id), float(x), float(y), float(z)])
    return id_list

id_list = create_id_list(id_points)

# Print the resulting list
# for entry in id_list:
#     print(entry)

el_list_r = []
el_list_theta = []
z = 3
theta = 6
count = 0
r = 5
# print(len(id_list))
for i in range(-1, len(id_list)-1):
    if str(id_list[i][0])[6] == str(id_list[i+1][0])[6]:
        el_list_r.append([id_list[i][0], id_list[i+1][0]]) 
for i in range(0, len(el_list_r)):
    print(el_list_r[i])
    print(el_list_r[i + r-1])
    # print(el_list_r[len(el_list_r)/r)
    # el_list_theta.append([el_list_r[i] + el_list_r[i+i*len(el_list_r)/r]]) 
print("xxxxxxxx")
for i in el_list_r:
    print(i)
# print(el_list)


