import pandas as pd
import sys


def filter_and_sample_csv(input_csv, min_size, max_size, output_csv):
    # Load the CSV file into a DataFrame
    df = pd.read_csv(input_csv)

    # Ensure dex_size column is numeric (handle errors by coercing non-numeric values to NaN)
    df['dex_size'] = pd.to_numeric(df['dex_size'], errors='coerce')

    # Filter rows based on dex_size range
    filtered_df = df[(df['dex_size'] >= min_size) & (df['dex_size'] <= max_size)]

    # Randomly sample 1000 rows (or all if less than 1000 available)
    if len(filtered_df) >= 1000:
        sample_df = filtered_df.sample(n=1000, random_state=42)  # random_state ensures reproducibility
    else:
        sample_df = filtered_df  # If fewer than 1000 rows, use all

    # Save to the output CSV file
    sample_df.to_csv(output_csv, index=False)

    print(f"Success Saved {len(sample_df)} rows to '{output_csv}'.")

if __name__ == "__main__":
    # Ensure correct number of arguments
    if len(sys.argv) != 5:
        print("Usage: python filter_sample_csv.py <input.csv> <min_size> <max_size> <output.csv>")
        sys.exit(1)

    # Parse command-line arguments
    input_csv = sys.argv[1]
    min_size = int(sys.argv[2])
    max_size = int(sys.argv[3])
    output_csv = sys.argv[4]

    # Run the filtering function
    filter_and_sample_csv(input_csv, min_size, max_size, output_csv)
