import pandas as pd
import os
import re
from pathlib import Path

def read_gid_data(gid_file_path, delimiter=' ', start_line=26, column_indices=[1,2]):
    """
    Read data from .gid file without writing to Excel.
    """
    skip_rows = max(0, start_line - 1)

    try:
        df = pd.read_csv(
            gid_file_path,
            sep='\s+',
            engine='python',
            skiprows=skip_rows,
            header=None,
            comment='!',
            on_bad_lines='skip',
            skip_blank_lines=True,
        )
    except Exception as e:
        print(f"Warning: primary read_csv failed for {gid_file_path}: {e}")
        df = pd.read_csv(
            gid_file_path,
            delimiter=delimiter,
            engine='python',
            skiprows=skip_rows,
            header=None,
            skipinitialspace=True,
            comment='!',
            on_bad_lines='skip',
            skip_blank_lines=True,
        )

    if df.empty:
        return pd.DataFrame()

    # Extract specified columns
    if df.shape[1] <= max(column_indices):
        col_indices = [i for i in column_indices if i < df.shape[1]]
    else:
        col_indices = column_indices

    result_df = df.iloc[:, col_indices].copy()
    result_df.columns = ['col_' + str(i) for i in range(len(col_indices))]

    return result_df
    """
    Extract data from .gid file (start_line to end) and write to Excel.
    
    Parameters:
    -----------
    gid_file_path : str
        Path to the .gid file
    output_excel_path : str, optional
        Output Excel file path. If None, saves to output.xlsx in current directory
    delimiter : str, optional
        Delimiter used in .gid file (default: space)
    sheet_merge : bool, optional
        If True, append to existing sheet; if False, create/overwrite (default: True)
    start_line : int, optional
        Starting line (1-indexed) to read from GID file (default: 26)
    
    Returns:
    --------
    pd.DataFrame
        DataFrame with extracted columns (crank_angle, result)
    """
    
    # Get file info
    gid_path = Path(gid_file_path)
    gid_name = gid_path.stem  # filename without extension
    folder_name = gid_path.parent.name  # parent folder name
    
    if output_excel_path is None:
        output_excel_path = 'output.xlsx'
    
    output_excel_path = Path(output_excel_path)
    
    # Read .gid file starting from provided line
    # skiprows is 0-indexed, so skip (start_line - 1) lines
    skip_rows = max(0, start_line - 1)

    try:
        df = pd.read_csv(
            gid_file_path,
            sep='\s+',
            engine='python',
            skiprows=skip_rows,
            header=None,
            comment='!',
            on_bad_lines='skip',
            skip_blank_lines=True,
        )
    except Exception as e:
        print(f"Warning: primary read_csv failed for {gid_file_path}: {e}")
        print("Retrying with fallback settings")
        df = pd.read_csv(
            gid_file_path,
            delimiter=delimiter,
            engine='python',
            skiprows=skip_rows,
            header=None,
            skipinitialspace=True,
            comment='!',
            on_bad_lines='skip',
            skip_blank_lines=True,
        )

    print(f"Debug: {gid_file_path} - start_line {start_line}, skip_rows {skip_rows}, df.shape {df.shape}")
    if not df.empty:
        print(f"Debug: First 3 rows of {gid_file_path}:")
        print(df.head(3))
    if df.empty:
        print(f"Warning: {gid_file_path} resulted in empty DataFrame after reading")
        return pd.DataFrame(columns=['crank_angle', 'result'])
    
    # Extract specified columns
    if df.shape[1] <= max(column_indices):
        print(f"Warning: {gid_file_path} has only {df.shape[1]} columns, requested max index {max(column_indices)}. Using available columns.")
        col_indices = [i for i in column_indices if i < df.shape[1]]
    else:
        col_indices = column_indices
    
    result_df = df.iloc[:, col_indices].copy()
    result_df.columns = ['crank_angle', 'result'][:len(col_indices)]
    
    # Include all rows starting from line 26
    
    # Write to Excel
    if sheet_merge and output_excel_path.exists():
        # Append to existing file with new sheet
        with pd.ExcelWriter(output_excel_path, engine='openpyxl', mode='a', if_sheet_exists='replace') as writer:
            result_df.to_excel(writer, sheet_name=re.split(r'[-_]', gid_name)[-1], index=False, header=False)
    else:
        # Create new Excel file
        with pd.ExcelWriter(output_excel_path, engine='openpyxl') as writer:
            result_df.to_excel(writer, sheet_name=re.split(r'[-_]', gid_name)[-1], index=False, header=False)
    
    print(f"✓ Written to {output_excel_path} | Sheet: {re.split(r'[-_]', gid_name)[-1]} | Rows: {len(result_df)}")
    
    return result_df


def process_multiple_gid_files(directory_path, output_excel_path=None, delimiter=' ', pattern='*.gid'):
    """
    Process multiple .gid files from a directory and combine into one Excel file.
    
    Parameters:
    -----------
    directory_path : str
        Directory containing .gid files
    output_excel_path : str, optional
        Output Excel file path
    delimiter : str, optional
        Delimiter in .gid files
    pattern : str, optional
        File pattern to search (default: '*.gid')
    """
    
    directory = Path(directory_path)
    gid_files = list(directory.glob(pattern))
    
    if not gid_files:
        print(f"No .gid files found in {directory_path}")
        return
    
    if output_excel_path is None:
        output_excel_path = directory / 'output.xlsx'
    
    print(f"Found {len(gid_files)} .gid file(s). Processing...")
    
    for gid_file in gid_files:
        gid_to_excel(gid_file, output_excel_path, delimiter=delimiter, sheet_merge=True)


# Example usage:
if __name__ == "__main__":
    # Read config from info.f file in the same directory as this script
    info_file = os.path.join(os.path.dirname(__file__), 'info.f')
    if not os.path.exists(info_file):
        print(f"info.f file not found. Please create {info_file} with required fields")
        exit(1)

    config = {}
    with open(info_file, 'r') as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            if ':' not in line:
                continue
            key, value = line.split(':', 1)
            key = key.strip()
            value = value.strip().strip('"').strip("'")
            config[key] = value

    Excite_path = config.get('Excite_path')
    case_set = config.get('case_set')
    speed_value = config.get('speed')
    list_gid = config.get('List_GID_file_name')
    excel_path = config.get('excel_path')
    start_line_value = config.get('START_LINE', '26')

    if not Excite_path or not case_set or not speed_value or not list_gid or not excel_path:
        print("info.f must include Excite_path, case_set, speed, List_GID_file_name, and excel_path")
        exit(1)

    # Parse speed as list
    try:
        speed = eval(speed_value) if isinstance(speed_value, str) else speed_value
        if not isinstance(speed, list):
            speed = [speed]
    except Exception:
        print("speed must be a list of integers, e.g. [6000,7000]")
        exit(1)

    # Parse list_gid as list
    try:
        list_gid = eval(list_gid)
        if not isinstance(list_gid, list):
            raise ValueError
    except Exception:
        print("List_GID_file_name must be a Python list string, e.g. [\"PTOT.GID\", \"PASP.GID\"]")
        exit(1)

    # Parse START_LINE as int or list
    try:
        start_line_parsed = eval(start_line_value) if isinstance(start_line_value, str) else start_line_value
        if isinstance(start_line_parsed, list):
            start_line = [int(x) for x in start_line_parsed]
        else:
            start_line = int(start_line_parsed)
    except Exception:
        print("START_LINE must be an integer or a list of integers, e.g. 26 or [26, 27]")
        exit(1)

    print(f"Excite path: {Excite_path}")
    print(f"Case set: {case_set}")
    print(f"Speeds: {speed}")
    print(f"GID files: {list_gid}")
    print(f"Excel path: {excel_path}")
    print(f"Start line(s): {start_line}")

    # Process for each speed
    data_dict = {}  # key: gid_file, value: dict of speed to df

    for spd in speed:
        folder_path = os.path.join(Excite_path, f"{case_set}.{spd}rpm", "results")
        print(f"Processing speed {spd}rpm from {folder_path}")

        for i, gid_file in enumerate(list_gid):
            gid_full_path = os.path.join(folder_path, gid_file)
            current_start_line = start_line[i] if isinstance(start_line, list) else start_line

            # Determine columns based on speed order
            if spd == speed[0]:  # First speed provides crank_angle and result
                col_indices = [1, 2]  # columns 2 and 3 (0-indexed)
            else:  # Subsequent speeds only provide result
                col_indices = [2]  # column 3

            try:
                df = read_gid_data(gid_full_path, delimiter=' ', start_line=current_start_line, column_indices=col_indices)
                if gid_file not in data_dict:
                    data_dict[gid_file] = {}
                data_dict[gid_file][spd] = df
                print(f"Loaded {gid_file} for {spd}rpm: {len(df)} rows")
            except Exception as e:
                print(f"Error processing {gid_full_path}: {e}")
                continue

    # Now write to Excel
    with pd.ExcelWriter(excel_path, engine='openpyxl') as writer:
        for gid_file, speed_data in data_dict.items():
            sheet_name = re.split(r'[-_]', Path(gid_file).stem)[-1]
            combined_df = pd.DataFrame()

            # Sort speeds to ensure consistent order
            sorted_speeds = sorted(speed_data.keys())

            for idx, spd in enumerate(sorted_speeds):
                df_spd = speed_data[spd]
                if idx == 0:  # First speed provides crank_angle
                    if len(df_spd.columns) > 0:
                        combined_df['crank_angle'] = df_spd.iloc[:, 0]
                    if len(df_spd.columns) > 1:
                        combined_df[f'result_{spd}'] = df_spd.iloc[:, 1]
                    else:
                        combined_df[f'result_{spd}'] = df_spd.iloc[:, 0]
                else:  # Subsequent speeds only provide result
                    if len(df_spd.columns) > 0:
                        combined_df[f'result_{spd}'] = df_spd.iloc[:, 0]

            combined_df.to_excel(writer, sheet_name=sheet_name, index=False)
            print(f"Written {sheet_name} to {excel_path}")

    print("Processing complete.")