
##_# streamlit_to_ppt


import streamlit as st
import pandas as pd
from pptx import Presentation
from pptx.util import Inches, Pt
from pptx.enum.text import PP_ALIGN
from pptx.dml.color import RGBColor
import io
import re
from PIL import Image
import tempfile
import os

def detect_placeholders(prs):
    """Detect all placeholders in the PowerPoint presentation"""
    placeholders = {
        'text': set(),
        'image': set(), 
        'table': set()
    }
    
    # Regex pattern to find placeholders
    pattern = r'\{\{([^}]+)\}\}'
    
    for slide in prs.slides:
        for shape in slide.shapes:
            # Check text in shapes
            if hasattr(shape, "text") and shape.text:
                matches = re.findall(pattern, shape.text)
                for match in matches:
                    placeholder = match.upper().strip()
                    if placeholder.startswith('IMAGE'):
                        placeholders['image'].add(placeholder)
                    elif placeholder.startswith('TABLE'):
                        placeholders['table'].add(placeholder)
                    else:
                        placeholders['text'].add(placeholder)
            
            # Check text in table cells
            if shape.has_table:
                table = shape.table
                for row in table.rows:
                    for cell in row.cells:
                        if cell.text:
                            matches = re.findall(pattern, cell.text)
                            for match in matches:
                                placeholder = match.upper().strip()
                                if placeholder.startswith('IMAGE'):
                                    placeholders['image'].add(placeholder)
                                elif placeholder.startswith('TABLE'):
                                    placeholders['table'].add(placeholder)
                                else:
                                    placeholders['text'].add(placeholder)
    
    return placeholders

def replace_text_in_slides(prs, replacements):
    """Replace placeholder text in all slides"""
    for slide in prs.slides:
        for shape in slide.shapes:
            if hasattr(shape, "text"):
                for placeholder, replacement in replacements.items():
                    if placeholder in shape.text:
                        shape.text = shape.text.replace(placeholder, str(replacement))
            
            # Handle text in tables
            if shape.has_table:
                table = shape.table
                for row in table.rows:
                    for cell in row.cells:
                        for placeholder, replacement in replacements.items():
                            if placeholder in cell.text:
                                cell.text = cell.text.replace(placeholder, str(replacement))

def add_image_to_slide(slide, image_file, placeholder_text, width=Inches(4), height=Inches(3)):
    """Add image to slide, replacing placeholder or adding new"""
    # Reset file pointer and read data
    image_file.seek(0)
    image_data = image_file.read()
    
    # Save uploaded image to temporary file
    with tempfile.NamedTemporaryFile(delete=False, suffix='.png') as tmp_file:
        tmp_file.write(image_data)
        tmp_path = tmp_file.name
    
    try:
        # Look for placeholder text in shapes
        placeholder_found = False
        for shape in slide.shapes:
            if hasattr(shape, "text") and placeholder_text in shape.text:
                # Get position and size of placeholder
                left = shape.left
                top = shape.top
                width = shape.width
                height = shape.height
                
                # Remove placeholder shape
                shape.element.getparent().remove(shape.element)
                
                # Add image at same position
                slide.shapes.add_picture(tmp_path, left, top, width, height)
                placeholder_found = True
                break
        
        # If no placeholder found, add image at default position
        if not placeholder_found:
            slide.shapes.add_picture(tmp_path, Inches(1), Inches(1), width, height)
            
    finally:
        # Clean up temporary file
        if os.path.exists(tmp_path):
            os.unlink(tmp_path)

def add_table_to_slide(slide, df, placeholder_text):
    """Add DataFrame as table to slide"""
    # Look for placeholder
    placeholder_shape = None
    for shape in slide.shapes:
        if hasattr(shape, "text") and placeholder_text in shape.text:
            placeholder_shape = shape
            break
    
    if placeholder_shape:
        # Get position of placeholder
        left = placeholder_shape.left
        top = placeholder_shape.top
        width = placeholder_shape.width
        
        # Remove placeholder
        placeholder_shape.element.getparent().remove(placeholder_shape.element)
    else:
        # Default position
        left = Inches(1)
        top = Inches(4)
        width = Inches(8)
    
    # Create table
    rows, cols = df.shape[0] + 1, df.shape[1]  # +1 for header
    table_shape = slide.shapes.add_table(rows, cols, left, top, width, Inches(0.5 * rows))
    table = table_shape.table
    
    # Add headers
    for i, col_name in enumerate(df.columns):
        cell = table.cell(0, i)
        cell.text = str(col_name)
        # Make header bold
        for paragraph in cell.text_frame.paragraphs:
            for run in paragraph.runs:
                run.font.bold = True
    
    # Add data
    for i, row in df.iterrows():
        for j, value in enumerate(row):
            cell = table.cell(i + 1, j)
            cell.text = str(value)

def main():
    st.set_page_config(
        page_title="Excel to PowerPoint Template Filler",
        page_icon="📊",
        layout="wide"
    )
    
    st.title("📊 Excel to PowerPoint Template Filler")
    st.markdown("""
    **Transform your Excel data into PowerPoint presentations automatically!**
    
    This app lets you:
    - 📊 Upload Excel files and select specific data
    - 🎯 Create automated sequences for text and tables  
    - 📄 Upload PowerPoint templates with placeholders
    - 🚀 Generate populated presentations instantly
    """)
    
    # Initialize session state
    if 'excel_data' not in st.session_state:
        st.session_state.excel_data = {}
    if 'text_sequences' not in st.session_state:
        st.session_state.text_sequences = []
    if 'table_sequences' not in st.session_state:
        st.session_state.table_sequences = []
    
    # Step 1: Excel File Upload and Configuration
    st.header("📋 Step 1: Upload & Configure Excel Data")
    
    # Prominent call-to-action for Excel upload
    st.markdown("### 🔥 Start Here: Upload Your Excel File")
    st.markdown("*Upload your Excel file to unlock automatic data population features*")
    
    uploaded_excel = st.file_uploader(
        "Choose Excel File (.xlsx, .xls)",
        type=['xlsx', 'xls'],
        help="Upload an Excel file to extract data for PowerPoint placeholders",
        key="excel_uploader"
    )
    
    if uploaded_excel is not None:
        try:
            # Load Excel file
            excel_file = pd.ExcelFile(uploaded_excel)
            sheet_names = excel_file.sheet_names
            
            st.success(f"🎉 **Excel file loaded successfully!**")
            st.info(f"📊 Found **{len(sheet_names)} sheets**: {', '.join(sheet_names)}")
            
            # Sheet selection with better visibility
            st.markdown("### 📑 Select Sheets to Work With")
            selected_sheets = st.multiselect(
                "Choose which sheets contain the data you want to use:",
                sheet_names,
                default=sheet_names[:3] if len(sheet_names) >= 3 else sheet_names,
                help="Select one or more sheets that contain your data"
            )
            
            if selected_sheets:
                # Load data from selected sheets
                for sheet_name in selected_sheets:
                    if sheet_name not in st.session_state.excel_data:
                        st.session_state.excel_data[sheet_name] = pd.read_excel(uploaded_excel, sheet_name=sheet_name)
                
                # Data configuration interface
                st.subheader("🔧 Configure Data Sequences")
                st.markdown("Create sequences that will automatically populate your PowerPoint placeholders")
                
                tab1, tab2 = st.tabs(["📝 Text Sequences", "📊 Table Sequences"])
                
                with tab1:
                    st.markdown("**Text sequences will populate text placeholders ({{TEXT1}}, {{TEXT2}}, etc.) in order**")
                    
                    # Add new text sequence
                    with st.expander("➕ Add New Text Sequence"):
                        col1, col2, col3 = st.columns(3)
                        with col1:
                            text_sheet = st.selectbox("Select Sheet", selected_sheets, key="text_sheet")
                        with col2:
                            if text_sheet:
                                available_columns = list(st.session_state.excel_data[text_sheet].columns)
                                text_column = st.selectbox("Select Column", available_columns, key="text_column")
                        with col3:
                            text_row = st.number_input("Row Index (0-based)", min_value=0, 
                                                     max_value=len(st.session_state.excel_data[text_sheet])-1 if text_sheet else 0,
                                                     value=0, key="text_row")
                        
                        if st.button("Add Text Sequence", key="add_text"):
                            if text_sheet and text_column:
                                value = st.session_state.excel_data[text_sheet].iloc[text_row][text_column]
                                sequence_info = {
                                    'sheet': text_sheet,
                                    'column': text_column,
                                    'row': text_row,
                                    'value': str(value),
                                    'description': f"{text_sheet} - {text_column} [Row {text_row}]"
                                }
                                st.session_state.text_sequences.append(sequence_info)
                                st.success(f"Added text sequence: {sequence_info['description']}")
                                st.rerun()
                    
                    # Display and manage existing text sequences
                    if st.session_state.text_sequences:
                        st.markdown("**Current Text Sequences:**")
                        for i, seq in enumerate(st.session_state.text_sequences):
                            col1, col2, col3 = st.columns([3, 1, 1])
                            with col1:
                                st.write(f"**{{{{TEXT{i+1}}}}}** ← {seq['description']}: `{seq['value'][:50]}{'...' if len(seq['value']) > 50 else ''}`")
                            with col2:
                                if st.button("↑", key=f"up_text_{i}", disabled=i==0):
                                    st.session_state.text_sequences[i], st.session_state.text_sequences[i-1] = st.session_state.text_sequences[i-1], st.session_state.text_sequences[i]
                                    st.rerun()
                            with col3:
                                if st.button("🗑️", key=f"del_text_{i}"):
                                    st.session_state.text_sequences.pop(i)
                                    st.rerun()
                
                with tab2:
                    st.markdown("**Table sequences will populate table placeholders ({{TABLE1}}, {{TABLE2}}, etc.) in order**")
                    
                    # Add new table sequence
                    with st.expander("➕ Add New Table Sequence"):
                        col1, col2 = st.columns(2)
                        with col1:
                            table_sheet = st.selectbox("Select Sheet", selected_sheets, key="table_sheet")
                        with col2:
                            if table_sheet:
                                available_columns = list(st.session_state.excel_data[table_sheet].columns)
                                table_columns = st.multiselect(
                                    "Select Columns", 
                                    available_columns, 
                                    key="table_columns",
                                    help="Select multiple columns to create a table"
                                )
                        
                        table_rows = st.slider(
                            "Number of rows to include", 
                            min_value=1, 
                            max_value=len(st.session_state.excel_data[table_sheet]) if table_sheet else 10,
                            value=min(10, len(st.session_state.excel_data[table_sheet]) if table_sheet else 10),
                            key="table_rows"
                        )
                        
                        if st.button("Add Table Sequence", key="add_table"):
                            if table_sheet and table_columns:
                                df_subset = st.session_state.excel_data[table_sheet][table_columns].head(table_rows)
                                sequence_info = {
                                    'sheet': table_sheet,
                                    'columns': table_columns,
                                    'rows': table_rows,
                                    'data': df_subset,
                                    'description': f"{table_sheet} - {', '.join(table_columns)} ({table_rows} rows)"
                                }
                                st.session_state.table_sequences.append(sequence_info)
                                st.success(f"Added table sequence: {sequence_info['description']}")
                                st.rerun()
                    
                    # Display and manage existing table sequences
                    if st.session_state.table_sequences:
                        st.markdown("**Current Table Sequences:**")
                        for i, seq in enumerate(st.session_state.table_sequences):
                            with st.expander(f"**{{{{TABLE{i+1}}}}}** ← {seq['description']}"):
                                col1, col2 = st.columns([4, 1])
                                with col1:
                                    st.dataframe(seq['data'], use_container_width=True)
                                with col2:
                                    if st.button("↑", key=f"up_table_{i}", disabled=i==0):
                                        st.session_state.table_sequences[i], st.session_state.table_sequences[i-1] = st.session_state.table_sequences[i-1], st.session_state.table_sequences[i]
                                        st.rerun()
                                    if st.button("🗑️", key=f"del_table_{i}"):
                                        st.session_state.table_sequences.pop(i)
                                        st.rerun()
        
        except Exception as e:
            st.error(f"❌ Error loading Excel file: {str(e)}")
            st.error("Please make sure you uploaded a valid Excel file (.xlsx or .xls)")
    
    else:
        # Show prominent message when no Excel file is uploaded
        st.warning("⬆️ **Please upload an Excel file above to enable auto-population features**")
        
        with st.expander("💡 What happens when you upload Excel?", expanded=True):
            st.markdown("""
            **When you upload an Excel file, you'll be able to:**
            - 📊 **View all sheets** in your Excel file
            - 🎯 **Create text sequences** from individual cells (populates {{TEXT1}}, {{TEXT2}}, etc.)
            - 📋 **Create table sequences** from column groups (populates {{TABLE1}}, {{TABLE2}}, etc.)
            - 🔄 **Reorder sequences** to control the mapping
            - 🚀 **Auto-populate** your PowerPoint templates instantly
            
            **Without Excel:** You can still use manual input mode below ⬇️
            """)
        
        st.markdown("---")
    
    # Step 2: PowerPoint Template Processing
    st.header("📄 Step 2: PowerPoint Template Processing")
    st.markdown("**Upload your PowerPoint template to populate with Excel data or manual inputs**")
    
    uploaded_ppt = st.file_uploader(
        "📁 Upload PowerPoint Template (.pptx)",
        type=['pptx'],
        help="Upload a PowerPoint file with placeholder text like {{TEXT1}}, {{IMAGE1}}, {{TABLE1}}",
        key="ppt_uploader"
    )
    
    if uploaded_ppt is not None:
        try:
            # Load and analyze the PowerPoint file
            prs = Presentation(uploaded_ppt)
            placeholders = detect_placeholders(prs)
            
            st.success(f"✅ Template loaded! Found {len(placeholders['text'])} text, {len(placeholders['image'])} image, and {len(placeholders['table'])} table placeholders.")
            
            # Show detected placeholders
            with st.expander("🔍 Detected Placeholders"):
                col1, col2, col3 = st.columns(3)
                with col1:
                    st.write("**Text Placeholders:**")
                    for placeholder in sorted(placeholders['text']):
                        st.write(f"• {{{{{placeholder}}}}}")
                with col2:
                    st.write("**Image Placeholders:**")
                    for placeholder in sorted(placeholders['image']):
                        st.write(f"• {{{{{placeholder}}}}}")
                with col3:
                    st.write("**Table Placeholders:**")
                    for placeholder in sorted(placeholders['table']):
                        st.write(f"• {{{{{placeholder}}}}}")
            
            # Show mapping preview
            if st.session_state.text_sequences or st.session_state.table_sequences:
                st.success("🎯 **Auto-population is ACTIVE!** Your Excel data will automatically fill placeholders.")
                with st.expander("🔗 Auto-Population Mapping Preview", expanded=True):
                    col1, col2 = st.columns(2)
                    
                    with col1:
                        st.write("**Text Mapping:**")
                        for i, seq in enumerate(st.session_state.text_sequences):
                            placeholder_name = f"TEXT{i+1}"
                            if placeholder_name in [p for p in placeholders['text']]:
                                st.write(f"✅ {{{{{placeholder_name}}}}} ← {seq['description']}")
                            else:
                                st.write(f"⚠️ {{{{{placeholder_name}}}}} ← {seq['description']} (placeholder not found)")
                    
                    with col2:
                        st.write("**Table Mapping:**")
                        for i, seq in enumerate(st.session_state.table_sequences):
                            placeholder_name = f"TABLE{i+1}"
                            if placeholder_name in [p for p in placeholders['table']]:
                                st.write(f"✅ {{{{{placeholder_name}}}}} ← {seq['description']}")
                            else:
                                st.write(f"⚠️ {{{{{placeholder_name}}}}} ← {seq['description']} (placeholder not found)")
            
            # Manual inputs for remaining placeholders
            remaining_text_placeholders = [p for p in placeholders['text'] if not any(f"TEXT{i+1}" == p for i in range(len(st.session_state.text_sequences)))]
            remaining_table_placeholders = [p for p in placeholders['table'] if not any(f"TABLE{i+1}" == p for i in range(len(st.session_state.table_sequences)))]
            
            if remaining_text_placeholders or remaining_table_placeholders or placeholders['image']:
                st.subheader("✍️ Manual Inputs for Remaining Placeholders")
                
                col1, col2 = st.columns(2)
                
                with col1:
                    # Remaining text inputs
                    if remaining_text_placeholders:
                        st.write("**Additional Text Inputs:**")
                        manual_text_inputs = {}
                        for placeholder in sorted(remaining_text_placeholders):
                            placeholder_key = f"{{{{{placeholder}}}}}"
                            manual_text_inputs[placeholder_key] = st.text_area(
                                f"{placeholder} (replaces {placeholder_key})",
                                height=80,
                                key=f"manual_text_{placeholder}"
                            )
                    
                    # Image inputs
                    if placeholders['image']:
                        st.write("**Image Uploads:**")
                        uploaded_images = {}
                        for placeholder in sorted(placeholders['image']):
                            placeholder_key = f"{{{{{placeholder}}}}}"
                            uploaded_images[placeholder] = st.file_uploader(
                                f"{placeholder} (replaces {placeholder_key})",
                                type=['png', 'jpg', 'jpeg'],
                                key=f"image_{placeholder}"
                            )
                            
                            if uploaded_images[placeholder] is not None:
                                img = Image.open(uploaded_images[placeholder])
                                st.image(img, caption=f"Preview of {placeholder}", width=200)
                
                with col2:
                    # Remaining table inputs
                    if remaining_table_placeholders:
                        st.write("**Additional Table Inputs:**")
                        manual_tables_data = {}
                        for placeholder in sorted(remaining_table_placeholders):
                            placeholder_key = f"{{{{{placeholder}}}}}"
                            st.write(f"**{placeholder} (replaces {placeholder_key})**")
                            
                            # Default sample data
                            if f"manual_df_{placeholder}" not in st.session_state:
                                st.session_state[f"manual_df_{placeholder}"] = pd.DataFrame({
                                    'Column 1': ['Row 1', 'Row 2', 'Row 3'],
                                    'Column 2': [100, 200, 300]
                                })
                            
                            manual_tables_data[placeholder] = st.data_editor(
                                st.session_state[f"manual_df_{placeholder}"],
                                key=f"manual_table_{placeholder}",
                                num_rows="dynamic",
                                use_container_width=True
                            )
            
            # Generate PowerPoint button
            generation_label = "🚀 Generate PowerPoint with Auto-Population" if (st.session_state.text_sequences or st.session_state.table_sequences) else "🚀 Generate PowerPoint (Manual Mode)"
            
            if st.button(generation_label, type="primary", use_container_width=True):
                try:
                    # Reload the PowerPoint file
                    prs = Presentation(uploaded_ppt)
                    
                    # Auto-populate text placeholders from sequences
                    text_replacements = {}
                    for i, seq in enumerate(st.session_state.text_sequences):
                        placeholder_key = f"{{{{TEXT{i+1}}}}}"
                        text_replacements[placeholder_key] = seq['value']
                    
                    # Add manual text inputs
                    if remaining_text_placeholders:
                        for placeholder in remaining_text_placeholders:
                            placeholder_key = f"{{{{{placeholder}}}}}"
                            if placeholder_key in manual_text_inputs and manual_text_inputs[placeholder_key].strip():
                                text_replacements[placeholder_key] = manual_text_inputs[placeholder_key]
                    
                    # Replace text placeholders
                    if text_replacements:
                        replace_text_in_slides(prs, text_replacements)
                        st.success(f"✅ Replaced {len(text_replacements)} text placeholders")
                    
                    # Auto-populate table placeholders from sequences
                    table_count = 0
                    for i, seq in enumerate(st.session_state.table_sequences):
                        placeholder_key = f"{{{{TABLE{i+1}}}}}"
                        # Find which slide contains this placeholder
                        for slide in prs.slides:
                            for shape in slide.shapes:
                                if hasattr(shape, "text") and placeholder_key in shape.text:
                                    add_table_to_slide(slide, seq['data'], placeholder_key)
                                    table_count += 1
                                    break
                    
                    # Add manual tables
                    if remaining_table_placeholders:
                        for placeholder in remaining_table_placeholders:
                            if placeholder in manual_tables_data and not manual_tables_data[placeholder].empty:
                                placeholder_key = f"{{{{{placeholder}}}}}"
                                for slide in prs.slides:
                                    for shape in slide.shapes:
                                        if hasattr(shape, "text") and placeholder_key in shape.text:
                                            add_table_to_slide(slide, manual_tables_data[placeholder], placeholder_key)
                                            table_count += 1
                                            break
                    
                    if table_count > 0:
                        st.success(f"✅ Added {table_count} tables")
                    
                    # Add images
                    if placeholders['image']:
                        image_count = 0
                        for placeholder in placeholders['image']:
                            if uploaded_images[placeholder] is not None:
                                placeholder_key = f"{{{{{placeholder}}}}}"
                                for slide in prs.slides:
                                    for shape in slide.shapes:
                                        if hasattr(shape, "text") and placeholder_key in shape.text:
                                            add_image_to_slide(slide, uploaded_images[placeholder], placeholder_key)
                                            image_count += 1
                                            break
                        
                        if image_count > 0:
                            st.success(f"✅ Added {image_count} images")
                    
                    # Save the modified presentation
                    output = io.BytesIO()
                    prs.save(output)
                    output.seek(0)
                    
                    # Download button
                    st.download_button(
                        label="📥 Download Auto-Populated PowerPoint",
                        data=output,
                        file_name="auto_populated_presentation.pptx",
                        mime="application/vnd.openxmlformats-officedocument.presentationml.presentation",
                        use_container_width=True
                    )
                    
                    st.success("🎉 PowerPoint generated successfully with auto-population!")
                    
                except Exception as e:
                    st.error(f"❌ Error processing PowerPoint: {str(e)}")
                    st.error("Make sure your PowerPoint file is valid and contains the expected placeholders.")
        
        except Exception as e:
            st.error(f"❌ Error loading PowerPoint: {str(e)}")
            st.error("Please make sure you uploaded a valid .pptx file.")
    
    else:
        st.info("👆 Please upload a PowerPoint template to proceed with auto-population")
        
        # Show example usage
        with st.expander("📋 How to Use This App"):
            st.markdown("""
            **Step 1: Excel Configuration**
            1. Upload your Excel file
            2. Select the sheets you want to work with
            3. Create text sequences by selecting individual cells (these will populate {{TEXT1}}, {{TEXT2}}, etc.)
            4. Create table sequences by selecting columns and rows (these will populate {{TABLE1}}, {{TABLE2}}, etc.)
            5. Use the up/down arrows to reorder sequences
            
            **Step 2: PowerPoint Template**
            1. Upload your PowerPoint template with placeholders
            2. The app will automatically map your Excel data to placeholders in sequence
            3. Fill in any remaining placeholders manually
            4. Generate and download your populated presentation
            
            **PowerPoint Placeholder Format:**
            - Text: `{{TEXT1}}`, `{{TEXT2}}`, `{{TITLE}}`, etc.
            - Tables: `{{TABLE1}}`, `{{TABLE2}}`, etc.
            - Images: `{{IMAGE1}}`, `{{IMAGE2}}`, etc.
            
            **Tips:**
            - Text sequences populate in order: first sequence → {{TEXT1}}, second → {{TEXT2}}, etc.
            - Table sequences populate in order: first table → {{TABLE1}}, second → {{TABLE2}}, etc.
            - You can reorder sequences using the arrow buttons
            - Manual inputs are available for any remaining placeholders
            """)

if __name__ == "__main__":
    main()







##_# hit_selector





import streamlit as st
import pandas as pd
import numpy as np
import io

# -------------------------
# App Title
# -------------------------
def display_app_title():
    st.markdown('<h3 style="color: #083C6E;"><br>Multi-Filter Column Extraction App<br></h3>', unsafe_allow_html=True)

# -------------------------
# Instructions Section
# -------------------------
def display_instructions():
    with st.expander("INSTRUCTIONS & DEMO DATA"):
        st.markdown('<h6 style="color: #083C6E;"><br><br>1) Drag & drop in a data table.<br><br>2) Enter filtering criteria to filter a data table.<br><br>3) With the filtered data table, you can extract a single column & export it.</h6>', unsafe_allow_html=True)
        st.markdown("**Example app usage:**")
        st.markdown("If you need a demo, click 'Use Demo Data' and use one of the filter schemas below to filter the demo data:")
        st.code("(A > 200 and B < 600) or not (C > 70)")
        st.code("D == 'Q'")

# -------------------------
# Demo Data
# -------------------------
def get_demo_data():
    return pd.DataFrame({
        'A': [147, 121, 1989, 452, 263, 573, 326, 35, 152],
        'B': [923, 363, 723, 135, 462, 986, 734, 247, 864],
        'C': [86, 236, 34, 74, 54, 37, 45, 94, 35],
        'D': ['P', 'Q', 'R', 'P', 'Q', 'R', 'P', 'Q', 'R']
    })

# -------------------------
# Function to Replace Spaces with Underscores in Column Names
# -------------------------
def sanitize_column_names(df):
    # Replace common problematic characters with underscores
    df.columns = df.columns.str.replace(' ', '_') \
                           .str.replace('[', '_') \
                           .str.replace(']', '_') \
                           .str.replace('.', '_') \
                           .str.replace(',', '_') \
                           .str.replace(':', '_') \
                           .str.replace('-', '_') \
                           .str.replace('/', '_') \
                           .str.replace('\\', '_') \
                           .str.replace('=', '_') \
                           .str.replace('!', '_') \
                           .str.replace(';', '_')
    return df

# -------------------------
# Load Data Function
# -------------------------
def load_data():
    uploaded_file = st.file_uploader("Upload CSV or Excel file", type=["csv", "xls", "xlsx"])

    demo_data_button = st.button("Use Demo Data")
    df = None

    if demo_data_button:
        df = get_demo_data()
        st.success("Demo data loaded!")

    # -------------------------
    # File Upload Logic
    # -------------------------
    if not demo_data_button and uploaded_file:
        file_type = uploaded_file.name.split(".")[-1]

        if file_type in ["xls", "xlsx"]:
            xls = pd.ExcelFile(uploaded_file)
            sheet_name = st.selectbox("Select sheet", xls.sheet_names)
            df = pd.read_excel(xls, sheet_name=sheet_name)
            # Replace spaces with underscores in column names
            df = sanitize_column_names(df)
        elif file_type == "csv":
            df = pd.read_csv(uploaded_file)
            # Replace spaces with underscores in column names
            df = sanitize_column_names(df)
        else:
            st.error("Unsupported file type.")
    
    return df

# -------------------------
# Filter Blocks and Column Extraction
# -------------------------
def configure_filters_and_extract_columns(df):
    col1, col2 = st.columns([1,1])
    with col1:
        st.markdown(f'<h4 style="color: #6C3BAA;"><br>Set number of filtered lists<br></h4>', unsafe_allow_html=True)
        num_blocks = st.number_input("Adjust:", min_value=1, max_value=10, value=1)

    # -------------------------
    # Loop Over Filter Blocks
    # -------------------------
    numeric_cols = df.select_dtypes(include=["number"]).columns.tolist()
    char_cols = df.select_dtypes(include=["object", "category"]).columns.tolist()

    extracted_columns = []

    for i in range(num_blocks):
        st.markdown(f'<h5 style="color: #FF4D00;"><br>🔎 Filter Block {i+1}<br></h5>', unsafe_allow_html=True)

        with st.expander(f"Configure Filter Block {i+1}", expanded=True):

            col1, col2 = st.columns([2, 1])

            with col1:
                num_filter_expr = st.text_area(f"Enter a filter expression for block {i+1}", height=100, key=f"num_filter_{i}")
            with col2:
                st.data_editor(pd.DataFrame({'Variable names': df.columns}), key = i*1.1)

            # Character filters
            char_filter_dict = {}
            for col in char_cols:
                unique_vals = sorted(df[col].unique().tolist())
                selected_vals = st.multiselect(
                    f"Select values for column `{col}` (all values included by default)",
                    unique_vals,
                    default=unique_vals,
                    key=f"{col}_{i}"
                )
                char_filter_dict[col] = {
                    "all": set(selected_vals) == set(unique_vals),
                    "values": selected_vals
                }

            # Column to extract
            extract_col = st.selectbox(f"Select column to extract from filtered data (block {i+1})", df.columns, key=f"extract_col_{i}")
            remove_duplicates = st.checkbox("Remove Duplicates", value=True, key=i)

        # -------------------------
        # Apply Filters (Ensure new filter expression overwrites old)
        # -------------------------
        filtered_df = df.copy()

        # Apply numeric filter
        if num_filter_expr.strip():
            try:
                # Clear previous filter application by reapplying only the new filter
                filtered_df = filtered_df.query(num_filter_expr)
                if filtered_df.empty:
                    st.warning(f"⚠️ Block {i+1}: Numeric filter returned no rows.")
            except Exception as e:
                st.error(f"❌ Block {i+1}: Invalid numeric filter expression:\n\n{e}")

        # Apply character filters
        for col, filter_info in char_filter_dict.items():
            if not filter_info["all"] and filter_info["values"]:
                filtered_df = filtered_df[filtered_df[col].isin(filter_info["values"])]

        # -------------------------
        # Output Filtered Column
        # -------------------------
        if not filtered_df.empty:
            # Build dynamic header
            header_parts = []
            if num_filter_expr.strip():
                header_parts.append(f"({num_filter_expr})")
            for col, filter_info in char_filter_dict.items():
                if not filter_info["all"] and filter_info["values"]:
                    val_str = ", ".join(filter_info["values"])
                    header_parts.append(f"{col} in [{val_str}]")
            header_title = " and ".join(header_parts) if header_parts else extract_col

            if not remove_duplicates:
                extracted_df = pd.DataFrame({header_title: filtered_df[extract_col].values})
            else:
                extracted_df = pd.DataFrame({header_title: pd.Series(filtered_df[extract_col].unique())})

            st.success(f"✅ Extracted Column from Block {i+1}")
            st.dataframe(extracted_df, use_container_width=True)

            # Add extracted column to the list
            extracted_columns.append(extracted_df)

        else:
            st.info(f"ℹ️ Block {i+1}: No data to extract.")

    return extracted_columns

# -------------------------
# Download Extracted Columns as Excel with Two Sheets
# -------------------------
def download_extracted_columns(df, extracted_columns):
    st.markdown(f'<h4 style="color: #C4B454;"><br>Download All Extracted Columns<br></h4>', unsafe_allow_html=True)

    # Export filename input with default value
    export_filename = st.text_input("Export filename:", placeholder="yourinitials_date_keyword_hits")

    if not export_filename:
        export_filename = "Filtered_values"

    if extracted_columns:
        # Create a new Excel writer object
        with io.BytesIO() as output:
            with pd.ExcelWriter(output, engine='xlsxwriter') as writer:
                # Write the original dataframe to the first sheet
                df.to_excel(writer, sheet_name="Original Data", index=False)

                # Concatenate all extracted columns into a single dataframe for the second sheet
                all_extracted_df = pd.concat(extracted_columns, axis=1)
                all_extracted_df.to_excel(writer, sheet_name="Filtered lists", index=False)

            # Save the result as bytes
            excel_file = output.getvalue()

        # Provide the download link
        st.download_button(
            "Download All Extracted Data as Excel",
            excel_file,
            file_name=f"{export_filename}.xlsx",  # Use the user-defined filename
            mime="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        )
    else:
        st.info("ℹ️ No extracted columns to combine. Adjust your filters.")

# -------------------------
# Main Function
# -------------------------
def run_hit_selector():
    display_app_title()
    display_instructions()
    
    df = load_data()

    if df is not None:
        df = sanitize_column_names(df)  # Replace spaces in column names with underscores
        st.markdown('<h4 style="color: #083C6E;"><br>Your uploaded table:<br></h4>', unsafe_allow_html=True)
        st.dataframe(df, height=300, use_container_width=True)
        
        extracted_columns = configure_filters_and_extract_columns(df)
        download_extracted_columns(df, extracted_columns)  # Pass df along with extracted columns
    else:
        st.write("Please upload a data frame")

run_hit_selector()




##_# register_reagents


import streamlit as st
import pandas as pd
import os
import time
import hashlib
import re
import string
import uuid

import save_to_cloud as s2c

# ---------- Constants ----------
CSV_PATH = "reagent_db.csv"
COLUMNS = ["Experimenter", "Project", "Class", "Name", "Cat#", "Lot#", "Vendor", "Concentration", "Concentration units", "Components"]
CLASS_OPTIONS = ["Cell line", "Antibody", "Dye", "Media", "Other"]

# ---------- Loaders ----------
#@st.cache_data
def load_existing_data():
    """Load the main database of reagents"""
    if os.path.exists(CSV_PATH):
        return pd.read_csv(CSV_PATH, keep_default_na=False).fillna("")
    return pd.DataFrame(columns=COLUMNS)

# ---------- Session State Initialization ----------
def init_session_state():
    """Initialize session state variables"""
    if "clear_requested" not in st.session_state:
        st.session_state.clear_requested = False
    
    if "editor_data" not in st.session_state:
        st.session_state.editor_data = pd.DataFrame(columns=COLUMNS)

# ---------- UI Functions ----------
def render_filters(existing_df):
    """Render project and class filter options"""
    st.markdown('<h4 style="color: #052B4F;"><br><br>Create a reagents list</h4>', unsafe_allow_html=True)
    st.markdown('<h4 style="color: #0289A1;"><br><br>🔍 Select reagent(s) to populate the Registry Table</h4>', unsafe_allow_html=True)

    project_options = existing_df["Project"].dropna().unique().tolist()
    col1, col2 = st.columns([1,1])
    selected_project = col1.selectbox("Filter by Project", options=[""] + sorted(project_options), key=f"project_filter")
    selected_class = col2.selectbox("Filter by Class", options=[""] + CLASS_OPTIONS, key=f"class_filter")
    
    return selected_project, selected_class

def get_filtered_rows(existing_df, selected_project, selected_class):
    """Filter the existing data based on selected filters"""
    filtered_df = existing_df.copy()
    if selected_project:
        filtered_df = filtered_df[filtered_df["Project"] == selected_project]
    if selected_class:
        filtered_df = filtered_df[filtered_df["Class"] == selected_class]

    col1, col2, col3 = st.columns([1,8,1])
    with col2:
        st.markdown('<h5 style="color: #052B4F;">All reagents within the filter:</h5>', unsafe_allow_html=True)
        st.write(filtered_df)
    return filtered_df

def render_row_selector(filtered_df, existing_df):
    """Render the multiselect for choosing reagents from filtered results"""
    selected_rows = pd.DataFrame(columns=COLUMNS)
    
    if not filtered_df.empty:
        row_labels = {
            idx: "_".join(str(filtered_df.loc[idx][col]) for col in COLUMNS)
            for idx in filtered_df.index
        }
        
        # Only show multiselect if there's data to select from
        options = list(row_labels.values())
        
        # Use an empty default for multiselect if clear was requested
        default = [] if st.session_state.clear_requested else None
        
        selected_labels = st.multiselect(
            "Reagent Multi-selector",
            options=options,
            default=default,
            key=f"reagent_selector_"
        )
        
        # Process selections to get dataframe rows
        if selected_labels:
            reverse_lookup = {v: k for k, v in row_labels.items()}
            selected_indexes = [reverse_lookup[label] for label in selected_labels]
            if selected_indexes:
                selected_rows = existing_df.loc[selected_indexes].reset_index(drop=True)

        with st.expander(":grey_question: What if I don't see my reagent?"):
            st.write("Enter the new reagent information into the Reagent Registry Table & Click 'Register reagent(s)'. It will then appear in the Reagent Multi-selector")
    else:
        st.warning("⚠️ No reagent entries found in the selected filter. You can still enter reagents manually.")
    
    return selected_rows

def render_data_editor(entry_df):
    """Render the data editor for reagent entries"""
    st.markdown('<h4 style="color: #052B4F;"><br><br>✏️ Reagent Registry Table</h4>', unsafe_allow_html=True)
    st.markdown('<h6 style="color: #083C6E;"><br><br>    • Please write the reagent entries the way you want them to appear on your final reports.</h6>', unsafe_allow_html=True)

    # If clear was requested or entry_df is empty, show a blank editor with single row
    if st.session_state.clear_requested or entry_df.empty:
        entry_df = pd.DataFrame([[""] * len(COLUMNS)], columns=COLUMNS)
    
    edited_df = st.data_editor(
        entry_df,
        num_rows="dynamic",
        hide_index=True,
        key=f"render_{int(time.time() * 1000000)}",
        column_config={
            "Class": st.column_config.SelectboxColumn(
                "Class",
                help="Select a class",
                options=CLASS_OPTIONS,
                required=False,
            )
        }
    ).fillna("")
    
    return edited_df

def clear_data():
    """Function to handle clear button action"""
    if st.button("Clear table 🧹", key=f"clear_btn_"):
        # Set the clear flag - will be processed before the next rerun
        st.session_state.clear_requested = True
        st.rerun()

def handle_register(edited_df, existing_df):
    """Handle reagent registration"""
    if st.button("Register reagent(s):card_file_box:", key=f"register_btn"):
        # Only register non-empty rows
        valid_rows = edited_df[edited_df.iloc[:, 0] != ""]
        if not valid_rows.empty:
            combined_df = pd.concat([existing_df, valid_rows], ignore_index=True).drop_duplicates()
            combined_df.to_csv(CSV_PATH, index=False)            
            st.success("✅ Data database updated successfully!")
            time.sleep(2)
            st.rerun()
        else:
            st.warning("No valid reagent data to register")


def render_action_buttons(edited_df, existing_df):
    """Render action buttons for registering, sending, and clearing data"""
    col1, col2, col3 = st.columns([1, 1, 2])

    with col1:
        handle_register(edited_df, existing_df)

    with col2:
        clear_data()

    with col3:
        s2c.store_in_cloud(edited_df, file_class_id="rx")

# ---------- Main ----------
def run():
    # Initialize session state
    init_session_state()
    
    # Load existing data
    existing_df = load_existing_data()
    
    # Render UI components for filtering
    selected_project, selected_class = render_filters(existing_df)
    filtered_df = get_filtered_rows(existing_df, selected_project, selected_class)
    
    # Get selected rows from multiselect
    selected_rows = render_row_selector(filtered_df, existing_df)
    
    # Process data based on selection and clear state
    if st.session_state.clear_requested:
        # Clear editor data
        editor_data = pd.DataFrame(columns=COLUMNS)
        # Reset the clear flag after processing
        st.session_state.clear_requested = False
    else:
        # Get existing editor data (if any)
        editor_data = st.session_state.editor_data
        
        if not selected_rows.empty:
            # When editor is empty or has just a blank row, replace it with selected rows
            if editor_data.empty or (len(editor_data) == 1 and editor_data.iloc[0, 0] == ""):
                editor_data = selected_rows
            else:
                # Otherwise concatenate with existing data
                editor_data = pd.concat([editor_data, selected_rows], ignore_index=True).drop_duplicates()


    # Render data editor and update its state
    edited_df = render_data_editor(editor_data)
    st.session_state.editor_data = edited_df
    
    # Render action buttons
    render_action_buttons(edited_df, existing_df)

run()















##_# add_media

import streamlit as st
import pandas as pd
import os


# ---------- Constants ----------
CSV_PATH = "reagent_db.csv"
COLUMNS = ["Experimenter", "Project", "Class", "Name", "Components"]

# ---------- Utility Functions ----------
def load_or_initialize_database(path):
    if os.path.exists(path):
        return pd.read_csv(path)
    return pd.DataFrame(columns=COLUMNS)


def concatenate_row_values(df, experimenter, project, category, cell_lines):
    df_cleaned = df[~df.apply(lambda row: row.isnull() | (row == ""), axis=1).all(axis=1)]
    if df_cleaned.empty:
        return ""
    concatenated_rows = [
        ' '.join(map(str, row.dropna())) for _, row in df_cleaned.iterrows()
    ]
    return f"{experimenter}_{project}_{category}_{cell_lines}_{', '.join(concatenated_rows)}"


def populate_dataframe_from_string(input_string):
    parts = input_string.split('_', 4)
    experimenter, project, category, cell_lines, rest = parts
    return pd.DataFrame([[experimenter, project, category, cell_lines, rest]], columns=COLUMNS)



# ---------- UI Functions ----------
def render_title_and_class_selection(project_opts):
    st.markdown('<h3 style="color: #052B4F;">Enter New List Recipe</h3>', unsafe_allow_html=True)
    st.markdown('<h4 style="color: #0289A1;"><br><br>Choose:</h4>', unsafe_allow_html=True)
    st.markdown('<h6 style="color: #083C6E;"><br><br>To associate your x with y, please register at least one associated y.</h6>', unsafe_allow_html=True)

    col1, col2 = st.columns([1, 8])
    with col2:
        v_experimenter = st.selectbox("Experimenter", options=[""] + project_opts, key="experimenter_selector")

        v_project = st.selectbox("Project", options=[""] + project_opts, key="project_selection")
        
        with st.expander("What if I don't see my project?"):
            st.write("Please enter your new project in the register.")
        
        v_class = st.selectbox("Class", options=[""] + ["Media", "SOP"], key="class_selection")
    
    return v_project, v_class


def handle_media_entry(db, v_project, cell_line_opts):
    col1, col2, col3 = st.columns([1, 4, 4])

    with col2:
        v_celllines = st.multiselect("Cell line(s):", options=cell_line_opts, key="cell_lines_selection")
        joined_celllines = ", ".join(v_celllines)

    with col3:
        st.dataframe(pd.DataFrame({"List of registered cell lines": cell_line_opts}))

    st.markdown('<h4 style="color: #0289A1;">Enter Medium Components:</h4>', unsafe_allow_html=True)
    col1, col2 = st.columns([1, 8])
    with col2:
        default_table = pd.DataFrame([[""] * 4] * 25, columns=["Component Name", "Vendor", "Cat#", "Amount"])
        media_entry_table = st.data_editor(default_table, key="media_data_editor")
        
        non_empty = media_entry_table[~media_entry_table.apply(lambda row: row.isnull() | (row == ""), axis=1).all(axis=1)]

        if not non_empty.empty:
            catted = concatenate_row_values(media_entry_table, v_project, "Media", joined_celllines)
            formatted_for_csv_db = populate_dataframe_from_string(catted)
            st.write(formatted_for_csv_db)

            if st.button("Register media", key="register_media_button"):
                new_media = pd.concat([db, formatted_for_csv_db], ignore_index=True, sort=False).drop_duplicates()
                new_media.to_csv(CSV_PATH, index=False)
                st.success("✅ New media successfully registered.\n\nReset the form to enter another medium recipe above.")


def handle_sop_entry():
    st.text_input("Name", placeholder="e.g. SOP descriptive title", key="sop_name_input")


# ---------- Main App ----------
# def run():
#     # Initialize reset flag
#     if 'reset_flag' not in st.session_state:
#         st.session_state.reset_flag = 0
    
#     # Load database
#     db = load_or_initialize_database(CSV_PATH)
    
#     # Get options from database
#     project_opts = db["Project"].dropna().unique().tolist()
#     cell_line_opts = db[db["Class"] == "Cell line"]["Name"].dropna().unique().tolist()

#     # Use reset flag in keys to make them unique after reset
#     reset_suffix = f"_{st.session_state.reset_flag}"
    
#     # Render UI with dynamic keys
#     col1, col2 = st.columns([1, 8])
#     with col2:
#         v_project = st.selectbox("Project", options=[""] + project_opts, key=f"project_selection{reset_suffix}")
        
#         with st.expander("What if I don't see my project?"):
#             st.write("Please enter your new project in the register.")
        
#         v_class = st.selectbox("Class", options=[""] + ["Media", "SOP"], key=f"class_selection{reset_suffix}")

#     if v_class == "Media" and len(v_project) > 1:
#         col1, col2, col3 = st.columns([1, 4, 4])

#         with col2:
#             v_celllines = st.multiselect("Cell line(s):", options=cell_line_opts, key=f"cell_lines_selection{reset_suffix}")
#             joined_celllines = ", ".join(v_celllines)

#         with col3:
#             st.dataframe(pd.DataFrame({"List of registered cell lines": cell_line_opts}))

#         st.markdown('<h4 style="color: #0289A1;">Enter Medium Components:</h4>', unsafe_allow_html=True)
#         col1, col2 = st.columns([1, 8])
#         with col2:
#             default_table = pd.DataFrame([[""] * 4] * 25, columns=["Component Name", "Vendor", "Cat#", "Amount"])
#             media_entry_table = st.data_editor(default_table, key=f"media_data_editor{reset_suffix}")
            
#             non_empty = media_entry_table[~media_entry_table.apply(lambda row: row.isnull() | (row == ""), axis=1).all(axis=1)]

#             if not non_empty.empty:
#                 catted = concatenate_row_values(media_entry_table, v_project, "Media", joined_celllines)
#                 formatted_for_csv_db = populate_dataframe_from_string(catted)
#                 st.write(formatted_for_csv_db)

#                 if st.button("Register media", key=f"register_media_button{reset_suffix}"):
#                     new_media = pd.concat([db, formatted_for_csv_db], ignore_index=True, sort=False).drop_duplicates()
#                     new_media.to_csv(CSV_PATH, index=False)
#                     st.success("✅ New media successfully registered.\n\nReset the form to enter another medium recipe above.")

#     elif v_class == "SOP" and len(v_project) > 1:
#         st.text_input("Name", placeholder="e.g. SOP descriptive title", key=f"sop_name_input{reset_suffix}")

#     else:
#         st.write("Please select Project & Class")

#     if st.button("🔄 Reset Form", key="reset_form_button_stable"):
#         st.session_state.reset_flag += 1


def run():
    # Initialize reset flag
    if 'reset_flag' not in st.session_state:
        st.session_state.reset_flag = 0

    # Load database
    db = load_or_initialize_database(CSV_PATH)

    # Get options from database
    project_opts = db["Project"].dropna().unique().tolist()
    experimenter_opts = db["Experimenter"].dropna().unique().tolist()
    cell_line_opts = db[db["Class"] == "Cell line"]["Name"].dropna().unique().tolist()

    # Use reset flag in keys to make widgets refresh
    reset_suffix = f"_{st.session_state.reset_flag}"

    # UI - Experimenter + Project + Class
    col1, col2 = st.columns([1, 8])
    with col2:
        v_experimenter = st.selectbox("Experimenter", options=[""] + experimenter_opts, key=f"experimenter_selector{reset_suffix}")
        v_project = st.selectbox("Project", options=[""] + project_opts, key=f"project_selection{reset_suffix}")

        with st.expander("What if I don't see my project?"):
            st.write("Please enter your new project in the register.")

        v_class = st.selectbox("Class", options=[""] + ["Media", "SOP"], key=f"class_selection{reset_suffix}")

    if v_class == "Media" and v_project:
        col1, col2, col3 = st.columns([1, 4, 4])
        with col2:
            v_celllines = st.multiselect("Cell line(s):", options=cell_line_opts, key=f"cell_lines_selection{reset_suffix}")
            joined_celllines = ", ".join(v_celllines)
        with col3:
            st.dataframe(pd.DataFrame({"List of registered cell lines": cell_line_opts}))

        st.markdown('<h4 style="color: #0289A1;">Enter Medium Components:</h4>', unsafe_allow_html=True)
        col1, col2 = st.columns([1, 8])
        with col2:
            default_table = pd.DataFrame([[""] * 4] * 25, columns=["Component Name", "Vendor", "Cat#", "Amount"])
            media_entry_table = st.data_editor(default_table, key=f"media_data_editor{reset_suffix}")
            
            non_empty = media_entry_table[~media_entry_table.apply(lambda row: row.isnull() | (row == ""), axis=1).all(axis=1)]

            if not non_empty.empty:
                # ✅ Use v_experimenter in the concatenation
                catted = concatenate_row_values(media_entry_table, v_experimenter, v_project, "Media", joined_celllines)
                formatted_for_csv_db = populate_dataframe_from_string(catted)
                st.write(formatted_for_csv_db)

                if st.button("Register media", key=f"register_media_button{reset_suffix}"):
                    new_media = pd.concat([db, formatted_for_csv_db], ignore_index=True, sort=False).drop_duplicates()
                    new_media.to_csv(CSV_PATH, index=False)
                    st.success("✅ New media successfully registered.\n\nReset the form to enter another medium recipe above.")

    elif v_class == "SOP" and v_project:
        st.text_input("Name", placeholder="e.g. SOP descriptive title", key=f"sop_name_input{reset_suffix}")

    else:
        st.write("Please select Project & Class")

    if st.button("🔄 Reset Form", key="reset_form_button_stable"):
        st.session_state.reset_flag += 1


if __name__ == "__main__":
    run()




##_# tab_to_tab_populate


import pandas as pd
import streamlit as st
import math

# Sample DataFrame
data = {
    'A': [1, 2, 3, 4],
    'B': [5, 6, 7, 8],
    'C': [9, 10, 11, 12],
    'D': [13, 14, 15, 16]
}
df = pd.DataFrame(data)

def run_col_tfer_custom():
    st.markdown('<h3 style="color: #083C6E;"><br>Transfer columns to populate second table<br></h3>', unsafe_allow_html=True)
    st.markdown('<h5 style="color: #083C6E;"><br>Source Table<br></h5>', unsafe_allow_html=True)
    st.dataframe(df)

    column_options = ["None"] + list(df.columns)

    # Define target columns (you can make this list as long as needed)
    target_columns = ['E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M']

    # Initialize or update session state
    if "column_map" not in st.session_state:
        st.session_state.column_map = {}

    for col in target_columns:
        if col not in st.session_state.column_map:
            st.session_state.column_map[col] = "None"

    st.markdown('<h5 style="color: #083C6E;"><br>Set transfer mapping(s)<br></h5>', unsafe_allow_html=True)

    # Clear All button
    if st.button("Clear All Selections"):
        for col in target_columns:
            st.session_state[f"map_{col}"] = "None"
        st.session_state.column_map = {col: "None" for col in target_columns}
        st.rerun()

    # Render dropdowns in rows of 6
    selected_mapping = {}
    num_per_row = 6
    num_rows = math.ceil(len(target_columns) / num_per_row)

    for row in range(num_rows):
        cols = st.columns(num_per_row)
        for i in range(num_per_row):
            idx = row * num_per_row + i
            if idx < len(target_columns):
                col_name = target_columns[idx]
                with cols[i]:
                    selected_value = st.selectbox(
                        f"→ {col_name}",
                        column_options,
                        key=f"map_{col_name}",
                        index=column_options.index(st.session_state.column_map[col_name])
                    )
                    selected_mapping[col_name] = selected_value

    # Update session state AFTER collecting all selected values
    st.session_state.column_map = selected_mapping

    second_table_df = pd.DataFrame()
    for col in target_columns:
        source_col = selected_mapping[col]
        if source_col != "None":
            second_table_df[col] = df[source_col]
        else:
            second_table_df[col] = pd.Series([None] * len(df))

    # Ensure at least 15 rows
    min_rows = st.number_input("How many rows needed in Destination Table?", min_value = len(df), max_value = 1000, value = len(df))
    current_rows = len(second_table_df)
    if current_rows < min_rows:
        additional_rows = min_rows - current_rows
        empty_rows = pd.DataFrame({col: [None] * additional_rows for col in second_table_df.columns})
        second_table_df = pd.concat([second_table_df, empty_rows], ignore_index=True)

    # Display the destination table
    st.markdown('<h5 style="color: #083C6E;"><br>Destination Table<br></h5>', unsafe_allow_html=True)
    st.data_editor(second_table_df, num_rows="dynamic")

run_col_tfer_custom()




##_# save_to_cloud


# import os
# import math
# import itertools
# import numpy as np
# import pandas as pd
# from math import log10, floor
# from openpyxl import Workbook, load_workbook
# from openpyxl.styles import PatternFill, Alignment
# import colorsys
# import streamlit as st
# import hashlib
# import re

# def sanitize_filename_component(text: str) -> str:
#     """Sanitize each component of a filename."""
#     # Replace all non-alphanumeric characters except dash and underscore
#     cleaned = re.sub(r"[^\w\-]", "_", text)
#     # Collapse multiple underscores
#     cleaned = re.sub(r"_+", "_", cleaned)
#     # Strip leading/trailing underscores
#     return cleaned.strip("_")

# def short_hash_df(df: pd.DataFrame, length: int = 8) -> str:
#     """Generate a short hash based on DataFrame contents"""
#     hash_obj = hashlib.sha256(pd.util.hash_pandas_object(df, index=True).values)
#     return hash_obj.hexdigest()[:length]

# def save_experiment_table(name: str, project: str, keywords: str, df: pd.DataFrame, file_class_id):
#     """Save edited_df to a uniquely named CSV"""
#     if df.empty:
#         return None

#     h = short_hash_df(df)
    
#     # Clean each part
#     name_clean = sanitize_filename_component(name)
#     project_clean = sanitize_filename_component(project)
#     keywords_clean = sanitize_filename_component(keywords)

#     # Join components with underscores
#     parts = [name_clean, project_clean, keywords_clean, file_class_id, h]
#     fname = "_".join(part for part in parts if part) + ".csv"  # Avoid empty parts making extra underscores

#     df.to_csv(fname, index=False)
#     return fname

# def store_in_cloud(edited_df, file_class_id):
#     """Handle sending reagents and saving to a uniquely named CSV"""

#     # Ensure the session state flag exists
#     if "show_metadata_form" not in st.session_state:
#         st.session_state.show_metadata_form = False

#     # Only keep valid rows
#     valid_rows = edited_df[edited_df.iloc[:, 0] != ""]

#     # When button is pressed, toggle form
#     if st.button("Store parameters for future use → :cloud:", key="send_btn"):
#         if not valid_rows.empty:
#             st.session_state.show_metadata_form = True
#         else:
#             st.warning("⚠️ No reagents to send.")
#             st.session_state.show_metadata_form = False

#     # If flag is set, show the form
#     if st.session_state.show_metadata_form:
#         st.success("✅ Valid reagents detected. Please complete the following:")

#         with st.form("send_metadata_form", clear_on_submit=False):
#             name = st.text_input("Initials")
#             project = st.text_input("Project")
#             keywords = st.text_input("Keywords (e.g. 'cell, staining')")

#             submitted = st.form_submit_button("Save & Confirm Send")

#             if submitted:
#                 if name and project and keywords:
#                     saved_file = save_experiment_table(name, project, keywords, valid_rows, file_class_id = file_class_id)
#                     st.success(f"Saved as: `{saved_file}`")
#                     st.write("Information stored")
#                     st.dataframe(valid_rows)
#                     st.session_state.show_metadata_form = False  # Reset
#                 else:
#                     st.warning("Please fill in all fields to save and send reagents.")


import os
import math
import itertools
import numpy as np
import pandas as pd
from math import log10, floor
from openpyxl import Workbook, load_workbook
from openpyxl.styles import PatternFill, Alignment
import colorsys
import streamlit as st
import hashlib
import re
import time
import uuid


# Constants
EXP_ID_CSV = "experiment_ids.csv"

def sanitize_filename_component(text: str) -> str:
    """Sanitize each component of a filename."""
    # Replace all non-alphanumeric characters except dash and underscore
    cleaned = re.sub(r"[^\w\-]", "_", text)
    # Collapse multiple underscores
    cleaned = re.sub(r"_+", "_", cleaned)
    # Strip leading/trailing underscores
    return cleaned.strip("_")

def short_hash_df(df: pd.DataFrame, length: int = 8) -> str:
    """Generate a short hash based on DataFrame contents"""
    hash_obj = hashlib.sha256(pd.util.hash_pandas_object(df, index=True).values)
    return hash_obj.hexdigest()[:length]

def create_experiment_id(name: str, project: str, keywords: list) -> str:
    """Create experiment ID by concatenating name, project, and keywords"""
    # Clean each component
    name_clean = sanitize_filename_component(name)
    project_clean = sanitize_filename_component(project)
    keywords_clean = [sanitize_filename_component(kw.strip()) for kw in keywords if kw.strip()]
    
    # Join components with underscores
    parts = [name_clean, project_clean] + keywords_clean
    exp_id = "_".join(part for part in parts if part)
    return exp_id

def save_experiment_id(exp_id: str):
    """Save experiment ID to CSV, removing duplicates"""
    # Load existing IDs or create empty DataFrame
    if os.path.exists(EXP_ID_CSV):
        try:
            existing_df = pd.read_csv(EXP_ID_CSV)
        except:
            existing_df = pd.DataFrame(columns=['experiment_id'])
    else:
        existing_df = pd.DataFrame(columns=['experiment_id'])
    
    # Add new ID
    new_row = pd.DataFrame({'experiment_id': [exp_id]})
    updated_df = pd.concat([existing_df, new_row], ignore_index=True)
    
    # Remove duplicates and save
    updated_df = updated_df.drop_duplicates().reset_index(drop=True)
    updated_df.to_csv(EXP_ID_CSV, index=False)
    
    # Store in session state
    st.session_state.exp_id = exp_id
    
    return updated_df

def load_experiment_ids() -> list:
    """Load all experiment IDs from CSV"""
    if os.path.exists(EXP_ID_CSV):
        try:
            df = pd.read_csv(EXP_ID_CSV)
            return df['experiment_id'].tolist()
        except:
            return []
    return []

def get_default_exp_id() -> str:
    """Get default experiment ID from session state or most recent from CSV"""
    # First check session state
    if 'exp_id' in st.session_state and st.session_state.exp_id:
        return st.session_state.exp_id
    
    # Otherwise get most recent from CSV
    exp_ids = load_experiment_ids()
    if exp_ids:
        return exp_ids[-1]  # Most recent (last in list)
    
    return ""

def render_experiment_id_selector():
    """Render selectbox for choosing experiment ID"""
    st.markdown("### Select or Create Experiment ID")
    
    exp_ids = load_experiment_ids()
    default_id = get_default_exp_id()
    
    if exp_ids:
        # Find index of default ID
        try:
            default_index = exp_ids.index(default_id) if default_id in exp_ids else len(exp_ids) - 1
        except:
            default_index = len(exp_ids) - 1 if exp_ids else 0
        
        # Add "Create New" option at the beginning
        options = ["-- Create New --"] + exp_ids
        default_index += 1  # Adjust for the "Create New" option
        
        selected = st.selectbox(
            "Choose existing experiment ID or create new:",
            options=options,
            index=default_index,
            key="exp_id_selector"
        )
        
        if selected == "-- Create New --":
            return None  # Signal to show creation form
        else:
            # Store selected ID in session state
            st.session_state.exp_id = selected
            return selected
    else:
        st.info("No existing experiment IDs found. Create your first one below.")
        return None

def save_experiment_table(name: str, project: str, keywords: list, df: pd.DataFrame, file_class_id):
    """Save edited_df to a uniquely named CSV"""
    if df.empty:
        return None
    
    h = short_hash_df(df)
    exp_id = create_experiment_id(name, project, keywords)
    
    # Create filename with experiment ID and hash
    fname = f"{exp_id}_{file_class_id}_{h}.csv"
    df.to_csv(fname, index=False)
    return fname

def parse_experiment_id(exp_id: str) -> tuple:
    """Parse experiment ID back into name, project, and keywords"""
    if not exp_id:
        return "", "", []
    
    parts = exp_id.split('_')
    if len(parts) >= 2:
        name = parts[0]
        project = parts[1]
        keywords = parts[2:] if len(parts) > 2 else []
        return name, project, keywords
    return "", "", []

def store_in_cloud(edited_df, file_class_id):
    """Handle sending reagents and saving to a uniquely named CSV"""
    # Ensure the session state flag exists
    if "show_metadata_form" not in st.session_state:
        st.session_state.show_metadata_form = False
    
    # Only keep valid rows
    valid_rows = edited_df[edited_df.iloc[:, 0] != ""]
    
    # Get current experiment ID from session state (if exists)
    current_exp_id = st.session_state.get('exp_id', '')
    
    # Parse current session state values for defaults
    default_name, default_project, default_keywords = parse_experiment_id(current_exp_id)
    
    # Show current experiment ID if it exists
    if current_exp_id:
        st.info(f"Current experiment ID: `{current_exp_id}`")
    
    # When button is pressed, toggle form
    if st.button("Store parameters for future use → :cloud:", key=f"send_btn_{int(time.time() * 1000000)}"):#f"send_btn_"
        if not valid_rows.empty:
            st.session_state.show_metadata_form = True
        else:
            st.warning("⚠️ No reagents to send.")
            st.session_state.show_metadata_form = False
    
    # If flag is set, show the form
    # if st.session_state.show_metadata_form:
    #     st.success("✅ Valid reagents detected. Please complete the following:")
        
    #     with st.form("send_metadata_form", clear_on_submit=False, key = f"validated_{int(time.time() * 1000000)}"):
    #         # Pre-populate with session state values
    #         name = st.text_input("Initials", value=default_name, help="Your initials or name")
    #         project = st.text_input("Project", value=default_project, help="Project name or identifier")
            
    #         st.write("Keywords (up to 5):")
    #         col1, col2 = st.columns(2)
    #         with col1:
    #             kw1 = st.text_input("Keyword 1", value=default_keywords[0] if len(default_keywords) > 0 else "", key="kw1")
    #             kw2 = st.text_input("Keyword 2", value=default_keywords[1] if len(default_keywords) > 1 else "", key="kw2")
    #             kw3 = st.text_input("Keyword 3", value=default_keywords[2] if len(default_keywords) > 2 else "", key="kw3")
    #         with col2:
    #             kw4 = st.text_input("Keyword 4", value=default_keywords[3] if len(default_keywords) > 3 else "", key="kw4")
    #             kw5 = st.text_input("Keyword 5", value=default_keywords[4] if len(default_keywords) > 4 else "", key="kw5")
            
    #         submitted = st.form_submit_button("Save & Confirm Send")
            
    #         if submitted:
    #             if name and project:
    #                 # Collect keywords
    #                 keywords = [kw for kw in [kw1, kw2, kw3, kw4, kw5] if kw.strip()]
                    
    #                 # Create and save experiment ID
    #                 exp_id = create_experiment_id(name, project, keywords)
    #                 save_experiment_id(exp_id)  # This updates both CSV and session state
                    
    #                 # Save the experiment table
    #                 saved_file = save_experiment_table(name, project, keywords, valid_rows, file_class_id)
                    
    #                 st.success(f"Experiment ID: `{exp_id}`")
    #                 st.success(f"Saved as: `{saved_file}`")
    #                 st.write("Information stored")
    #                 st.dataframe(valid_rows)
                    
    #                 # Reset form
    #                 st.session_state.show_metadata_form = False
    #             else:
    #                 st.warning("Please fill in at least Name and Project fields to save and send reagents.")
    if st.session_state.show_metadata_form:
        st.success("✅ Valid reagents detected. Please complete the following:")

        # Using a unique key for the form
        form_key = f"validated_{int(time.time() * 1000000)}"
        
        with st.form("send_metadata_form", clear_on_submit=False, key=form_key):
            # Pre-populate with session state values
            name = st.text_input("Initials", value=default_name, help="Your initials or name")
            project = st.text_input("Project", value=default_project, help="Project name or identifier")

            st.write("Keywords (up to 5):")
            col1, col2 = st.columns(2)
            
            # Set unique keys for each widget inside the form
            with col1:
                kw1 = st.text_input("Keyword 1", value=default_keywords[0] if len(default_keywords) > 0 else "", key="kw1")
                kw2 = st.text_input("Keyword 2", value=default_keywords[1] if len(default_keywords) > 1 else "", key="kw2")
                kw3 = st.text_input("Keyword 3", value=default_keywords[2] if len(default_keywords) > 2 else "", key="kw3")
            with col2:
                kw4 = st.text_input("Keyword 4", value=default_keywords[3] if len(default_keywords) > 3 else "", key="kw4")
                kw5 = st.text_input("Keyword 5", value=default_keywords[4] if len(default_keywords) > 4 else "", key="kw5")

            # Submit button
            submitted = st.form_submit_button("Save & Confirm Send")

            if submitted:
                if name and project:
                    # Collect keywords
                    keywords = [kw for kw in [kw1, kw2, kw3, kw4, kw5] if kw.strip()]

                    # Create and save experiment ID
                    exp_id = create_experiment_id(name, project, keywords)
                    save_experiment_id(exp_id)  # This updates both CSV and session state

                    # Save the experiment table
                    saved_file = save_experiment_table(name, project, keywords, valid_rows, file_class_id)

                    st.success(f"Experiment ID: `{exp_id}`")
                    st.success(f"Saved as: `{saved_file}`")
                    st.write("Information stored")
                    st.dataframe(valid_rows)

                    # Reset form
                    st.session_state.show_metadata_form = False
                else:
                    st.warning("Please fill in at least Name and Project fields to save and send reagents.")






# Example usage function for testing
# def demo_store_in_cloud():
#     """Demo function to test the store_in_cloud functionality"""
#     st.title("Cloud Storage Demo")
    
#     # Create sample dataframe for testing
#     sample_data = {
#         'Reagent': ['ReagentA', 'ReagentB', 'ReagentC'],
#         'Concentration': ['1mM', '5uM', '10nM'],
#         'Volume': ['100ul', '50ul', '200ul']
#     }
#     sample_df = pd.DataFrame(sample_data)
    
#     st.write("Sample data to store:")
#     st.dataframe(sample_df)
    
#     # Test the store_in_cloud function
#     store_in_cloud(sample_df, "TEST")

# if __name__ == "__main__":
#     demo_store_in_cloud()


##_# main



import streamlit as st

# Set page configuration - this should be the first Streamlit command
st.set_page_config(
    page_title="Lab Reagent Manager",
    page_icon="🧪",
    layout="wide",
    initial_sidebar_state="expanded"
)

# Function to safely import and run modules
def load_and_run_page(page_name):
    module_map = {
        "Register Metadata": "meta_registry",
        "Register Reagents": "register_reagents",
        "Register Media": "add_media",
        "Delete Reagents": "delete_items_in_db",
        "Create Metadata Table": "rx_combis",
        "Dilute Reagents": "xl_serial_dil"
    }
    
    module_name = module_map.get(page_name)
    if not module_name:
        st.error(f"Unknown page: {page_name}")
        return
    
    try:
        # Dynamic import
        module = __import__(module_name)
        
        # Check if module has run function
        if hasattr(module, 'run') and callable(module.run):
            module.run()
        else:
            st.error(f"Module {module_name} doesn't have a callable run() function")
            
    except ImportError as e:
        st.error(f"Could not import {module_name}: {str(e)}")
    except Exception as e:
        st.error(f"Error running {page_name}: {str(e)}")
        with st.expander("Show error details"):
            st.code(repr(e))

# Available pages
PAGE_NAMES = [
    "Register Metadata",
    "Register Reagents",
    "Register Media", 
    "Delete Reagents",
    "Create Metadata Table",
    "Dilute Reagents"
]

# Create main layout containers
sidebar_container = st.sidebar.container()
main_container = st.container()

# Sidebar Navigation
with sidebar_container:
    st.title("Lab Reagent Manager")
    st.markdown("---")
    
    current_page = st.radio(
        "Navigation:",
        PAGE_NAMES,
        index=0,
        key="page_nav"
    )
    
    st.markdown("---")
    st.caption("Have a suggestion? :bulb:")
    st.caption("Found a bug? :beetle:")
    st.caption("Screen shot it & send to Anna Bird + your input data if applicable.")

# Main content area
with main_container:
    st.header(f"{current_page}")
    
    # Create a placeholder for page content
    page_placeholder = st.empty()
    
    # Load page content into the placeholder
    with page_placeholder.container():
        load_and_run_page(current_page)





##_# rx_combis_tableinput



import streamlit as st
import pandas as pd
import io
import time
import uuid
import random
import string
import datetime
import time
import random
import string

def get_stable_key(base_name, unique_suffix=""):
    # Combine base_name with timestamp and unique suffix to ensure key uniqueness
    timestamp = int(time.time() * 1000000)  # Microsecond precision
    random_suffix = ''.join(random.choices(string.ascii_letters + string.digits, k=6))  # Random part
    
    # Return a key that combines everything
    return f"{base_name}_{timestamp}_{random_suffix}_{unique_suffix}"


def initialize_session_state():
    """Initialize all session state variables."""
    if 'imported_df' not in st.session_state:
        st.session_state.imported_df = None
    if 'original_headers' not in st.session_state:
        st.session_state.original_headers = []
    if 'final_df' not in st.session_state:
        st.session_state.final_df = None
    if 'removed_duplicates' not in st.session_state:
        st.session_state.removed_duplicates = 0
    if 'rows_with_missing' not in st.session_state:
        st.session_state.rows_with_missing = None


def import_file_section():
    """Handle file import functionality."""
    st.markdown("<br><h3 style='color: #007BA7;'>Import Function</h3>", unsafe_allow_html=True)

    col1, col2 = st.columns([1,8])
        
    with col2:
        uploaded_file = st.file_uploader(
            "Drag and drop your table file here",
            type=['csv', 'xlsx', 'xls'],
            help="Supported formats: CSV, Excel (.xlsx, .xls)",
            key = "sumac"
        )

        if uploaded_file is not None:
            file_extension = uploaded_file.name.split('.')[-1].lower()
            
            try:
                # Handle Excel files
                if file_extension in ['xlsx', 'xls']:
                    # Read Excel file to get sheet names
                    excel_file = pd.ExcelFile(uploaded_file)
                    sheet_names = excel_file.sheet_names
                    
                    st.write(f"📊 Excel file detected with {len(sheet_names)} sheet(s)")
                    
                    # Sheet selection
                    if len(sheet_names) > 1:
                        selected_sheet = st.selectbox(
                            "Select the sheet to import:",
                            options=sheet_names,
                            key=get_stable_key("exc")
                        )
                    else:
                        selected_sheet = sheet_names[0]
                        st.write(f"Using sheet: **{selected_sheet}**")
                    
                    # Read the selected sheet
                    df = pd.read_excel(uploaded_file, sheet_name=selected_sheet)
                    
                # Handle CSV files
                elif file_extension == 'csv':
                    df = pd.read_csv(uploaded_file)
                
                # Store imported data
                st.session_state.imported_df = df
                st.session_state.original_headers = list(df.columns)
                
                # Display import success
                st.success(f"✅ File imported successfully!")
                st.write(f"**File:** {uploaded_file.name}")
                if file_extension in ['xlsx', 'xls']:
                    st.write(f"**Sheet:** {selected_sheet}")
                st.write(f"**Dimensions:** {df.shape[0]} rows × {df.shape[1]} columns")
                
                # Show preview of imported data
                st.write("**Preview of imported data:**")
                st.dataframe(df.head(10), use_container_width=True)
                            
            except Exception as e:
                st.error(f"❌ Error reading file: {str(e)}")
                st.session_state.imported_df = None


def assign_columns_section():
    st.markdown("<br><h3 style='color: #007BA7;'>Assign Columns</h3>", unsafe_allow_html=True)

    if st.session_state.imported_df is not None:
        df = st.session_state.imported_df
        original_headers = st.session_state.original_headers
        
        st.write("Map your original columns to the new column names (A, B, C, D, E):")
        
        # Create column mapping interface
        col1, col2 = st.columns([1,8])
        
        with col1:
            new_columns = ['A', 'B', 'C', 'D', 'E']
        
        with col2:
            st.write("**Select Original Columns:**")
            column_mapping = {}
            
            # Create selectboxes for each new column
            # for new_col in new_columns:
            #     selected_original = st.selectbox(
            #         f"Map to column '{new_col}':",
            #         options=['-- Select Column --'] + original_headers,
            #         key=get_stable_key("orig")
            #     )
            for new_col in new_columns:
                selected_original = st.selectbox(
                    f"Map to column '{new_col}':",
                    options=['-- Select Column --'] + original_headers,
                    key=f"{new_col}"
                )

                
                if selected_original != '-- Select Column --':
                    column_mapping[new_col] = selected_original
        
            # Process button
            if st.button("🔄 Process Table", type="primary", key="asdfghew_"):

            #if st.button("🔄 Process Table", type="primary"):
                if len(column_mapping) > 0:
                    try:
                        # Create new dataframe with selected columns
                        selected_columns = list(column_mapping.values())
                        new_df = df[selected_columns].copy()
                        
                        # Rename columns
                        rename_dict = {original: new for new, original in column_mapping.items()}
                        new_df = new_df.rename(columns=rename_dict)
                        
                        # Store original row count
                        original_row_count = len(new_df)
                        
                        # Remove duplicate rows
                        new_df_no_dups = new_df.drop_duplicates()
                        duplicates_removed = original_row_count - len(new_df_no_dups)
                        
                        # Identify rows with missing values
                        rows_with_missing = new_df_no_dups[new_df_no_dups.isnull().any(axis=1)]
                        
                        # Store results in session state
                        st.session_state.final_df = new_df_no_dups
                        st.session_state.removed_duplicates = duplicates_removed
                        st.session_state.rows_with_missing = rows_with_missing
                        
                        st.success("✅ Table processed successfully!")
                        
                    except Exception as e:
                        st.error(f"❌ Error processing table: {str(e)}")
                else:
                    st.warning("⚠️ Please select at least one column mapping before processing.")

def display_formatted_table():
    """Display the formatted table and processing results."""
    if st.session_state.final_df is not None:
        final_df = st.session_state.final_df
        duplicates_removed = st.session_state.removed_duplicates
        rows_with_missing = st.session_state.rows_with_missing
        
        st.markdown("<br><h3 style='color: #007BA7;'>Formatted Table</h3>", unsafe_allow_html=True)
        
        # Show processing summary
        col1, col2, col3, col4 = st.columns([1,2,2,2])
        with col2:
            st.metric("Final Rows", len(final_df))
        with col3:
            st.metric("Duplicates Removed", duplicates_removed)
        with col4:
            st.metric("Rows with Missing Values", len(rows_with_missing))

        col1, col2, col3 = st.columns([1,4,4])
        # Show duplicate removal message
        with col2:
            if duplicates_removed > 0:
                st.info(f"ℹ️ **Duplicate rows removed:** {duplicates_removed} duplicate row(s) were found and removed from the final dataset.")
            else:
                st.success("✅ **No duplicate rows found.**")
            
            # Show missing values information
            if len(rows_with_missing) > 0:
                st.warning(f"⚠️ **Rows with missing values found:** {len(rows_with_missing)} row(s) contain missing values.")
                
                with st.expander("View rows with missing values"):
                    st.dataframe(rows_with_missing, use_container_width=True)
                    
                    # Show which columns have missing values
                    missing_info = rows_with_missing.isnull().sum()
                    missing_cols = missing_info[missing_info > 0]
                    if len(missing_cols) > 0:
                        st.write("**Missing values by column:**")
                        for col, count in missing_cols.items():
                            st.write(f"• Column '{col}': {count} missing value(s)")
            else:
                st.success("✅ **No missing values found.**")
            
            # Display final processed table
            st.write("**Final Processed Table:**")
        
        col1, col2 = st.columns([1,8])
        with col2:
            st.dataframe(final_df, use_container_width=True)

def download_and_action_section():
    """Handle download options and metadata action."""
    meta_table_one = None
    
    if st.session_state.final_df is not None:
        final_df = st.session_state.final_df
        duplicates_removed = st.session_state.removed_duplicates
        rows_with_missing = st.session_state.rows_with_missing
        
        # Download options
        st.markdown("<br><h3 style='color: #007BA7;'>Choose</h3>", unsafe_allow_html=True)
        
        col1, col2, col3, col4 = st.columns([3,2,2,2])
        with col1:
            if st.button(":ice_hockey_stick_and_puck: Pass table above into metadata"):
                meta_table_one = st.session_state.final_df

        with col2:
            # CSV download
            csv = final_df.to_csv(index=False)
            st.download_button(
                label="📥 Download as CSV",
                data=csv,
                file_name="processed_table.csv",
                mime="text/csv"
            )
        
        with col3:
            # Excel download
            excel_buffer = io.BytesIO()
            with pd.ExcelWriter(excel_buffer, engine='openpyxl') as writer:
                final_df.to_excel(writer, sheet_name='Processed_Data', index=False)
                
                # Add summary sheet
                summary_data = pd.DataFrame({
                    'Metric': ['Total Rows', 'Duplicates Removed', 'Rows with Missing Values'],
                    'Value': [len(final_df), duplicates_removed, len(rows_with_missing)]
                })
                summary_data.to_excel(writer, sheet_name='Summary', index=False)
                
                # Add missing values sheet if any exist
                if len(rows_with_missing) > 0:
                    rows_with_missing.to_excel(writer, sheet_name='Rows_with_Missing', index=False)
            
            excel_buffer.seek(0)
            
            st.download_button(
                label="📥 Download as Excel",
                data=excel_buffer.getvalue(),
                file_name="processed_table.xlsx",
                mime="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
            )
        with col4:
            # Reset button
            if st.session_state.imported_df is not None:
                if st.button("🗑️ Clear All Data and Start Over"):
                    clear_all_data()
                    st.rerun()
    
    return meta_table_one

def clear_all_data():
    """Clear all session state data."""
    st.session_state.imported_df = None
    st.session_state.original_headers = []
    st.session_state.final_df = None
    st.session_state.removed_duplicates = 0
    st.session_state.rows_with_missing = None

def incorporate_imported_metadata():
    """Main function to run the Streamlit app and return meta_table_one if button is pressed."""    
    # Initialize session state
    initialize_session_state()
    
    # Run all sections
    import_file_section()
    assign_columns_section()
    display_formatted_table()
    meta_table_one = download_and_action_section()
    
    # Show info message if no data is available
    if st.session_state.imported_df is None:
        st.info("👆 Please import a file in Section A to begin the column renaming process.")
    
    return meta_table_one

# Use of this will output a table
# meta_table_one = incorporate_imported_metadata()





##_# import_cat_rx



import os
import math
import itertools
import numpy as np
import pandas as pd
from math import log10, floor
from openpyxl import Workbook, load_workbook
from openpyxl.styles import PatternFill, Alignment
import colorsys
import streamlit as st
import hashlib
import re
import save_to_cloud as s2c
import time
import streamlit as st
import uuid

# Initialize key storage in session state
if 'widget_keys' not in st.session_state:
    st.session_state.widget_keys = {}

def get_stable_key(widget_id):
    """Get or create a stable key for a widget"""
    if widget_id not in st.session_state.widget_keys:
        st.session_state.widget_keys[widget_id] = f"{widget_id}_{uuid.uuid4().hex[:8]}"
    return st.session_state.widget_keys[widget_id]

# Select and import CSV file
def select_and_import_csv():
    current_dir = os.getcwd()  # Get the current working directory
    
    # Find all CSV files containing '_' in their filename
    csv_files = [f for f in os.listdir(current_dir) if f.endswith('.csv') and '_' in f]
    
    if not csv_files:
        st.warning("No reagent tables available yet. Create one of these using Reagent Registry")
        return None
    
    # Sort CSV files by modification time (newest first)
    csv_files_with_time = []
    for file in csv_files:
        file_path = os.path.join(current_dir, file)
        try:
            mod_time = os.path.getmtime(file_path)
            csv_files_with_time.append((file, mod_time))
        except OSError:
            # If we can't get modification time, add with timestamp 0
            csv_files_with_time.append((file, 0))
    
    # Sort by modification time (newest first - descending order)
    csv_files_with_time.sort(key=lambda x: x[1], reverse=True)
    
    # Extract just the filenames in sorted order
    sorted_csv_files = [file for file, _ in csv_files_with_time]
    
    # Create a selectbox for the user to choose a CSV file
    selected_file = st.selectbox("Select a CSV file to import:", sorted_csv_files)
    
    if selected_file:
        file_path = os.path.join(current_dir, selected_file)
        try:
            df = pd.read_csv(file_path)
            st.success(f"Successfully stored {selected_file.removesuffix('.csv')}")
            return df
        except Exception as e:
            st.error(f"Error importing {selected_file}: {str(e)}")
            return None
    
    return None

def process_and_concatenate_columns(keyword="", delimiter=" ", output_column_name="concatenated_column"):

    st.markdown("""
        <br>
        <h5 style='color: #007BA7;'>Select a reagent list:</h5>
    """, unsafe_allow_html=True)

    # Step 1: List all CSV files in the current directory containing the keyword in the filename
    files = [f for f in os.listdir('.') if f.endswith('.csv') and keyword in f]
    
    # If no files match, show an error and exit
    if not files:
        st.error(f"No CSV files found with '{keyword}' in the filename.")
        return []
    
    # Step 2: Remove '.csv' extension for display in the dropdown
    files_without_extension = [f.replace('.csv', '') for f in files]
    
    # Step 3: Allow the user to select a file from the dropdown
    selected_file_name = st.selectbox(
        "Choose reagents from registry:",
        [None] + files_without_extension,
        key=f"rx_concat_cols_{int(time.time() * 1000000)}"# Make the key unique by appending the keyword
    )
    if selected_file_name:
        # Step 4: Re-add the '.csv' extension to the selected file name
        selected_csv = selected_file_name + '.csv'
        
        # Step 5: Read the selected CSV to get its columns
        df = pd.read_csv(selected_csv)
        
        # Step 6: Let the user select which columns to concatenate
        columns_to_concat = st.multiselect("Select column(s) to use as reagent list", df.columns.tolist(), key = get_stable_key("headers"))
        
        # Step 7: Ensure at least two columns are selected
        if len(columns_to_concat) < 2:
            st.error("Please select at least two columns to concatenate.")
            return []

        # Step 8: Concatenate the selected columns
        df[output_column_name] = df[columns_to_concat].apply(lambda row: delimiter.join(row.astype(str)), axis=1)
        
        # Step 9: Extract the concatenated column as a list
        concatenated_list = df[output_column_name].tolist()

        return concatenated_list, df
    else:
        
        st.write("Recommended: Use reagent registry to store reagent info. Then extract it out here.")
        concatenated_list = []
        df = []
        return concatenated_list, df








##_# meta_registry




import streamlit as st
import pandas as pd
import os
import time
import hashlib
import re
import string
import uuid

import save_to_cloud as s2c

# ---------- Constants ----------
CSV_PATH = "meta_db.csv"
COLUMNS = ["Origin", "Contact"]
CLASS_OPTIONS = ["Cell line", "Antibody", "Dye", "Media", "Other"]

# ---------- Loaders ----------
#@st.cache_data
def load_existing_data():
    """Load the main database of reagents"""
    if os.path.exists(CSV_PATH):
        return pd.read_csv(CSV_PATH, keep_default_na=False).fillna("")
    return pd.DataFrame(columns=COLUMNS)

# ---------- Session State Initialization ----------
def init_session_state():
    """Initialize session state variables"""
    if "clear_requested" not in st.session_state:
        st.session_state.clear_requested = False
    
    if "editor_data" not in st.session_state:
        st.session_state.editor_data = pd.DataFrame(columns=COLUMNS)

# ---------- UI Functions ----------
def render_filters(existing_df):
    """Render project and class filter options"""
    st.markdown('<h4 style="color: #052B4F;"><br><br>Create a reagents list</h4>', unsafe_allow_html=True)
    st.markdown('<h4 style="color: #0289A1;"><br><br>🔍 Select reagent(s) to populate the Registry Table</h4>', unsafe_allow_html=True)

    project_options = existing_df["Project"].dropna().unique().tolist()
    col1, col2 = st.columns([1,1])
    selected_project = col1.selectbox("Filter by Project", options=[""] + sorted(project_options), key=f"project_filter")
    selected_class = col2.selectbox("Filter by Class", options=[""] + CLASS_OPTIONS, key=f"class_filter")
    
    return selected_project, selected_class

def get_filtered_rows(existing_df, selected_project, selected_class):
    """Filter the existing data based on selected filters"""
    filtered_df = existing_df.copy()
    if selected_project:
        filtered_df = filtered_df[filtered_df["Project"] == selected_project]
    if selected_class:
        filtered_df = filtered_df[filtered_df["Class"] == selected_class]

    col1, col2, col3 = st.columns([1,8,1])
    with col2:
        st.markdown('<h5 style="color: #052B4F;">All reagents within the filter:</h5>', unsafe_allow_html=True)
        st.write(filtered_df)
    return filtered_df

def render_row_selector(filtered_df, existing_df):
    """Render the multiselect for choosing reagents from filtered results"""
    selected_rows = pd.DataFrame(columns=COLUMNS)
    
    if not filtered_df.empty:
        row_labels = {
            idx: "_".join(str(filtered_df.loc[idx][col]) for col in COLUMNS)
            for idx in filtered_df.index
        }
        
        # Only show multiselect if there's data to select from
        options = list(row_labels.values())
        
        # Use an empty default for multiselect if clear was requested
        default = [] if st.session_state.clear_requested else None
        
        selected_labels = st.multiselect(
            "Reagent Multi-selector",
            options=options,
            default=default,
            key=f"reagent_selector_"
        )
        
        # Process selections to get dataframe rows
        if selected_labels:
            reverse_lookup = {v: k for k, v in row_labels.items()}
            selected_indexes = [reverse_lookup[label] for label in selected_labels]
            if selected_indexes:
                selected_rows = existing_df.loc[selected_indexes].reset_index(drop=True)

        with st.expander(":grey_question: What if I don't see my reagent?"):
            st.write("Enter the new reagent information into the Reagent Registry Table & Click 'Register reagent(s)'. It will then appear in the Reagent Multi-selector")
    else:
        st.warning("⚠️ No reagent entries found in the selected filter. You can still enter reagents manually.")
    
    return selected_rows

def render_data_editor(entry_df):
    """Render the data editor for reagent entries"""
    st.markdown('<h4 style="color: #052B4F;"><br><br>✏️ Reagent Registry Table</h4>', unsafe_allow_html=True)
    st.markdown('<h6 style="color: #083C6E;"><br><br>    • Please write the reagent entries the way you want them to appear on your final reports.</h6>', unsafe_allow_html=True)

    # If clear was requested or entry_df is empty, show a blank editor with single row
    if st.session_state.clear_requested or entry_df.empty:
        entry_df = pd.DataFrame([[""] * len(COLUMNS)], columns=COLUMNS)
    
    edited_df = st.data_editor(
        entry_df,
        num_rows="dynamic",
        hide_index=True,
        key=f"render_{int(time.time() * 1000000)}",
        column_config={
            "Origin": st.column_config.SelectboxColumn(
                "Origin",
                help="Select a class",
                options=CLASS_OPTIONS,
                required=False,
            )
        }
    ).fillna("")
    
    return edited_df

def clear_data():
    """Function to handle clear button action"""
    if st.button("Clear table 🧹", key=f"clear_btn_"):
        # Set the clear flag - will be processed before the next rerun
        st.session_state.clear_requested = True
        st.rerun()

def handle_register(edited_df, existing_df):
    """Handle reagent registration"""
    if st.button("Register reagent(s):card_file_box:", key=f"register_btn"):
        # Only register non-empty rows
        valid_rows = edited_df[edited_df.iloc[:, 0] != ""]
        if not valid_rows.empty:
            combined_df = pd.concat([existing_df, valid_rows], ignore_index=True).drop_duplicates()
            combined_df.to_csv(CSV_PATH, index=False)            
            st.success("✅ Data database updated successfully!")
            time.sleep(2)
            st.rerun()
        else:
            st.warning("No valid reagent data to register")


def render_action_buttons(edited_df, existing_df):
    """Render action buttons for registering, sending, and clearing data"""
    col1, col2, col3 = st.columns([1, 1, 2])

    with col1:
        handle_register(edited_df, existing_df)

    with col2:
        clear_data()

    with col3:
        s2c.store_in_cloud(edited_df, file_class_id="rx")

# ---------- Main ----------
def run():
    # Initialize session state
    init_session_state()
    
    # Load existing data
    existing_df = load_existing_data()
    
    # Render UI components for filtering
    selected_project, selected_class = render_filters(existing_df)
    filtered_df = get_filtered_rows(existing_df, selected_project, selected_class)
    
    # Get selected rows from multiselect
    selected_rows = render_row_selector(filtered_df, existing_df)
    
    # Process data based on selection and clear state
    if st.session_state.clear_requested:
        # Clear editor data
        editor_data = pd.DataFrame(columns=COLUMNS)
        # Reset the clear flag after processing
        st.session_state.clear_requested = False
    else:
        # Get existing editor data (if any)
        editor_data = st.session_state.editor_data
        
        if not selected_rows.empty:
            # When editor is empty or has just a blank row, replace it with selected rows
            if editor_data.empty or (len(editor_data) == 1 and editor_data.iloc[0, 0] == ""):
                editor_data = selected_rows
            else:
                # Otherwise concatenate with existing data
                editor_data = pd.concat([editor_data, selected_rows], ignore_index=True).drop_duplicates()


    # Render data editor and update its state
    edited_df = render_data_editor(editor_data)
    st.session_state.editor_data = edited_df
    
    # Render action buttons
    render_action_buttons(edited_df, existing_df)

run()















##_# rx_combis





import streamlit as st
import pandas as pd
import itertools
import pandas as pd
import numpy as np
from openpyxl import Workbook
from openpyxl import load_workbook
from openpyxl.styles import PatternFill, Alignment
import os
import re
import rx_combis_tableinput as rct
import import_cat_rx as icrx

import hashlib
import re
import string
import save_to_cloud as s2c

import time
import uuid



def get_stable_key(widget_id):
    """Get or create a stable key for a widget"""
    if widget_id not in st.session_state.widget_keys:
        st.session_state.widget_keys[widget_id] = f"{widget_id}_{uuid.uuid4().hex[:8]}"
    return st.session_state.widget_keys[widget_id]

def initialize_session_state():
    """Initialize all session state variables"""
    if 'num_tables' not in st.session_state:
        st.session_state.num_tables = 2
    if 'tables_data' not in st.session_state:
        st.session_state.tables_data = {}
    if 'list_inputs' not in st.session_state:
        st.session_state.list_inputs = {}
    if 'cross_join_results' not in st.session_state:
        st.session_state.cross_join_results = {}
    if "last_selected_cols" not in st.session_state:
        st.session_state.last_selected_cols = {}

def perform_cross_join(df, list1, list2):
    """Perform cross join between dataframe and two lists"""
    # Parse lists from comma-separated strings
    list1_items = [item.strip() for item in list1.split(',') if item.strip()] if list1 else []
    list2_items = [item.strip() for item in list2.split(',') if item.strip()] if list2 else []
    
    # Start with original dataframe
    result_df = df.copy()
    
    # Add List1_Value column if list1 has items
    if list1_items:
        # Cross join with list1
        temp_rows = []
        for _, row in result_df.iterrows():
            for list1_val in list1_items:
                new_row = row.copy()
                new_row['List1_Value'] = list1_val
                temp_rows.append(new_row)
        result_df = pd.DataFrame(temp_rows).reset_index(drop=True)
    
    # Add List2_Value column if list2 has items
    if list2_items:
        # Cross join with list2
        temp_rows = []
        for _, row in result_df.iterrows():
            for list2_val in list2_items:
                new_row = row.copy()
                new_row['List2_Value'] = list2_val
                temp_rows.append(new_row)
        result_df = pd.DataFrame(temp_rows).reset_index(drop=True)
    
    return result_df

def get_default_table_data(table_num):
    """Initialize default table data"""
    columns = ["Reagents"]
    return pd.DataFrame(columns=columns)

def load_metadata_table():
    """Load and incorporate metadata table into Table 1"""
    try:
        # Call the actual function from rct module
        meta_table_one = rct.incorporate_imported_metadata()
        
        if meta_table_one is not None and not meta_table_one.empty:
            # Ensure session state is initialized
            if 'tables_data' not in st.session_state:
                st.session_state.tables_data = {}
            # Force update Table 1 (index 0) with the metadata table
            st.session_state.tables_data[0] = meta_table_one
            st.success(f"✅ Metadata table loaded into Table 1! ({len(meta_table_one)} rows)")
            return meta_table_one
        else:
            # No metadata available yet - this is normal
            st.info("ℹ️ No metadata table available yet. Use the Import/Process section above to create one.")
            
    except Exception as e:
        st.error(f"❌ Error loading metadata table: {e}")
    
    # Default fallback
    columns = ["Reagents"]
    return pd.DataFrame(columns=columns)

def render_header():
    """Render the application header"""
    st.markdown("<br><h3 style='color: #007BA7;'>Cross-Join Tables Application</h3>", unsafe_allow_html=True)

def render_configuration_section():
    """Render the configuration section for number of tables"""
    st.markdown("<br><h3 style='color: #007BA7;'>Configuration</h3>", unsafe_allow_html=True)
    col1, col2 = st.columns([1,8])
    with col2:
        num_tables = st.selectbox(
            "Number of Tables:",
            options=[1, 2, 3, 4, 5],
            index=2,  # Default to 3
            key=f"num_tables_selector_"
        )
        return num_tables

def get_reagent_files():
    """Get list of available reagent CSV files"""
    return [f for f in os.listdir('.') if f.endswith('.csv') and '_' in f]

# def handle_reagent_file_selection(table_index):
#     """Handle reagent file selection and auto-population for a table"""
#     st.markdown("##### 🔗 Auto-populate 'Reagents' Column from Registry")
    
#     reagent_files = get_reagent_files()
#     selected_rx_file = st.selectbox(
#         f"Select reagent CSV for Table {table_index+1}:",
#         reagent_files,
#         key=f"table_index_{table_index +1}"
#     ) if reagent_files else None

#     if selected_rx_file:
#         try:
#             df_rx = pd.read_csv(selected_rx_file)
#             selected_cols = st.multiselect(
#                 f"Columns to combine as Reagents:",
#                 df_rx.columns.tolist(),
#                 key=f"rx_concat_cols_{table_index+1}"
#             )

#             if selected_cols:
#                 update_reagents_from_file(table_index, df_rx, selected_cols)

#         except Exception as e:
#             st.error(f"❌ Error loading or processing reagent file: {e}")
#     else:
#         st.info("ℹ️ No reagent CSV files found with '_' in the name.")


def handle_reagent_file_selection(table_index):
    """Handle reagent file selection and auto-population for a table"""
    st.markdown("##### 🔗 Auto-populate 'Reagents' Column from Registry")
    
    reagent_files = get_reagent_files()
    selected_rx_file = st.selectbox(
        f"Select reagent CSV for Table {table_index+1}:",
        reagent_files,
        key=f"table_index_{table_index +1}"
    ) if reagent_files else None
    
    if selected_rx_file:
        try:
            df_rx = pd.read_csv(selected_rx_file)
            
            # Debug: Check what df_rx actually is
            if not isinstance(df_rx, pd.DataFrame):
                st.error(f"❌ Expected DataFrame, got {type(df_rx)}")
                return
                
            if df_rx.empty:
                st.warning("⚠️ The selected CSV file is empty.")
                return
                
            selected_cols = st.multiselect(
                f"Columns to combine as Reagents:",
                df_rx.columns.tolist(),  # This should work now
                key=f"rx_concat_cols_{table_index+1}"
            )
            if selected_cols:
                update_reagents_from_file(table_index, df_rx, selected_cols)
                
        except pd.errors.EmptyDataError:
            st.error("❌ The selected CSV file is empty or invalid.")
        except pd.errors.ParserError as e:
            st.error(f"❌ Error parsing CSV file: {e}")
        except Exception as e:
            st.error(f"❌ Error loading or processing reagent file: {e}")
    else:
        st.info("ℹ️ No reagent CSV files found with '_' in the name.")


def update_reagents_from_file(table_index, df_rx, selected_cols):
    """Update reagents column from selected file and columns"""
    reagent_series = df_rx[selected_cols].astype(str).agg(" ".join, axis=1)
    reagent_list = reagent_series.tolist()

    session_table = st.session_state.tables_data.get(table_index, pd.DataFrame())

    # Expand session_table if it's shorter than reagent_list
    if session_table.empty:
        session_table = pd.DataFrame(index=range(len(reagent_list)))
    elif len(session_table) < len(reagent_list):
        extra_rows = pd.DataFrame(index=range(len(session_table), len(reagent_list)))
        session_table = pd.concat([session_table, extra_rows], ignore_index=True)

    num_rows = len(session_table)

    # Sync reagent_list length to session_table length
    if len(reagent_list) < num_rows:
        reagent_list.extend([""] * (num_rows - len(reagent_list)))
    elif len(reagent_list) > num_rows:
        reagent_list = reagent_list[:num_rows]

    current_reagents = session_table.get("Reagents", pd.Series([""] * num_rows))
    if not current_reagents.equals(pd.Series(reagent_list)):
        session_table["Reagents"] = reagent_list
        st.session_state.tables_data[table_index] = session_table

def render_table_editor(table_index):
    """Render the data editor for a specific table"""
    if table_index not in st.session_state.tables_data:
        st.session_state.tables_data[table_index] = get_default_table_data(table_index + 1)

    edited_data = st.data_editor(
        st.session_state.tables_data.get(table_index, get_default_table_data(table_index + 1)),
        key=f"render_table_{table_index+1}",
        use_container_width=True,
        num_rows="dynamic",
        height=200
    )

    # Save user edits back to session state
    st.session_state.tables_data[table_index] = edited_data

def initialize_list_inputs(table_index):
    """Initialize list inputs for a table if not already present"""
    if table_index not in st.session_state.list_inputs:
        st.session_state.list_inputs[table_index] = {
            'list1': 'Option1, Option2, Option3',
            'list2': 'TypeA, TypeB, TypeC'
        }

def render_list_inputs(table_index):
    """Render list input controls for a table"""
    initialize_list_inputs(table_index)

    list1_input = st.text_input(
        "List 1 (comma-separated):",
        value=st.session_state.list_inputs[table_index]['list1'],
        key=f"list1_{table_index}"
    )

    list2_input = st.text_input(
        "List 2 (comma-separated):",
        value=st.session_state.list_inputs[table_index]['list2'],
        key=f"list2_{table_index}"
    )

    st.session_state.list_inputs[table_index]['list1'] = list1_input
    st.session_state.list_inputs[table_index]['list2'] = list2_input

    if st.button(f"Update Cross-Join", key=f"cross_join_update_{table_index}"):
        result = perform_cross_join(
            st.session_state.tables_data[table_index],
            list1_input,
            list2_input
        )
        st.session_state.cross_join_results[table_index] = result

def get_or_create_cross_join_result(table_index):
    """Get existing cross-join result or create a new one"""
    if table_index in st.session_state.cross_join_results:
        return st.session_state.cross_join_results[table_index]
    else:
        result_df = perform_cross_join(
            st.session_state.tables_data[table_index],
            st.session_state.list_inputs[table_index]['list1'],
            st.session_state.list_inputs[table_index]['list2']
        )
        st.session_state.cross_join_results[table_index] = result_df
        return result_df

def render_cross_join_result(table_index):
    """Render the cross-join result for a table"""
    result_df = get_or_create_cross_join_result(table_index)
    
    st.write(f"**Cross-Join Result for Table {table_index+1}** ({len(result_df)} rows):")
    st.dataframe(result_df, use_container_width=True)

def render_single_table(table_index):
    """Render a complete table section including editor, inputs, and results"""
    st.markdown(f"<br><h3 style='color: #007BA7;'>Table {table_index+1}</h3>", unsafe_allow_html=True)

    # Create columns for table and list inputs
    margin, left_col, right_col = st.columns([1, 5, 3])

    with left_col:
        # Handle reagent file selection for tables 2 and above
        if table_index >= 1:
            handle_reagent_file_selection(table_index)

        # Render the editable table
        render_table_editor(table_index)

    with right_col:
        # Render list inputs and update button
        render_list_inputs(table_index)
    with left_col:
    # Render cross-join result
        render_cross_join_result(table_index)
    
    st.write("---")

def combine_all_results(num_tables):
    """Combine all cross-join results into a single dataframe"""
    combined_dfs = []
    
    for i in range(num_tables):
        if i in st.session_state.cross_join_results:
            df_copy = st.session_state.cross_join_results[i].copy()
            df_copy['Source_Table'] = f'Table_{i+1}'  # Add source identifier
            combined_dfs.append(df_copy)
    
    if combined_dfs:
        return pd.concat(combined_dfs, ignore_index=True)
    return None

def create_excel_export(final_combined_df, num_tables):
    """Create Excel file with multiple sheets"""
    excel_buffer = BytesIO()
    
    with pd.ExcelWriter(excel_buffer, engine='openpyxl') as writer:
        # Write combined data to main sheet
        final_combined_df.to_excel(writer, sheet_name='Combined_All_Tables', index=False)
        
        # Write individual tables to separate sheets
        for i in range(num_tables):
            if i in st.session_state.cross_join_results:
                st.session_state.cross_join_results[i].to_excel(
                    writer, 
                    sheet_name=f'Table_{i+1}_CrossJoin', 
                    index=False
                )
    
    excel_buffer.seek(0)
    return excel_buffer

def render_export_section(num_tables):
    """Render the combined export section"""
    st.markdown("<br><h3 style='color: #007BA7;'>Combined Export</h3>", unsafe_allow_html=True)

    # if st.button("Generate Combined Metadata Table", type="primary"):
    final_combined_df = combine_all_results(num_tables)
        
    if final_combined_df is not None:
            # st.write(f"**Combined Dataset** ({len(final_combined_df)} total rows from {sum(1 for i in range(num_tables) if i in st.session_state.cross_join_results)} tables):")
            # st.dataframe(final_combined_df, use_container_width=True)
            
            # # Create Excel file
            # excel_buffer = create_excel_export(final_combined_df, num_tables)
            
            # # Download button for Excel file
            # st.download_button(
            #     label="📥 Download Combined Excel File (.xlsx)",
            #     data=excel_buffer.getvalue(),
            #     file_name="combined_cross_join_tables.xlsx",
            #     mime="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
            # )
            
            # # Also provide CSV option
            # csv_combined = final_combined_df.to_csv(index=False)
            # st.download_button(
            #     label="📥 Download Combined CSV File",
            #     data=csv_combined,
            #     file_name="combined_cross_join_tables.csv",
            #     mime="text/csv"
            # )
            s2c.store_in_cloud(final_combined_df, file_class_id="meta_d")
    else:
        st.warning("No cross-join results available. Please update cross-joins for your tables first.")

def run():
    """Main application function"""
    # Initialize session state
    initialize_session_state()
    
    # Render header
    render_header()
    
    # Load metadata table
    meta_table_one = load_metadata_table()
    
    # Render configuration section
    num_tables = render_configuration_section()
    
    # Main tables section
    st.markdown("<br><h3 style='color: #007BA7;'>Tables and Cross-Join Configuration</h3>", unsafe_allow_html=True)
    
    # Render each table
    for i in range(num_tables):
        render_single_table(i)
    
    # Render export section
    render_export_section(num_tables)

run()






##_# xl_serial_dil



import os
import math
import itertools
import numpy as np
import pandas as pd
from math import log10, floor
from openpyxl import Workbook, load_workbook
from openpyxl.styles import PatternFill, Alignment
import colorsys
import streamlit as st
import hashlib
import uuid

import re
import save_to_cloud as s2c
import import_cat_rx as icrx


def import_file():
    # File uploader for CSV or Excel files
    uploaded_file = st.file_uploader("Upload a CSV or Excel file", type=["csv", "xls", "xlsx"])
    
    if uploaded_file is not None:
        # Get file extension
        file_ext = os.path.splitext(uploaded_file.name)[1].lower()
        
        try:
            if file_ext == ".csv":
                # Read CSV file
                df = pd.read_csv(uploaded_file)
                return df
            
            elif file_ext in [".xls", ".xlsx"]:
                # Read Excel file to get sheet names
                xl = pd.ExcelFile(uploaded_file)
                sheet_names = xl.sheet_names
                
                # Let user select sheet
                selected_sheet = st.selectbox("Select a sheet", sheet_names)
                
                # Read selected sheet into DataFrame
                df = pd.read_excel(uploaded_file, sheet_name=selected_sheet)
                return df
                
        except Exception as e:
            st.error(f"Error reading file: {str(e)}")
            return None
    
    return None

# Gen colors to label reagents
def generate_rainbow_colors(num_colors):

    # Generate num_colors distinct colors in the HSL color space
    colors = []
    
    # Hue ranges from 0 to 1 (where 0 is red, 0.33 is green, and 0.66 is blue)
    # Saturation and lightness are kept constant to create lighter pastel colors
    for i in range(num_colors):
        hue = i / num_colors  # Evenly distribute the hues across the color wheel
        lightness = 0.85      # Light pastel color
        saturation = 0.4      # Moderate saturation for good visibility
        
        # Convert HSL to RGB
        r, g, b = colorsys.hls_to_rgb(hue, lightness, saturation)
        
        # Convert RGB to hex format
        hex_color = f"{int(r * 255):02X}{int(g * 255):02X}{int(b * 255):02X}"
        colors.append(hex_color)
    
    return colors

# Function to generate serial dilution series
def serial_dilute(high_conc, fold, num_points_in_curv, fold_dil_to_well):
    concentrations = []
    current_conc = high_conc * fold_dil_to_well
    for _ in range(num_points_in_curv):
        concentrations.append(current_conc)
        current_conc /= fold
    return concentrations

# Function to calculate dilution details
def calculate_dilution(well_count, units, vol_per_well, vol_per_well_units, concentration_series):
    d_serialdil = pd.DataFrame({
        f'Concentration ({units})': concentration_series
    })
    
    # Add well count to the dataframe
    wells = [well_count] * (len(d_serialdil) - 1)
    wells.insert(0, 0)
    d_serialdil['Well count'] = wells

    # Add volume per well to the dataframe
    vols = [vol_per_well] * (len(d_serialdil) - 1)
    vols.insert(0, 0)
    d_serialdil[f'Vol. per well (mL)'] = vols

    # Calculate pipetting loss adjustment
    d_serialdil['Pipetting loss adjustment'] = 0.1 + 1.002 ** d_serialdil['Well count']

    # Calculate dilution-specific values
    d_serialdil['Fold of serial dilution'] = d_serialdil[f'Concentration ({units})'].shift(1) / d_serialdil[f'Concentration ({units})']
    d_serialdil['Diluent (mL)'] = d_serialdil['Well count'] * d_serialdil[f'Vol. per well (mL)'] * d_serialdil['Pipetting loss adjustment']
    
    # Adjust row 2 manually (after the above calculation)
    d_serialdil.loc[1, 'Diluent (mL)'] = d_serialdil.loc[1, 'Diluent (mL)'] * d_serialdil.loc[2:, 'Fold of serial dilution'].max()

    # Calculate transferred volume
    d_serialdil['Prior dilution (mL)'] = d_serialdil['Diluent (mL)'] / (d_serialdil['Fold of serial dilution'] - 1)
    
    # Set the first row (for calculation purposes) to NaN
    d_serialdil.iloc[0, 1:] = None

    return d_serialdil

# Adjust volumes to minimal pipettable volume
def adjust_well_count(min_pipettable_vol, stock, top_dil, fold_dil, num_dils, fold_to_well, well_count, units, vol_per_well, vol_per_well_units):
    concentration_series = [stock] + serial_dilute(top_dil, fold_dil, num_dils, fold_to_well)
    
    d_serialdil = calculate_dilution(well_count, units, vol_per_well, vol_per_well_units, concentration_series)
    min_transferred_volume = d_serialdil['Prior dilution (mL)'].min()

    # Continue running the calculation as long as the minimum transferred volume is less than 0.03
    while min_transferred_volume < min_pipettable_vol:
        well_count += 10**(math.floor(math.log10(min_pipettable_vol / min_transferred_volume)) - 1)
        well_count = math.ceil(well_count)
        print(f"\nIncreasing well count to {well_count} and recalculating...")

        # Re-run the function with the updated well_count
        d_serialdil = calculate_dilution(well_count, units, vol_per_well, vol_per_well_units, concentration_series)
        
        # Update the minimum transferred volume
        min_transferred_volume = d_serialdil['Prior dilution (mL)'].min()

    return d_serialdil, well_count


def create_stacked_excel_file_with_reagents(d_serialdil_list, reagent_names, reagent_colors, output_file="stacked_dilution_tables_with_reagents.xlsx", rounding_precision=2):
    # Create a new workbook and get the active sheet
    wb = Workbook()
    ws = wb.active

    # Set column widths for the first 7 columns
    column_widths = {
        1: 15,  # Column A (Concentration) width
        2: 15,  # Column B (Volume) width
        3: 15,  # Column C (Amount) width
        4: 15,  # Column D width (Pipetting Loss Adjustment)
        5: 15,  # Column E width (Fold Dilution)
        6: 15,  # Column F width (Volume of Diluent)
        7: 15   # Column G width (Transferred Volume)
    }
    
    for col_num, width in column_widths.items():
        ws.column_dimensions[chr(64 + col_num)].width = width

    # Define the colors for columns F and G (green and orange)
    green_fill = PatternFill(start_color="b3cde0", end_color="b3cde0", fill_type="solid")
    orange_fill = PatternFill(start_color="6497b1", end_color="6497b1", fill_type="solid")

    # Initialize row for the first table
    start_row = 5

    # Iterate over all the d_serialdil tables and their respective reagent names
    for i, (d_serialdil, reagent_name) in enumerate(zip(d_serialdil_list, reagent_names)):
        reagent_color = reagent_colors[i]  # This should be in RGB hex format like "FFA500"
        fill_color = PatternFill(start_color=reagent_color, end_color=reagent_color, fill_type="solid")
        # Insert reagent name above the table (in the first column)
        ws.cell(row=start_row, column=1, value=f"{reagent_name}")
        # Merge cells for the reagent name so it spans the first 7 columns
        ws.merge_cells(start_row=start_row, start_column=1, end_row=start_row, end_column=7)
        # Set the alignment to center for the reagent name
        ws.cell(row=start_row, column=1).alignment = Alignment(horizontal="center", vertical="center")
        # Apply the color to the reagent name cell
        ws.cell(row=start_row, column=1).fill = fill_color

        # Move to the next row for the table (start from the next row after the reagent name)
        start_row += 1

        # Write the header row for each table
        for col_num, column_name in enumerate(d_serialdil.columns, 1):
            header_cell = ws.cell(row=start_row, column=col_num, value=column_name)
            # Set the text wrapping for header cells
            header_cell.alignment = Alignment(wrap_text=True)
        
        # Adjust the row height for the header row to fit the wrapped text
        ws.row_dimensions[start_row].height = 30  # Adjust this value for more/less height

        # Write the data rows (including formulas for pipetting loss, fold dilution, volume of diluent, transferred volume)
        for row_num, row in enumerate(d_serialdil.itertuples(index=False), start=start_row + 1):
            # Write the values for the first 3 columns
            for col_num, value in enumerate(row, 1):
                if col_num < 4:  # Concentration, Volume, Amount columns
                    ws.cell(row=row_num, column=col_num, value=value)

            # Add Excel formulas starting from row 2 and copy down
            ws[f'D{row_num}'] = f"=ROUND(0.1 + 1.002^B{row_num}, 3)"  # Pipetting loss factor
            ws[f'E{row_num}'] = f"=ROUND(A{row_num - 1} / A{row_num}, 3)"  # Fold dilution formula
            ws[f'F{row_num}'] = f"=B{row_num} * C{row_num} * D{row_num}"  # Volume of diluent formula
            
            # Adjust for row 3 (max fold dilution adjustment)
            if row_num == start_row + 2:  # Adjust for row 2
                ws[f'F{row_num}'] = f"=ROUND(B{row_num} * C{row_num} * D{row_num} + B{row_num+1} * C{row_num+1} * D{row_num+1} * (MAX(E{row_num+1}:E{start_row+len(d_serialdil)}) - 0.9), 5)"

            # Transferred volume formula
            ws[f'G{row_num}'] = f"=ROUND(F{row_num} / (E{row_num} - 1), 5)"
            
            # Now, clear values for columns 2 to 7 if it's the second row (after the header row)
            if row_num == start_row + 1:
                for col in range(2, 8):
                    ws.cell(row=row_num, column=col).value = None

        # Apply color to columns F and G (start from row 2, not header row)
        for row_num in range(start_row + 1, start_row + len(d_serialdil) + 1):
            # Column F (Green)
            ws.cell(row=row_num, column=6).fill = green_fill
            # Column G (Orange)
            ws.cell(row=row_num, column=7).fill = orange_fill

        # Round the values in Column A (Concentration) without affecting the other columns
        for row_num in range(start_row + 1, start_row + len(d_serialdil) + 1):
            # Round Column A (Concentration) value to the specified precision
            concentration_cell = ws.cell(row=row_num, column=1)
            concentration_cell.value = round(concentration_cell.value, rounding_precision)

        # Update start_row for the next table: Adding 3 blank rows between tables
        start_row += len(d_serialdil) + 3

    # Save the workbook to the specified file
    wb.save(output_file)
    print(f"Excel file saved as {output_file}")

# Make multiple reagent dilution calcs
def make_stacked_excel_example(dilution_params_df, reagent_names):
    # Initialize lists to store the dilution tables and well counts
    d_serialdil_list = []
    well_count_list = []

    # Loop through the rows of the DataFrame and adjust well counts
    for _, params in dilution_params_df.iterrows():
        d_serialdil, well_count = adjust_well_count(
            params["min_pipettable_vol"],
            params["stock"],
            params["top_dil"],
            params["fold_dil"],
            params["num_dils"],
            params["fold_to_well"],
            params["well_count"],
            params["units"],
            params["vol_per_well"],
            params["vol_per_well_units"]
        )
        #d_serialdil = round_numeric_values(d_serialdil)
        d_serialdil_list.append(d_serialdil)
        well_count_list.append(well_count)
    
    # Create reagent names list
    reagent_names = reagent_names
    reagent_colors = generate_rainbow_colors(len(reagent_names))
    
    # Create and save the stacked Excel file with reagents and custom colors
    create_stacked_excel_file_with_reagents(d_serialdil_list, reagent_names, reagent_colors, output_file="stacked_dilution_tables.xlsx")

# Make sure table is filled out correctly
def validate_dilution_table(df):
    issues = []

    # Define expected types and values
    numeric_columns = ["stock", "top_dil", "fold_dil", "num_dils", "fold_to_well",
                       "min_pipettable_vol", "well_count", "vol_per_well"]
    valid_units = ["ng/mL", "ug/mL", "uM", "nM"]
    valid_vol_units = ["mL", "uL"]

    # Check for missing values
    if df.isnull().values.any():
        issues.append("• Missing values detected in the table.")

    # Check numeric columns
    for col in numeric_columns:
        if not pd.api.types.is_numeric_dtype(df[col]):
            issues.append(f"• Column '{col}' must be numeric.")

    # Check valid entries for 'units'
    if not df["units"].isin(valid_units).all():
        invalid_units = df.loc[~df["units"].isin(valid_units), "units"].unique()
        issues.append(f"• Invalid unit(s) in 'units': {invalid_units.tolist()}")

    # Check valid entries for 'vol_per_well_units'
    if not df["vol_per_well_units"].isin(valid_vol_units).all():
        invalid_vol_units = df.loc[~df["vol_per_well_units"].isin(valid_vol_units), "vol_per_well_units"].unique()
        issues.append(f"• Invalid unit(s) in 'vol_per_well_units': {invalid_vol_units.tolist()}")

    # Final output
    if issues:
        # Add indentation to each issue
        formatted_issues = ["&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;  " + issue for issue in issues]
        
        st.write(
            "The following issues were found in the table:<br><br>" + "<br>".join(formatted_issues),
            unsafe_allow_html=True
        )

        table_passed = False
    else:
        st.success("✅ Validation passed! All values are valid.")
        table_passed = True

    return table_passed

# Example of how the DataFrame would look
d_demo = {
    "reagent": ["Reagent 1", "Reagent 2", "Reagent 3"],
    "stock": [40000, 30000, 50000],
    "top_dil": [400, 400, 400],
    "fold_dil": [2, 2, 2],
    "num_dils": [4, 4, 4],
    "fold_to_well": [2, 2, 2],
    "min_pipettable_vol": [0.001, 0.001, 0.001],
    "well_count": [10, 10, 10],
    "units": ["ng/mL", "ng/mL", "ng/mL"],
    "vol_per_well": [0.1, 0.1, 0.1],
    "vol_per_well_units": ["mL", "mL", "mL"]
}



def initialize_data():
    """Initialize basic data structures"""
    columns = [
        "reagent", "stock", "top_dil", "fold_dil", "num_dils", "fold_to_well", 
        "min_pipettable_vol", "well_count", "units", "vol_per_well", "vol_per_well_units"
    ]
    df = pd.DataFrame(columns=columns)
    allowed_units = ["fold", "nM", "uM", "mM", "mg/mL", "ug/mL", "ng/mL"]
    return df, columns, allowed_units

def render_headers():
    """Render the main headers"""
    st.markdown("""
        <br>
        <h4 style='color: #007BA7;'>Input dilution parameters to calculate serial dilutions</h4>
    """, unsafe_allow_html=True)
    st.markdown("""
        <br>
        <h5 style='color: #007BA7;'>Step 1 - Choose data source</h5>
    """, unsafe_allow_html=True)

# def render_data_source_selection(df):
#     """Render data source radio buttons and template download"""
#     col1, col2 = st.columns([1,2])
#     with col1:
#         data_source = st.radio(
#             "Choose", 
#             ["Start a new table", "Stored dilution parameters", "Upload a table", "Demo data"],
#             key="data_source_selection"
#         )
#     with col2:
#         csv = df.to_csv(index=False)
#         st.download_button(
#             label="⬇️ Download dilution template",
#             data=csv,
#             file_name="dilution_parameter_template.csv",
#             mime="text/csv"
#         )
#     return data_source

import time

def render_data_source_selection(df):
    """Render data source radio buttons and template download"""
    col1, col2 = st.columns([1,2])
    with col1:
        data_source = st.radio(
            "Choose", 
            ["Start a new table", "Stored dilution parameters", "Upload a table", "Demo data"],
            key=f"data_source_selection_{int(time.time() * 1000000)}"  # microsecond precision
        )
    with col2:
        csv = df.to_csv(index=False)
        st.download_button(
            label="⬇️ Download dilution template",
            data=csv,
            file_name="dilution_parameter_template.csv",
            mime="text/csv",
            key = f"data_source_selection_{int(time.time() * 1000000)}"
        )
    return data_source

def handle_new_table_source(columns):
    """Handle 'Start a new table' data source"""
    df = pd.DataFrame(columns=columns)
    df.loc[0] = [None] * len(columns)
    col1, col2, col3 = st.columns([1, 3, 5])
    with col2:
        reagent_list, rx_reg_table = icrx.process_and_concatenate_columns()
    if len(df) > len(reagent_list):
        df["reagent"] = reagent_list + [None] * (len(df) - len(reagent_list))
    elif len(df) < len(reagent_list):
        df = df.reindex(range(len(reagent_list)))
        df["reagent"] = reagent_list
    else:
        df["reagent"] = reagent_list
    with col3:
        if len(rx_reg_table) > 0:
            st.markdown("""
                <br>
                <h5 style='color: #007BA7;'>Reagent Registery Table</h5>
            """, unsafe_allow_html=True)
            st.write(rx_reg_table)
    return df

def handle_stored_parameters_source():
    """Handle 'Stored dilution parameters' data source"""
    d_i = icrx.select_and_import_csv()    
    if d_i is not None and len(d_i) > 1:
        return pd.DataFrame(d_i)
    return None

def handle_upload_source():
    """Handle 'Upload a table' data source"""
    d_i = import_file()
    if d_i is not None and len(d_i) > 1:  
        return pd.DataFrame(d_i)
    return None

def handle_demo_source():
    """Handle 'Demo data' source"""
    return pd.DataFrame(d_demo)

def get_dataframe_by_source(data_source, columns):
    """Get dataframe based on selected data source"""
    if data_source == "Start a new table":
        return handle_new_table_source(columns)
    elif data_source == "Stored dilution parameters":
        result = handle_stored_parameters_source()
        return result if result is not None else pd.DataFrame(columns=columns)
    elif data_source == "Upload a table":
        result = handle_upload_source()
        return result if result is not None else pd.DataFrame(columns=columns)
    else:
        return handle_demo_source()

def render_step2_and_editor(df, allowed_units):
    """Render Step 2 header and data editor"""
    st.markdown("""
        <br>
        <h5 style='color: #007BA7;'>Step 2 - Fill in dilution parameters:</h5>
    """, unsafe_allow_html=True)
    d_entries = st.data_editor(df.reset_index(drop=True), num_rows="dynamic", key=f"data_source_selection_{int(time.time() * 1000000)}", 
    hide_index=True, column_config={
        "units": st.column_config.SelectboxColumn(
            "units",
            options=allowed_units,
            required=True  # Optional: make selection required
        )
    })
    return d_entries

def render_validation_section(d_entries):
    """Render validation expander and return validation status"""
    with st.expander(":vertical_traffic_light: CLICK HERE to see remaining updates required for this dilution table:"):
        st.write("Once the following issues are corrected, you will see a button to export the dilution tables.")
        validated = validate_dilution_table(d_entries)
    return validated

def handle_export_section(d_entries, validated):
    """Handle data storage and export functionality"""
    # st.write(d_entries.iloc[:, 1:])
    # st.write(d_entries.iloc[:,0])
    s2c.store_in_cloud(d_entries, file_class_id="dil_params")
    if st.button(":arrow_down: Export calculated dilutions", disabled=not validated, key = f"_Export Dilz_{int(time.time() * 1000000)}"):
        make_stacked_excel_example(d_entries.iloc[:, 1:], d_entries.iloc[:,0])
        st.success("File was exported as 'stacked_dilution_tables.xlsx'")

def run():
    """Main function to run the dilution parameters application"""
    # Initialize data
    df, columns, allowed_units = initialize_data()
    
    # Render headers
    render_headers()
    
    # Handle data source selection
    data_source = render_data_source_selection(df)
    
    # Get dataframe based on source
    df = get_dataframe_by_source(data_source, columns)
    
    # Process if dataframe has data
    if len(df) > 0:
        # Render editor
        d_entries = render_step2_and_editor(df, allowed_units)
        
        # Handle validation
        validated = render_validation_section(d_entries)
        
        # Handle export
        handle_export_section(d_entries, validated)

run()






##_# calculate_dilutions



import os
import math
import itertools
import pandas as pd
import numpy as np
from openpyxl import Workbook, load_workbook
from openpyxl.styles import PatternFill, Alignment
import colorsys
import string

# CREATE THE INPUT DILUTION INITIATOR TABLE

# PULL IN REAGENT LIST WITH ASSOCIATED DATA

import streamlit as st
import pandas as pd



# def display_selected_columns_table(df):
#     """
#     Display a multiselect tool with 'Select All' and 'Clear All' buttons
#     for choosing which columns to populate in the second table.
#     """
#     st.write("### Original DataFrame")
#     st.dataframe(df)

#     # Initialize session state for selected columns
#     if "selected_columns" not in st.session_state:
#         st.session_state.selected_columns = []

#     # Buttons to select or clear all
#     col1, col2, col3, col4 = st.columns([3, 1, 1, 2])
#     with col1:
#         selected_columns = st.multiselect(
#             "Select columns to populate in the second table:",
#             options=df.columns,
#             default=st.session_state.selected_columns,
#             key="selected_columns"
#         )
#     with col2:
#         if st.button("Select All"):
#             st.session_state.selected_columns = list(df.columns)
#     with col3:
#         if st.button("Clear All"):
#             st.session_state.selected_columns = []

#     # Multiselect widget controlled by session state

#     # Create a blank DataFrame with the same columns
#     blank_data = {col: [''] * len(df) for col in df.columns}
#     second_table_df = pd.DataFrame(blank_data)

#     # Populate selected columns
#     for col in selected_columns:
#         second_table_df[col] = df[col]

#     st.write("### Second Table (Blank by Default, Columns Populated by Selection)")
#     st.data_editor(second_table_df)

def display_selected_columns_table(df):
    """
    Display a multiselect tool with 'Select All' and 'Clear All' buttons
    to choose which columns to populate in the second table.
    """
    st.write("### Original DataFrame")
    st.dataframe(df)

    # Initialize session state
    if "selected_columns" not in st.session_state:
        st.session_state.selected_columns = []

    # Handle button presses BEFORE the multiselect is drawn
    col1, col2, col3, col4 = st.columns([1, 1, 3, 2])
    with col1:
        if st.button("Transfer All Cols"):
            st.session_state.selected_columns = list(df.columns)
            st.rerun()
    with col2:
        if st.button("Clear All Cols"):
            st.session_state.selected_columns = []
            st.rerun()
    with col3:
        selected_columns = st.multiselect(
            "Transfer individual columns:",
            options=df.columns,
            default=st.session_state.selected_columns,
            key="selected_columns"
        )

    # Create a blank DataFrame with the same columns
    blank_data = {col: [''] * len(df) for col in df.columns}
    second_table_df = pd.DataFrame(blank_data)

    # Populate only the selected columns
    for col in selected_columns:
        second_table_df[col] = df[col]

    st.write("### Second Table (Blank by Default, Columns Populated by Selection)")
    st.data_editor(second_table_df)


# Example: Creating a sample DataFrame
data = {
    'A': [1, 2, 3, 4],
    'B': [5, 6, 7, 8],
    'C': [9, 10, 11, 12],
    'D': [13, 14, 15, 16]
}
df = pd.DataFrame(data)

# Streamlit App
def main():
    st.title("Column Selector for Data Editor")
    display_selected_columns_table(df)

if __name__ == "__main__":
    main()







##_# p_transform




import streamlit as st
import pandas as pd
import numpy as np
import openpyxl
from io import BytesIO

# Function to transform the plate data
def transform_plate(input_data):
    original_header = list(input_data[0])  # Store the first row as header
    
    plate_96 = pd.DataFrame(input_data)
    plate_96 = plate_96.drop(index=0).reset_index(drop=True)  # Drop first row (header)
    plate_96 = plate_96.drop(columns=0).reset_index(drop=True)  # Drop first column (index column)
    
    # Reverse the rows
    plate_96_sorted = plate_96.iloc[::-1].reset_index(drop=True)
    
    # Add blank rows between each row
    plate_96_with_gaps = []
    for _, row in plate_96_sorted.iterrows():
        plate_96_with_gaps.append(row.values.tolist())
        plate_96_with_gaps.append([None] * len(row))
    
    plate_96_with_gaps = pd.DataFrame(plate_96_with_gaps)
    
    # Rotate 90 degrees
    plate_384_rotated = plate_96_with_gaps.transpose().reset_index(drop=True)
    
    # Shift every other row by one cell
    for i in range(1, len(plate_384_rotated), 2):
        plate_384_rotated.iloc[i] = plate_384_rotated.iloc[i].shift(1)
    
    # Ensure exactly 16 data rows
    while len(plate_384_rotated) < 16:
        plate_384_rotated.loc[len(plate_384_rotated)] = [None] * plate_384_rotated.shape[1]
    
    # Determine the highest numeric column in the original header and extend to 24
    max_numeric = max([int(x) for x in original_header[1:] if str(x).isdigit()], default=0)
    new_columns = [original_header[0]] + [str(i) for i in range(1, 25)]
    
    # Ensure exactly 25 total columns
    plate_384_rotated = plate_384_rotated.reindex(columns=range(25))
    plate_384_rotated.columns = new_columns[:25]
    
    # Add row labels A-P in column 1, starting in the first row below the header row
    rows = list("ABCDEFGHIJKLMNOP")[:16]
    plate_384_rotated.iloc[:16, 0] = rows
    # Extract data as a NumPy array
    sub_array = plate_384_rotated.iloc[0:14, 1:15].to_numpy()

    # Clear the original section
    plate_384_rotated.iloc[0:14, 1:15] = None  # Replace with None (or '' for empty)

    # Paste it 1 row down and 1 column to the right
    plate_384_rotated.iloc[1:15, 2:16] = sub_array  # Assign back to new location

    return plate_384_rotated

def main():
    st.title("Plate Transformation Tool")
    
    st.markdown("""
    Upload a 96-well plate (8x12 format), and this tool will transform it into a 384-well format (16x24),
    ensuring the final output has 24 columns and 17 rows.
    """)
    
    uploaded_file = st.file_uploader("Upload CSV file", type=["csv"])
    
    if uploaded_file is not None:
        try:
            input_data = pd.read_csv(uploaded_file, header=None)
            st.subheader("Original Plate Data")
            st.write(input_data)
            
            output_plate = transform_plate(input_data.values)
            st.subheader("Transformed Plate Data")
            st.write(output_plate)
            
            # Convert the DataFrame to an Excel file in memory
            output = BytesIO()
            with pd.ExcelWriter(output, engine="xlsxwriter") as writer:
                output_plate.to_excel(writer, index=False, sheet_name="Transformed Data")
            output.seek(0)  # Move to the beginning of the file

            # Add a download button
            st.download_button(
                label="Download as Excel",
                data=output,
                file_name="transformed_plate.xlsx",
                mime="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
            )
            
        except Exception as e:
            st.error(f"Error processing the file: {e}")

if __name__ == "__main__":
    main()









##_# p_rot


import streamlit as st
import pandas as pd
import openpyxl

def find_cells_with_a_and_b(df):
    result = []
    rows, cols = df.shape

    # Loop through the dataframe to find "A" or "a"
    for row in range(rows):
        for col in range(cols):
            if str(df.iloc[row, col]).lower() == 'a':
                # Check surrounding cells with bounds check to avoid IndexError
                if row + 1 < rows and str(df.iloc[row + 1, col]).lower() == 'b':
                    current_row = row + 1  # Start from the row below "A"
                    letter_chain = ['a']  # To keep track of letters found below "B"
                    
                    # Start while loop to check for subsequent letters like C, D, etc.
                    while current_row < rows:
                        next_value = str(df.iloc[current_row, col]).lower()
                        
                        # Stop if the value is empty or not a single letter
                        if next_value == "" or len(next_value) != 1 or not next_value.isalpha():
                            break
                        
                        letter_chain.append(next_value)  # Add letter to the chain
                        current_row += 1  # Move to the next row
                    
                    # Add result with 5 elements
                    final_row = current_row + 1  # The last valid row with a letter
                    result.append((row - 1, col, "Below", letter_chain, final_row))  # Ensure 5 elements in tuple

                # Handle other directions (Above, Left, Right)
                elif row - 1 >= 0 and str(df.iloc[row - 1, col]).lower() == 'b':
                    current_row = row - 1 
                    letter_chain = ['a']
                    
                    # Start while loop to check for subsequent letters like C, D, etc.
                    while current_row < rows:
                        next_value = str(df.iloc[current_row, col]).lower()
                        
                        # Stop if the value is empty or not a single letter
                        if next_value == "" or len(next_value) != 1 or not next_value.isalpha():
                            break
                        
                        letter_chain.append(next_value)  # Add letter to the chain
                        current_row -= 1  # Move to the prior row
                    
                    final_row = current_row - 1  # The last valid row with a letter
                    result.append((row + 1, col, "Above", letter_chain, final_row))

                    current_col = col
                    st.write(current_col)
                    while current_col >= 0:
                        next_value = df.iloc[row, current_col-1]

                        if isinstance(next_value, (int, float)):  # Check if the value is an integer or float
                            chain.append(next_value)  # Add the integer to the chain
                        else:
                            # Stop if it's not an integer or is empty
                            if next_value == "" or not isinstance(next_value, (int, float)):
                                break

                        current_col -= 1
                    
                    final_col = current_col + 1  # The last valid column with an integer
                    result.append((row + 1, col, "Above", chain, final_col))               

                elif col - 1 >= 0 and str(df.iloc[row, col - 1]).lower() == 'b':

                    current_col = col - 1 
                    letter_chain = ['a']
                    
                    while current_col < cols:
                        next_value = str(df.iloc[row, current_col]).lower()

                        if next_value == "" or len(next_value) != 1 or not next_value.isalpha():
                            break
                        
                        letter_chain.append(next_value)
                        current_col -= 1  # Move to the prior row

                    final_col = current_col - 1
                    result.append((row, col + 1, "Left", letter_chain, final_col))


                elif col + 1 < cols and str(df.iloc[row, col + 1]).lower() == 'b':

                    current_col = col + 1 
                    letter_chain = ['a']  
                    
                    while current_col < cols:
                        next_value = str(df.iloc[row, current_col]).lower()

                        if next_value == "" or len(next_value) != 1 or not next_value.isalpha():
                            break
                        
                        letter_chain.append(next_value)
                        current_col += 1
                    
                    final_col = current_col + 1
                    result.append((row, col - 1, "Right", letter_chain, final_col))

    return result


# Function to read CSV or Excel files
def read_file(file):
    if file.name.endswith('.csv'):
        return pd.read_csv(file)
    elif file.name.endswith('.xlsx'):
        excel_data = pd.ExcelFile(file)
        sheet_name = st.selectbox("Select Sheet", excel_data.sheet_names)
        return pd.read_excel(file, sheet_name=sheet_name)
    else:
        st.error("Please upload a CSV or Excel file")
        return None

# Streamlit UI
def main():
    st.title("Excel/CSV Cell Scanner")
    
    file = st.file_uploader("Upload a CSV or Excel file", type=["csv", "xlsx"])
    
    if file is not None:
        df = read_file(file)
        
        if df is not None:
            st.write("File Preview:")
            st.write(df)

            # Find instances of 'A' or 'a' and check surrounding cells
            result = find_cells_with_a_and_b(df)

            if result:
                st.write("Found Instances of 'A' and 'B' (with downward letters):")
                # Ensure all tuples have the correct structure (5 elements)
                result_df = pd.DataFrame(result, columns=["start Row", "start Col", "Direction", "Chain", "Final val"])
                st.write(result_df)
            else:
                st.write("No instances of 'A' or 'a' with surrounding 'B' or 'b' found.")
        else:
            st.error("Unable to read the file. Please check its format.")
    
if __name__ == "__main__":
    main()


##_# ctrl_to_384


import streamlit as st
import pandas as pd
import numpy as np
from io import BytesIO

# Function to transform the plate data and populate control values
def transform_plate(control_values):
    # Create an empty 384-well plate (24x24) to handle the placement correctly
    plate_384 = pd.DataFrame(np.full((24, 24), ""))
    
    # Initialize a row and column index for placing control values
    control_idx = 0

    # Loop through control values and place them in the 384-well plate
    for row in range(0, len(control_values)):
        if control_idx < len(control_values):
            control_value = control_values[control_idx]
            eoo = control_idx % 2 == 0

            plate_384.iloc[row, 17 + eoo] = control_value  # Column 2 (B)
            plate_384.iloc[row, 19 + eoo] = control_value  # Column 4 (D)
            plate_384.iloc[row, 21 + eoo] = control_value  # Column 6 (F)
            
            control_idx += 1  # Move to the next control value

    # Set row labels A-P (24 rows)
    plate_384.index = list("ABCDEFGHIJKLMNOPQRSTUVWX")  # 24 row labels

    # Column headers 1-24
    plate_384.columns = [str(i) for i in range(1, 25)]
    
    return plate_384

def main():
    st.title("Plate Transformation Tool with Manual Controls")
    
    st.markdown("""
    Enter control values into the table below. The controls will be placed into the 384-well format (24x24) 
    starting from B18, in triplicates across every other column.
    """)
    
    # Create an editable dataframe to input control values into the first column
    control_data = pd.DataFrame({
        'Row': list("ABCDEFGHIJKLMNO"),  # Rows A-P (15 rows for control values)
        'Control': [""] * 15  # Empty cells for control values
    })
    
    # Display the data editor
    control_values_df = st.data_editor(control_data, use_container_width=True)
    
    # Extract the control values (first column) and filter out None values
    control_values = control_values_df['Control'].dropna().values.tolist()

    # Ensure control values are entered
    if control_values:
        # Transform the plate with control values
        output_plate = transform_plate(control_values)
        
        st.subheader("Transformed Plate Data with Controls")
        st.write(output_plate)
        
        # Convert the DataFrame to an Excel file in memory
        output = BytesIO()
        with pd.ExcelWriter(output, engine="xlsxwriter") as writer:
            output_plate.to_excel(writer, index=True, sheet_name="Transformed Data")
        output.seek(0)  # Move to the beginning of the file

        # Add a download button
        st.download_button(
            label="Download as Excel",
            data=output,
            file_name="transformed_plate_with_controls.xlsx",
            mime="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        )
    else:
        st.warning("Please enter control values to populate the plate.")

if __name__ == "__main__":
    main()

