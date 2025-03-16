import os

def create_root_folder(path):
    """
    Creates a root folder at the specified path if it does not already exist.

    :param path: The path where the root folder should be created.
    :return: The absolute path of the created or existing folder.
    """
    try:
        os.makedirs(path, exist_ok=True)
        # print(f"Folder created or already exists: {os.path.abspath(path)}")
        return os.path.abspath(path)
    except Exception as e:
        print(f"Error creating folder: {e}")
        return None

def create_nested_folders(base_path, subfolders):
    """
    Creates subfolders within a base folder.

    :param base_path: The base directory where subfolders should be created.
    :param subfolders: A list of subfolder names to create inside the base directory.
    """
    for folder in subfolders:
        folder_path = os.path.join(base_path, folder)
        create_root_folder(folder_path)

def create_folders_from_list(base_path, folder_list):
    """
    Creates multiple folders from a given list.

    :param base_path: The base directory where folders should be created.
    :param folder_list: A list of folder names to create inside the base directory.
    """
    for folder in folder_list:
        folder_path = os.path.join(base_path, folder)
        create_root_folder(folder_path)

# Example usage
if __name__ == "__main__":
    project_root = r"C:\Users\TechnoStar\Documents\New_task_EHD\Tool\_FEMFAT_WEB"
    folder_layer_1 = ["fatigue"]
    folder_layer_2 = ["dma", "ffj", "fps", "henni", "mat", "pro", 
                      "web1_j", "web2_j", "web3_j", "web4_j", "web5_j", "web6_j", 
                      "web1_p", "web2_p", "web3_p", "web4_p", "web5_p", "web6_p"]
    folder_layer_3 = ["1000rpm", "2000rpm", "3000rpm", "4000rpm", "5000rpm", "6000rpm"]

    # Create first layer (fatigue)
    base_layer_1_path = os.path.join(project_root, folder_layer_1[0])
    create_root_folder(base_layer_1_path)

    # Create second layer (dma, ffj, etc.) inside 'fatigue'
    create_folders_from_list(base_layer_1_path, folder_layer_2)

    # Create third layer (1000rpm, 2000rpm, etc.) inside 'henni' folder
    henni_folder_path = os.path.join(base_layer_1_path, "henni")
    create_folders_from_list(henni_folder_path, folder_layer_3)
