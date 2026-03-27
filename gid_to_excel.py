import pandas as pd
import os
from pathlib import Path

def gid_to_excel(gid_file_path, output_excel_path=None, delimiter=' ', sheet_merge=True):
    """
    Extract data from .gid file (line 41 to end) and write to Excel.
    
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
    
    # Read .gid file starting from line 26 (0-indexed: line 25)
    # Skip first 25 lines, then read
    df = pd.read_csv(
        gid_file_path,
        delimiter=delimiter,
        skiprows=25,  # Skip first 25 lines (0-24), start from line 26
        header=None,
        skipinitialspace=True
    )
    
    # Extract columns 2 and 3 (0-indexed: columns 2 and 3)
    result_df = df.iloc[:, [2, 3]].copy()
    result_df.columns = ['crank_angle', 'result']
    
    # Add index as folder name
    result_df.insert(0, 'index', folder_name)
    
    # Write to Excel
    if sheet_merge and output_excel_path.exists():
        # Append to existing file with new sheet
        with pd.ExcelWriter(output_excel_path, engine='openpyxl', mode='a', if_sheet_exists='replace') as writer:
            result_df.to_excel(writer, sheet_name=gid_name, index=False)
    else:
        # Create new Excel file
        with pd.ExcelWriter(output_excel_path, engine='openpyxl') as writer:
            result_df.to_excel(writer, sheet_name=gid_name, index=False)
    
    print(f"✓ Written to {output_excel_path} | Sheet: {gid_name} | Rows: {len(result_df)}")
    
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
    # Single file example:
    # gid_to_excel('path/to/file.gid', 'output.xlsx', delimiter=' ')
    
    # Multiple files example:
    # process_multiple_gid_files('path/to/gid/folder', 'combined_output.xlsx', delimiter=' ')
    
    print("gid_to_excel module loaded. Use functions:")
    print("  - gid_to_excel(gid_file_path, output_excel, delimiter, sheet_merge)")
    print("  - process_multiple_gid_files(directory, output_excel, delimiter, pattern)")
