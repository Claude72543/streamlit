
import streamlit as st
import pandas as pd
import numpy as np
import matplotlib.pyplot as plt
from scipy.optimize import curve_fit
from scipy.stats import linregress
import seaborn as sns
from datetime import datetime
import warnings
import io
import zipfile
from pathlib import Path
import base64

def adjust_zero_doses(df, dose_col):
    """Adjust zero dose values by adding 1% of minimum positive dose."""
    if dose_col not in df.columns:
        return df
    
    df_adjusted = df.copy()
    positive_doses = df_adjusted[df_adjusted[dose_col] > 0][dose_col]
    
    if len(positive_doses) > 0:
        min_positive_dose = positive_doses.min()
        adjustment = 0.01 * min_positive_dose
        df_adjusted.loc[df_adjusted[dose_col] <= 0, dose_col] = adjustment
        
        if (df[dose_col] <= 0).any():
            st.info(f"Adjusted {(df[dose_col] <= 0).sum()} zero/negative dose values to {adjustment:.6f}")
    
    return df_adjusted


def import_data():
    st.subheader("Data Import")
    file_type = st.selectbox("Select file type", ["CSV", "Excel"])
    uploaded_file = st.file_uploader("Upload your data file", type=["csv", "xlsx"])
    
    if uploaded_file:
        try:
            if file_type == "CSV":
                df = pd.read_csv(uploaded_file)
            else:
                # For Excel, allow sheet selection
                sheet_names = pd.ExcelFile(uploaded_file).sheet_names
                selected_sheet = st.selectbox("Select sheet", sheet_names)
                df = pd.read_excel(uploaded_file, sheet_name=selected_sheet)
            st.success("Data imported successfully!")
            return df
        except Exception as e:
            st.error(f"Error importing file: {str(e)}")
            return None
    return None


def discrete_breaks(df, break_params):
    """Split table into discrete subtables based on parameters."""
    if not break_params:
        return {"full_data": df}
    
    subtables = {}
    grouped = df.groupby(break_params)
    for name, group in grouped:
        # Create meaningful key names for plotting
        if isinstance(name, tuple):
            key = ", ".join([f"{val}" for param, val in zip(break_params, name)])
        else:
            key = f"{name}"
        subtables[key] = group.reset_index(drop=True)
    return subtables
def breaks_with_shared_controls(df, param, control_value):
    """Split table with shared control rows."""
    subtables = {}
    control_rows = df[df[param] == control_value]
    
    for value in df[param].unique():
        if value != control_value:
            subtable = pd.concat([df[df[param] == value], control_rows])
            key = f"{value}"
            subtables[key] = subtable.reset_index(drop=True)
    return subtables


def define_curves_with_shared_zero_dose(df, curve_param, dose_col):
    """Define curves that share the zero dose values automatically."""
    curves = {}
    
    # Find rows with dose == 0 (these will be shared across curves)
    zero_dose_rows = df[df[dose_col] == 0]
    
    # For each unique curve parameter value, create a curve with its data plus shared zero doses
    for value in df[curve_param].unique():
        # Get rows for this curve that are NOT zero dose
        curve_rows = df[(df[curve_param] == value) & (df[dose_col] != 0)]
        
        # Combine with zero dose rows, removing any duplicates
        if not zero_dose_rows.empty:
            combined = pd.concat([curve_rows, zero_dose_rows]).drop_duplicates().reset_index(drop=True)
        else:
            combined = curve_rows.reset_index(drop=True)
        
        key = f"{value}"
        curves[key] = combined
    
    return curves


def curves_with_shared_controls(df, curve_param, shared_param, shared_value):
    """Define subtables for individual curves with shared control values."""
    curves = {}
    shared_rows = df[df[shared_param] == shared_value]
    
    for value in df[curve_param].unique():
        # Get rows for this curve value
        curve_rows = df[df[curve_param] == value]
        # Combine with shared rows (remove duplicates if any)
        combined = pd.concat([curve_rows, shared_rows]).drop_duplicates().reset_index(drop=True)
        key = f"{value}"  #{curve_param}=
        curves[key] = combined
    return curves


def define_individual_curves(df, curve_param):
    """Define subtables for individual curves without shared controls."""
    curves = {}
    for value in df[curve_param].unique():
        key = f"{value}"   #{curve_param}=
        curves[key] = df[df[curve_param] == value].reset_index(drop=True)
    return curves

def hierarchical_data_processing(df, break_params=None, shared_control_param=None, 
                                shared_control_value=None, curve_param=None, dose_col=None):
    """
    Process data hierarchically:
    1. Discrete breaks first
    2. Shared controls on each discrete subtable
    3. Individual curves with shared zero doses on each shared control subtable
    """
    results = {
        'discrete_subtables': {},
        'shared_control_subtables': {},
        'curve_groups': {},
        'processing_log': []
    }
    
    # Step 1: Discrete breaks
    if break_params:
        discrete_subtables = discrete_breaks(df, break_params)
        results['discrete_subtables'] = discrete_subtables
        results['processing_log'].append(f"Created {len(discrete_subtables)} discrete subtables")
    else:
        discrete_subtables = {"full_data": df}
        results['discrete_subtables'] = discrete_subtables
        results['processing_log'].append("No discrete breaks - using full dataset")
    
    # Step 2: Apply shared controls to each discrete subtable
    if shared_control_param and shared_control_value is not None:
        for discrete_name, discrete_df in discrete_subtables.items():
            if discrete_df.empty:
                continue
                
            # Check if the shared control parameter and value exist in this subtable
            if (shared_control_param in discrete_df.columns and 
                shared_control_value in discrete_df[shared_control_param].values):
                
                shared_subtables = breaks_with_shared_controls(
                    discrete_df, shared_control_param, shared_control_value
                )
                
                # Add discrete prefix to shared control subtable names
                for shared_name, shared_df in shared_subtables.items():
                    combined_name = f"{discrete_name}_{shared_name}" if discrete_name != "full_data" else shared_name
                    results['shared_control_subtables'][combined_name] = shared_df
                
                results['processing_log'].append(
                    f"Applied shared controls to '{discrete_name}': {len(shared_subtables)} subtables"
                )
            else:
                # If no shared controls can be applied, use the discrete subtable as-is
                results['shared_control_subtables'][discrete_name] = discrete_df
                results['processing_log'].append(
                    f"No shared controls applied to '{discrete_name}' - using as single group"
                )
    else:
        # If no shared controls specified, use discrete subtables
        results['shared_control_subtables'] = discrete_subtables
        results['processing_log'].append("No shared controls specified - using discrete subtables")
    
    # Step 3: Define individual curves with shared zero doses for each shared control subtable
    if curve_param and dose_col:
        for shared_name, shared_df in results['shared_control_subtables'].items():
            if shared_df.empty:
                continue
                
            # Check if curve parameter exists in this subtable
            if curve_param in shared_df.columns:
                curves = define_curves_with_shared_zero_dose(shared_df, curve_param, dose_col)
                
                # Add shared control prefix to curve names
                for curve_name, curve_df in curves.items():
                    combined_curve_name = f"{shared_name}_{curve_name}"
                    results['curve_groups'][combined_curve_name] = curve_df
                
                results['processing_log'].append(
                    f"Created {len(curves)} curves from '{shared_name}' with shared zero doses"
                )
            else:
                results['processing_log'].append(
                    f"Curve parameter '{curve_param}' not found in '{shared_name}'"
                )
    else:
        # If no curve definition specified, use shared control subtables as single curves
        for shared_name, shared_df in results['shared_control_subtables'].items():
            results['curve_groups'][shared_name] = shared_df
        results['processing_log'].append("No curve parameters specified - using shared control subtables as curves")
    
    return results


def split_data_ui_hierarchical(df, dose):
    """Updated UI for hierarchical data splitting."""
    st.subheader("Hierarchical Data Processing")
    st.info("Data will be processed in sequence: Discrete Breaks → Shared Controls → Individual Curves")
    
    # Get numeric columns for dose selection
    numeric_columns = [col for col in df.columns if np.issubdtype(df[col].dtype, np.number)]
    
    # Step 1: Discrete breaks
    st.write("### Step 1: Discrete Breaks")
    break_params = st.multiselect("Select parameters for discrete breaks", df.columns)
    
    # Step 2: Shared controls
    st.write("### Step 2: Shared Controls (applied to each discrete subtable)")
    use_shared_controls = st.checkbox("Use shared controls")
    
    shared_control_param = None
    shared_control_value = None
    if use_shared_controls:
        shared_control_param = st.selectbox("Select parameter for shared controls", 
                                           df.columns, key="shared_control_param")
        shared_control_value = st.selectbox("Select control value", 
                                          df[shared_control_param].unique(), 
                                          key="shared_control_value")
    
    # Step 3: Individual curves
    st.write("### Step 3: Individual Curves (with shared zero doses)")
    curve_param = st.selectbox("Select parameter for curves", df.columns, key="curve_param_select")
    # dose_col = st.selectbox("Select dose column for shared zero dose detection", 
    #                        [None] + numeric_columns, key="dose_col_for_curves")

    default_index = ([None] + numeric_columns).index(dose) if dose in numeric_columns else 0
    dose_col = st.selectbox("Select dose column for shared zero dose detection", 
                            [None] + numeric_columns, index=default_index, key="dose_col_for_curves")

    # Process data hierarchically
    results = hierarchical_data_processing(
        df, 
        break_params=break_params if break_params else None,
        shared_control_param=shared_control_param,
        shared_control_value=shared_control_value,
        curve_param=curve_param,
        dose_col=dose_col
    )
    
    # Display processing log
    with st.expander("Processing"):
        st.write("### Processing Summary:")
        for log_entry in results['processing_log']:
            st.write(f"- {log_entry}")
        
        # Display final curve groups
        if results['curve_groups']:
            st.write("### Final Curve Groups:")
            for curve_name, curve_df in results['curve_groups'].items():
                st.write(f"- **{curve_name}**: {len(curve_df)} data points")
    
    return results


def group_plots_hierarchical(results):
    """Group plots based on hierarchical processing results."""
    grouped_models = {}
    
    # Group curves by their shared control subtables
    if results['shared_control_subtables']:
        for shared_name in results['shared_control_subtables'].keys():
            # Find all curves that belong to this shared control group
            group_curves = {}
            for curve_name, curve_df in results['curve_groups'].items():
                if curve_name.startswith(shared_name + "_"):
                    # Remove the shared control prefix for cleaner curve names
                    clean_curve_name = curve_name.replace(shared_name + "_", "")
                    group_curves[clean_curve_name] = curve_df
            
            if group_curves:
                grouped_models[shared_name] = group_curves
    
    # If no grouping resulted, create one group with all curves
    if not grouped_models and results['curve_groups']:
        grouped_models = {"All_Curves": results['curve_groups']}
    
    return grouped_models

def three_pl_model(x, top, bottom, ic50):
    """3PL model function."""
    return bottom + (top - bottom) / (1 + (x / ic50))


def four_pl_model(x, top, bottom, ic50, hill):
    """4PL model function."""
    return bottom + (top - bottom) / (1 + (x / ic50) ** hill)


def calculate_r_squared(y_actual, y_predicted):
    """Calculate R-squared value."""
    ss_res = np.sum((y_actual - y_predicted) ** 2)
    ss_tot = np.sum((y_actual - np.mean(y_actual)) ** 2)
    return 1 - (ss_res / ss_tot)


def calculate_ec_value(params, model_type, percent=50):
    """Calculate EC value for given percentage inhibition."""
    if model_type == "3PL":
        top, bottom, ic50 = params
        # For 3PL, ECx is simply IC50 scaled by percentage
        if percent == 50:
            return ic50
        else:
            # Calculate ECx for other percentages
            fraction = percent / 100.0
            return ic50 * ((1 - fraction) / fraction)
    else:  # 4PL
        top, bottom, ic50, hill = params
        if percent == 50:
            return ic50
        else:
            # Calculate ECx for other percentages
            fraction = percent / 100.0
            return ic50 * ((1 - fraction) / fraction) ** (1 / hill)


def fit_curve(data, x_col, y_col):
    """Fit 3PL and 4PL models and select best based on error."""
    try:
        # Validate input data
        if not isinstance(data, pd.DataFrame):
            raise ValueError("Input data must be a pandas DataFrame")
        if data.empty:
            raise ValueError("Input data is empty")
        if x_col not in data.columns or y_col not in data.columns:
            raise ValueError(f"Columns {x_col} or {y_col} not found in data")
        
        # Check if x_col and y_col are numeric
        if not np.issubdtype(data[x_col].dtype, np.number):
            raise ValueError(f"Column {x_col} contains non-numeric data")
        if not np.issubdtype(data[y_col].dtype, np.number):
            raise ValueError(f"Column {y_col} contains non-numeric data")
        
        # Adjust zero doses before fitting
        adjusted_data = adjust_zero_doses(data, x_col)
        
        # Filter out any remaining non-positive doses (should be rare after adjustment)
        valid_data = adjusted_data[adjusted_data[x_col] > 0].copy()
        if valid_data.empty:
            raise ValueError("No positive dose values available for fitting after adjustment")
        
        x = valid_data[x_col].values
        y = valid_data[y_col].values
        
        # Calculate median max for constraint and hook effect detection
        max_dose = valid_data[x_col].value_counts().idxmax()
        max_median = valid_data[valid_data[x_col] == max_dose][y_col].median()
        highest_response = valid_data[y_col].max()
        
        # Initial parameters
        p0_3pl = [max_median, min(y), np.median(x)]
        p0_4pl = [max_median, min(y), np.median(x), 1]
        
        # Fit 3PL
        popt_3pl, _ = curve_fit(three_pl_model, x, y, p0=p0_3pl)
        y_pred_3pl = three_pl_model(x, *popt_3pl)
        error_3pl = np.mean((y - y_pred_3pl) ** 2)
        r2_3pl = calculate_r_squared(y, y_pred_3pl)
        
        # Fit 4PL with hook effect constraint
        # If there's potential hook effect, constrain the max parameter
        bounds_4pl = ([-np.inf, -np.inf, -np.inf, -np.inf], 
                      [np.inf, np.inf, np.inf, np.inf])
        
        # Check for hook effect by comparing model max to highest response
        if max_median < highest_response * 0.9:  # Potential hook effect
            bounds_4pl = ([-np.inf, -np.inf, -np.inf, -np.inf], 
                          [highest_response, np.inf, np.inf, np.inf])
        
        popt_4pl, _ = curve_fit(four_pl_model, x, y, p0=p0_4pl, bounds=bounds_4pl)
        y_pred_4pl = four_pl_model(x, *popt_4pl)
        error_4pl = np.mean((y - y_pred_4pl) ** 2)
        r2_4pl = calculate_r_squared(y, y_pred_4pl)
        
        # Select best model
        if error_3pl <= error_4pl:
            return "3PL", popt_3pl, error_3pl, r2_3pl, adjusted_data
        return "4PL", popt_4pl, error_4pl, r2_4pl, adjusted_data
    
    except Exception as e:
        with st.expander("Fitting errors"):
            st.error(f"Curve fitting failed: {str(e)}")
        return None, None, None, None, None


def fit_curves_ui(curves, x_col, y_col):
    fitted_models = {}
    
    try:
        for curve_name, curve_data in curves.items():
            try:
                if not isinstance(curve_data, pd.DataFrame) or curve_data.empty:
                    st.warning(f"Curve '{curve_name}' is empty or invalid. Skipping.")
                    continue
                if x_col not in curve_data.columns or y_col not in curve_data.columns:
                    st.warning(f"Curve '{curve_name}' missing {x_col} or {y_col}. Skipping.")
                    continue
                
                # Additional numeric validation
                if not np.issubdtype(curve_data[x_col].dtype, np.number):
                    st.warning(f"Curve '{curve_name}' has non-numeric data in {x_col}. Skipping.")
                    continue
                if not np.issubdtype(curve_data[y_col].dtype, np.number):
                    st.warning(f"Curve '{curve_name}' has non-numeric data in {y_col}. Skipping.")
                    continue
                
                model_type, params, error, r2, adjusted_data = fit_curve(curve_data, x_col, y_col)
                if model_type:
                    fitted_models[curve_name] = {
                        "model_type": model_type,
                        "params": params,
                        "error": error,
                        "r_squared": r2,
                        "data": adjusted_data
                    }
                else:
                    st.warning(f"Curve fitting failed for '{curve_name}'. Skipping.")
            except Exception as e:
                st.error(f"Error processing curve '{curve_name}': {str(e)}")
                continue
        
        if not fitted_models:
            st.error("No curves successfully fitted. Check your data and column selections.")
        return fitted_models
    except Exception as e:
        st.error(f"Curve fitting failed: {str(e)}")
        return {}


def generate_statistics(fitted_models, original_params, y_col, ec_values=[50]):
    """Generate statistics table with customizable EC values."""
    stats_data = []
    
    for curve_name, model_info in fitted_models.items():
        data = model_info["data"]
        model_type = model_info["model_type"]
        params = model_info["params"]
        error = model_info["error"]
        r_squared = model_info["r_squared"]
        
        # Calculate empirical min/max and range for response
        response_min = data[y_col].min()
        response_max = data[y_col].max()
        response_range = response_max - response_min
        
        # Calculate empirical min/max for all numeric columns
        emp_min = data.min(numeric_only=True).to_dict()
        emp_max = data.max(numeric_only=True).to_dict()
        
        # Calculate EC values
        ec_dict = {}
        for ec_percent in ec_values:
            try:
                ec_val = calculate_ec_value(params, model_type, 100 - ec_percent)
                ec_dict[f"EC{ec_percent}"] = ec_val
            except:
                ec_dict[f"EC{ec_percent}"] = np.nan
        
        # Create stats row
        stats_row = {
            "curve_name": curve_name,
            "model_type": model_type,
            f"R² (model error)": r_squared,
            "MSE": error,
            "response_range": response_range,
            **ec_dict,
            **{f"param_{i}": p for i, p in enumerate(params)},
            **{f"min_{k}": v for k, v in emp_min.items()},
            **{f"max_{k}": v for k, v in emp_max.items()},
            **{k: data[k].iloc[0] for k in original_params if k in data.columns}
        }
        stats_data.append(stats_row)
    
    stats_df = pd.DataFrame(stats_data)
    return stats_df


def get_plot_settings():
    """Get global plot settings from sidebar."""
    st.header("Global Plot Settings")
    
    # Figure dimensions
    fig_width = st.number_input("Figure width", value=8, key="global_width")
    fig_height = st.number_input("Figure height", value=6, key="global_height")
    
    # Legend settings
    legend_fontsize = st.selectbox("Legend font size", 
                                    ["xx-small", "x-small", "small", "medium", "large", "x-large", "xx-large"],
                                    index=3, key="global_legend_fontsize")
    
    # Axis labels
    xlabel = st.text_input("X-axis label", value="Dose", key="global_xlabel")
    ylabel = st.text_input("Y-axis label", value="Response", key="global_ylabel")
    
    # Title settings
    title_fontsize = st.selectbox("Title font size",
                                ["small", "medium", "large", "x-large", "xx-large"],
                                index=2, key="global_title_fontsize")
    
    return {
        "fig_width": fig_width,
        "fig_height": fig_height,
        "legend_fontsize": legend_fontsize,
        "xlabel": xlabel,
        "ylabel": ylabel,
        "title_fontsize": title_fontsize
    }


def generate_plot(fitted_models, x_col, y_col, title="", subtitle="", caption="", 
                 plot_settings=None):
    
    if plot_settings is None:
        plot_settings = {
            "fig_width": 8, "fig_height": 6,
            "legend_fontsize": "medium", "xlabel": "Dose", "ylabel": "Response",
            "title_fontsize": "large"
        }
    
    fig, ax = plt.subplots(figsize=(plot_settings["fig_width"], plot_settings["fig_height"]))
    
    # Define markers and colors
    markers = ['o', 's', '^', 'D', 'v', '<', '>', 'p', '*', 'h']
    colors = sns.color_palette("husl", len(fitted_models))
    
    for i, (curve_name, model_info) in enumerate(fitted_models.items()):
        data = model_info["data"]
        model_type = model_info["model_type"]
        params = model_info["params"]
        
        # Plot points
        ax.scatter(data[x_col], data[y_col], color=colors[i], marker=markers[i % len(markers)],
                  label=curve_name, alpha=0.6, s=50)
        
        # Plot fitted curve
        x_range = np.logspace(np.log10(min(data[x_col][data[x_col] > 0])), 
                             np.log10(max(data[x_col])), 100)
        if model_type == "3PL":
            y_pred = three_pl_model(x_range, *params)
        else:
            y_pred = four_pl_model(x_range, *params)
        
        ax.plot(x_range, y_pred, color=colors[i], linestyle='-', linewidth=2)
    
    # Set x-axis to log10 scale
    ax.set_xscale('log')
    
    # Customize plot
    # Title positioned at top-left of plot area
    ax.text(0.02, 1.02, title, transform=ax.transAxes, ha='left', va='bottom',
           fontsize=plot_settings["title_fontsize"], weight='bold')
    if subtitle:
        ax.text(0.02, 0.98, subtitle, transform=ax.transAxes, ha='left', va='top',
               fontsize=plot_settings["title_fontsize"])
    
    ax.set_xlabel(plot_settings["xlabel"], fontsize='large')
    ax.set_ylabel(plot_settings["ylabel"], fontsize='large')
    
    # Add caption below plot, right-justified
    fig.text(0.99, 0.01, caption, ha='right', va='bottom', fontsize='small')
    
    # Add legend on the right side, above the plot
    ax.legend(ncol=1, 
             bbox_to_anchor=(1.02, 1.0), loc='upper left',
             fontsize=plot_settings["legend_fontsize"])
    
    plt.tight_layout()
    return fig


def export_data_with_stats(stats_df, user_initials="USER"):
    """Export only the statistics table."""
    st.subheader("Export Statistics")
    
    zip_buffer = io.BytesIO()
    timestamp = pd.Timestamp.now().strftime('%Y%m%d_%H%M%S')
    
    with zipfile.ZipFile(zip_buffer, "w", zipfile.ZIP_DEFLATED) as zip_file:
        # Add only the stats table
        stats_buffer = io.StringIO()
        stats_df.to_csv(stats_buffer, index=False)
        zip_file.writestr(f"statistics_{timestamp}.csv", stats_buffer.getvalue())
    
    zip_buffer.seek(0)
    st.download_button(
        label="Download Statistics",
        data=zip_buffer,
        file_name=f"stats_export_{timestamp}.zip",
        mime="application/zip"
    )


def export_plots(fitted_models_groups, export_format="png", plot_settings=None, x_col="", y_col="", user_initials="USER"):
    st.subheader("Export Plots")
    zip_buffer = io.BytesIO()
    
    # Get caption
    caption = f"{user_initials} {pd.Timestamp.now().strftime('%Y-%m-%d')}"
    
    with zipfile.ZipFile(zip_buffer, "w", zipfile.ZIP_DEFLATED) as zip_file:
        for group_name, fitted_models in fitted_models_groups.items():
            fig = generate_plot(fitted_models, 
                              x_col=x_col,
                              y_col=y_col,
                              title=group_name,
                              caption=caption,
                              plot_settings=plot_settings)
            
            img_buffer = io.BytesIO()
            fig.savefig(img_buffer, format=export_format, bbox_inches='tight', dpi=300)
            safe_filename = "".join(c for c in group_name if c.isalnum() or c in (' ', '-', '_')).rstrip()
            zip_file.writestr(f"{safe_filename}.{export_format}", img_buffer.getvalue())
            plt.close(fig)
    
    zip_buffer.seek(0)
    st.download_button(
        label=f"Download plots as {export_format.upper()}",
        data=zip_buffer,
        file_name=f"plots_{pd.Timestamp.now().strftime('%Y%m%d_%H%M%S')}.zip",
        mime="application/zip"
    )

def group_plots_ui(discrete_subtables, shared_subtables, fitted_models):
    """Group fitted models according to their corresponding subtables."""
    try:
        grouped_models = {}
        
        # Handle discrete breaks
        if discrete_subtables and len(discrete_subtables) > 1:  # More than just "full_data"
            st.write("### Plots grouped by discrete breaks:")
            
            for subtable_name, subtable_df in discrete_subtables.items():
                if subtable_df.empty:
                    continue
                    
                # Find fitted models that belong to this subtable
                group_models = {}
                
                # Parse subtable parameters
                subtable_params = {}
                if subtable_name != "full_data":
                    for param_pair in subtable_name.split('_'):
                        if '=' in param_pair:
                            param_name, param_value = param_pair.split('=', 1)
                            # Try to convert to appropriate type
                            try:
                                # Try numeric conversion
                                if '.' in param_value:
                                    param_value = float(param_value)
                                else:
                                    param_value = int(param_value)
                            except ValueError:
                                # Keep as string
                                pass
                            subtable_params[param_name] = param_value
                
                # Match fitted models to this subtable
                for curve_name, model_info in fitted_models.items():
                    model_data = model_info["data"]
                    
                    # Check if this model's data matches the subtable parameters
                    matches = True
                    if subtable_params:  # Only check if we have parameters to match
                        for param_name, param_value in subtable_params.items():
                            if param_name in model_data.columns:
                                # Check if all values in this column match the expected value
                                unique_values = model_data[param_name].unique()
                                if len(unique_values) == 1 and unique_values[0] == param_value:
                                    continue
                                elif param_value in unique_values:
                                    # Partial match - could be shared control case
                                    continue
                                else:
                                    matches = False
                                    break
                            else:
                                matches = False
                                break
                    
                    if matches:
                        group_models[curve_name] = model_info
                
                if group_models:
                    grouped_models[subtable_name] = group_models
        
        # Handle shared controls - these should override discrete breaks
        if shared_subtables:
            st.write("### Plots grouped by shared controls:")
            
            # Clear previous groupings since shared controls take precedence
            grouped_models = {}
            
            for subtable_name, subtable_df in shared_subtables.items():
                if subtable_df.empty:
                    continue
                    
                # For shared controls, ALL curves should appear in each plot
                # The subtable already contains the shared control data combined with each treatment
                group_models = {}
                
                # Parse subtable parameter to identify the treatment group
                if '=' in subtable_name:
                    param_name, param_value = subtable_name.split('=', 1)
                    try:
                        if '.' in param_value:
                            param_value = float(param_value)
                        else:
                            param_value = int(param_value)
                    except ValueError:
                        pass
                    
                    # For shared controls, we want ALL curves that contain data for this treatment
                    # AND the shared control should appear in every plot
                    for curve_name, model_info in fitted_models.items():
                        model_data = model_info["data"]
                        
                        # Check if this curve has data that overlaps with this subtable
                        if param_name in model_data.columns:
                            # Include curves that have either:
                            # 1. The specific treatment value, OR 
                            # 2. The shared control value (these should be in all plots)
                            model_param_values = set(model_data[param_name].unique())
                            subtable_param_values = set(subtable_df[param_name].unique())
                            
                            # If there's any overlap in parameter values, include this curve
                            if model_param_values.intersection(subtable_param_values):
                                group_models[curve_name] = model_info
                
                if group_models:
                    grouped_models[f"SharedControl_{subtable_name}"] = group_models
        
        # If no specific grouping was done, create one group with all models
        if not grouped_models and fitted_models:
            grouped_models = {"All_Curves": fitted_models}
        
        # Display grouping summary
        if grouped_models:
            with st.expander("Groupings created"):
                st.write("### Plot Groups Created:")
                for group_name, group_models in grouped_models.items():
                    st.write(f"- **{group_name}**: {len(group_models)} curves")
                    for curve_name in group_models.keys():
                        st.write(f"  - {curve_name}")
        
        return grouped_models, 1, 1  # n_rows, n_cols (simplified)
    
    except Exception as e:
        st.error(f"Failed to group plots: {str(e)}")
        return {"All_Curves": fitted_models} if fitted_models else {}, 1, 1


def main_hierarchical():
    st.title("Dose Response Curve Analysis - Hierarchical Processing")
    
    try:
        # Data import
        df = import_data()
        
        if df is None:
            st.info("Please upload a data file to begin analysis.")
            return
        
        # Filter numeric columns
        numeric_columns = [col for col in df.columns 
                          if np.issubdtype(df[col].dtype, np.number)]
        if not numeric_columns:
            st.error("No numeric columns found in the data. Please upload a dataset with numeric dose and response columns.")
            return

        selected_date = st.date_input("Choose a date")
        user_initials = st.text_input("Your initials", "USER", key="initials_input")
        caption = f"{user_initials} {pd.to_datetime(selected_date).strftime('%Y-%m-%d')}"        

        # Select x and y columns
        x_col = st.selectbox("Select dose column (X-axis)", numeric_columns, key="dose_column_select")
        y_col = st.selectbox("Select response column (Y-axis)", numeric_columns, key="response_column_select")
        
        # Hierarchical data processing
        results = split_data_ui_hierarchical(df, x_col)
        curves = results['curve_groups']
        
        if not curves:
            st.error("No curves generated from hierarchical processing. Check your parameter selections.")
            return
        
        # Curve fitting
        st.subheader("Curve Fitting")
        fitted_models = fit_curves_ui(curves, x_col, y_col)
        
        if not fitted_models:
            st.error("No fitted models generated. Check your data and column selections.")
            return
        
        # Statistics with customizable EC values
        st.subheader("Statistics")
        st.write("### Configure EC Values")
        ec_input = st.text_input("Enter EC values (comma-separated, e.g., 10,20,50,70,90)", "50")

        try:
            ec_values = [int(x.strip()) for x in ec_input.split(",") if x.strip().isdigit()]
            if not ec_values:
                ec_values = [50]
        except:
            ec_values = [50]
            st.warning("Invalid EC values entered. Using EC50 as default.")
        
        original_params = list(set(df.columns) - {x_col, y_col})
        stats_df = generate_statistics(fitted_models, original_params, y_col, ec_values)
        st.write(stats_df)
        
        # Group fitted models by their shared control subtables for plotting
        plot_groups = {}
        
        for shared_name in results['shared_control_subtables'].keys():
            group_fitted_models = {}
            for curve_name in curves.keys():
                if curve_name.startswith(shared_name + "_"):
                    if curve_name in fitted_models:
                        clean_curve_name = curve_name.replace(shared_name + "_", "")
                        group_fitted_models[clean_curve_name] = fitted_models[curve_name]
            
            if group_fitted_models:
                plot_groups[shared_name] = group_fitted_models
        
        # If no grouping resulted, create one group with all fitted models
        if not plot_groups and fitted_models:
            plot_groups = {"All_Curves": fitted_models}
        
        grouped_models = plot_groups
        
        if not grouped_models:
            st.error("No plot groups generated from hierarchical processing.")
            return
        
        # Display plot grouping summary
        with st.expander("Plot Groups Created"): 
            for group_name, group_models in grouped_models.items():
                st.write(f"- **{group_name}**: {len(group_models)} curves")
                for curve_name in group_models.keys():
                    st.write(f"  - {curve_name}")
        
        # Layout for plots and controls
        col1, col2 = st.columns([1, 4])

        with col1:
            plot_settings = get_plot_settings()

        # Plot generation using global settings
        with col2:
            st.subheader("Generated Plots")
            for group_name, group_models in grouped_models.items():
                try:
                    fig = generate_plot(
                        group_models,
                        x_col,
                        y_col,
                        title=group_name,
                        caption=caption,
                        plot_settings=plot_settings
                    )
                    if fig:
                        st.pyplot(fig)
                    else:
                        st.warning(f"Plot for group '{group_name}' could not be generated.")
                except Exception as e:
                    st.error(f"Error generating plot for group '{group_name}': {str(e)}")
                    continue
        
        # Export section
        col1, col2 = st.columns(2)
        
        with col1:
            export_data_with_stats(stats_df, user_initials)
        
        with col2:
            export_plots(grouped_models, "png", plot_settings, x_col, y_col, user_initials)
    
    except Exception as e:
        st.error(f"Application error: {str(e)}")


main_hierarchical()
