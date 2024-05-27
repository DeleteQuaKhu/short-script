import pandas as pd

def print_sheets_starting_with(excel_file, prefix):
    xls = pd.ExcelFile(excel_file)
    
    for sheet in xls.sheet_names:
        if sheet.startswith(prefix):
            print(sheet)

excel_file = r"C:\Users\TechnoStar\Documents\macro\save png\1234 - Copy.xlsx"
print_sheets_starting_with(excel_file, '1500')
