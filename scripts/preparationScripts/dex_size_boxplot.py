import pandas as pd
import seaborn as sns
import matplotlib.pyplot as plt
import numpy as np

def main():
    # Path to your CSV file
    csv_file = 'latest.csv'  # Change this to your actual file path

    # Load CSV
    df = pd.read_csv(csv_file)

    # Convert dex_size to numeric and remove invalid entries
    df['dex_size'] = pd.to_numeric(df['dex_size'], errors='coerce')
    df = df.dropna(subset=['dex_size'])

    # Convert bytes to megabytes (MB)
    df['dex_size_MB'] = df['dex_size'] / (1024 * 1024)

    # ✅ **Calculate Quartiles**
    Q1 = df['dex_size_MB'].quantile(0.25)  # First quartile (25%)
    Q2 = df['dex_size_MB'].median()        # Median (50%)
    Q3 = df['dex_size_MB'].quantile(0.75)  # Third quartile (75%)
    IQR = Q3 - Q1                          # Interquartile Range
    lower_bound = Q1 - 1.5 * IQR           # Lower bound
    upper_bound = Q3 + 1.5 * IQR           # Upper bound

    # ✅ **Print Exact Q1, Q2, Q3 Values**
    print(f"📊 Quartile Statistics for dex_size (in MB):")
    print(f"   🔹 Q1 (25%): {Q1:.2f} MB")
    print(f"   🔹 Median (50%): {Q2:.2f} MB")
    print(f"   🔹 Q3 (75%): {Q3:.2f} MB")
    print(f"   🔹 IQR: {IQR:.2f} MB")
    print(f"   🔹 Outlier Lower Bound: {lower_bound:.2f} MB")
    print(f"   🔹 Outlier Upper Bound: {upper_bound:.2f} MB")

    # ✅ **Count distributions between quartile ranges**
    count_0_Q1 = len(df[df['dex_size_MB'] < Q1])
    count_Q1_Q3 = len(df[(df['dex_size_MB'] >= Q1) & (df['dex_size_MB'] <= Q3)])
    count_Q3_above = len(df[df['dex_size_MB'] > Q3])

    print(f"\n📈 Data Distribution by dex_size_MB:")
    print(f"   🔸 Between 0 and Q1: {count_0_Q1} rows")
    print(f"   🔸 Between Q1 and Q3: {count_Q1_Q3} rows")
    print(f"   🔸 Above Q3: {count_Q3_above} rows")

    # ✅ **Filter dataset to remove outliers**
    df_filtered = df[(df['dex_size_MB'] >= lower_bound) & (df['dex_size_MB'] <= upper_bound)]

    print(f"\n📉 Original dataset size: {len(df)}")
    print(f"📉 Filtered dataset size (outliers removed): {len(df_filtered)}")

    # ✅ **BoxPlot After Removing Outliers**
    plt.figure(figsize=(10, 6))
    sns.boxplot(x=df_filtered['dex_size_MB'])
    plt.title('BoxPlot of dex_size (in MB) - Outliers Removed')
    plt.xlabel('dex_size (MB)')
    plt.grid(True)
    plt.tight_layout()
    plt.savefig('boxplot_dex_size_MB_filtered.png')
    plt.show()

if __name__ == "__main__":
    main()
