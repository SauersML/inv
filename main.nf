#!/usr/bin/env python3

import argparse
import os
import json
import sys
import time
import pandas as pd
import numpy as np
from scipy.stats import chi2_contingency

def parse_args():
    """ Parse command line arguments """
    parser = argparse.ArgumentParser(description="Run H1/H2 association tests using phenotype and pre-calculated consensus status.")
    parser.add_argument('--consensus-file', required=True, help='Path to the consensus status TSV file (Header: person_id, is_consensus_h1, is_consensus_h2)')
    parser.add_argument('--phenotype-file', required=True, help='Path to the phenotype file (TSV format, person_id index, columns for diseases with 0/1/NA)')
    # Note: Allele info is no longer needed here, it was used in the Hail step
    parser.add_argument('--out-results', required=True, help='Output file path for association results (TSV format)')
    return parser.parse_args()

def run_association(merged_df, phenotype_cols):
    """ Run chi-squared association tests """
    print("\n[2] Calculating H1 vs H2 association with each phenotype...")
    results_list = []

    # Filter to only include individuals clearly defined as H1 or H2 consensus
    # Consensus file should have 0/1 integers
    compare_df = merged_df[
        merged_df['is_consensus_h1'].isin([0, 1]) & merged_df['is_consensus_h2'].isin([0, 1]) &
        ((merged_df['is_consensus_h1'] == 1) | (merged_df['is_consensus_h2'] == 1))
    ].copy()

    n_comparable = len(compare_df)
    if n_comparable == 0:
        print("  Skipping association analysis: No participants found who are homozygous H1 or H2 in merged data.")
        return pd.DataFrame()

    print(f"  Performing analysis on {n_comparable:,} participants clearly defined as H1 or H2 consensus.")
    compare_df['haplotype'] = np.where(compare_df['is_consensus_h1'] == 1, 'H1', 'H2')

    print(f"  Checking {len(phenotype_cols)} phenotypes...")
    for pheno in phenotype_cols:
        # Phenotype data should already be 0.0/1.0/NA floats from reading CSV/TSV
        pheno_compare_df = compare_df[compare_df[pheno].isin([0.0, 1.0])].copy() # Filter NA phenotypes
        if pheno_compare_df[pheno].nunique() < 2:
            print(f"    Skipping {pheno}: Only one outcome group present after removing NA.")
            continue

        pheno_compare_df['status'] = pheno_compare_df[pheno].astype(int) # Case=1, Control=0

        n_pheno_comp = len(pheno_compare_df)
        if n_pheno_comp < 2:
            print(f"    Skipping {pheno}: Not enough comparable samples ({n_pheno_comp}).")
            continue

        try:
            contingency_table = pd.crosstab(pheno_compare_df['haplotype'], pheno_compare_df['status'])
            contingency_table = contingency_table.reindex(index=['H1', 'H2'], columns=[0, 1], fill_value=0)

            h1_cases = contingency_table.loc['H1', 1]
            h1_ctrls = contingency_table.loc['H1', 0]
            h2_cases = contingency_table.loc['H2', 1]
            h2_ctrls = contingency_table.loc['H2', 0]
            phi_coefficient = np.nan
            p_value = np.nan
            chi2_stat = np.nan

            if contingency_table.values.sum() > 0 and not (contingency_table == 0).all().all():
                if (contingency_table.values < 5).any():
                     print(f"    Note: Small counts (<5) in contingency table for {pheno}, Chi2 p-value may be less reliable.")
                if (contingency_table.sum(axis=0) == 0).any() or (contingency_table.sum(axis=1) == 0).any():
                    print(f"    Skipping Chi2 for {pheno} due to zero margin in table.")
                else:
                    try:
                       chi2, p, _, _ = chi2_contingency(contingency_table, correction=False)
                       n_total = contingency_table.values.sum()
                       chi2_stat = chi2
                       p_value = p
                       phi_coefficient = np.sqrt(chi2 / n_total) if n_total > 0 else np.nan
                    except ValueError as chi_err:
                        print(f"    Skipping Chi2 for {pheno} due to calculation error: {chi_err}")
            else:
                 print(f"    Skipping Chi2 for {pheno} due to empty or zero-filled table.")

            results_list.append({
                'Phenotype': pheno,
                'H1_Cases': h1_cases, 'H1_Controls': h1_ctrls,
                'H2_Cases': h2_cases, 'H2_Controls': h2_ctrls,
                'Total_Compared': n_pheno_comp,
                'Chi2_Stat': chi2_stat,
                'Phi_Coefficient': phi_coefficient,
                'P_Value': p_value
            })
            # print(f"    Processed {pheno}: P-value={p_value:.3e}") # Reduce verbosity

        except Exception as corr_err:
            print(f"    ERROR calculating association for {pheno}: {corr_err}", file=sys.stderr)
            results_list.append({'Phenotype': pheno, 'Total_Compared': n_pheno_comp, 'Chi2_Stat': np.nan, 'Phi_Coefficient': np.nan, 'P_Value': np.nan})

    print(f"  Finished processing {len(phenotype_cols)} phenotypes.")
    return pd.DataFrame(results_list)


def main():
    """ Main execution function """
    args = parse_args()
    start_time_script = time.time()
    print(f"--- Starting Haplotype Association Calculation (TSV Input) ---")
    print(f"  Consensus File: {args.consensus_file}")
    print(f"  Phenotype File: {args.phenotype_file}")

    # --- Load Inputs ---
    print("\n[1] Loading Input Data...")
    try:
        # Load consensus data (person_id should be first col)
        consensus_df = pd.read_csv(args.consensus_file, sep='\t')
        # Ensure required columns exist
        if not {'person_id', 'is_consensus_h1', 'is_consensus_h2'}.issubset(consensus_df.columns):
             raise ValueError("Consensus file missing required columns (person_id, is_consensus_h1, is_consensus_h2)")
        consensus_df = consensus_df.set_index('person_id')
        consensus_df.index = consensus_df.index.astype(str) # Ensure index is string
        # Ensure consensus columns are integer
        consensus_df['is_consensus_h1'] = consensus_df['is_consensus_h1'].astype(int)
        consensus_df['is_consensus_h2'] = consensus_df['is_consensus_h2'].astype(int)
        print(f"  Loaded consensus status for {len(consensus_df)} samples.")
    except Exception as e:
        print(f"ERROR loading consensus data from '{args.consensus_file}': {e}", file=sys.stderr)
        sys.exit(1)

    try:
        # Load phenotype data (person_id is index)
        phenotypes_df = pd.read_csv(args.phenotype_file, sep='\t', index_col='person_id', na_values=['NA',''])
        phenotypes_df.index = phenotypes_df.index.astype(str) # Ensure index is string
        phenotype_cols = phenotypes_df.columns.tolist()
         # Convert phenotype columns to numeric (float to handle NA)
        for col in phenotype_cols:
            phenotypes_df[col] = pd.to_numeric(phenotypes_df[col], errors='coerce')
        print(f"  Loaded phenotypes for {len(phenotypes_df)} samples and {len(phenotype_cols)} diseases.")
    except Exception as e:
        print(f"ERROR loading phenotype data from '{args.phenotype_file}': {e}", file=sys.stderr)
        sys.exit(1)

    # --- Merge Phenotypes and Consensus Status ---
    print("\n[2] Merging Phenotypes and Consensus Status...")
    merged_df = phenotypes_df.join(consensus_df, how='inner') # Inner join keeps only samples present in both
    n_merged = len(merged_df)
    print(f"  Successfully merged data for {n_merged:,} participants.")
    if n_merged == 0:
        print("  WARNING: Merge resulted in zero participants. No associations can be calculated.")
        results_df = pd.DataFrame()
    else:
        # --- Run Association Tests ---
        results_df = run_association(merged_df, phenotype_cols)

    # --- Save Results ---
    print("\n[3] Saving Results...")
    if not results_df.empty:
        results_df = results_df.sort_values(by='P_Value')
        results_df.to_csv(args.out_results, sep='\t', index=False, float_format='%.4e', na_rep='NA')
        print(f"  Association results saved to: {args.out_results}")
    else:
         print("  No association results generated.")
         # Save empty file with headers
         pd.DataFrame(columns=['Phenotype', 'H1_Cases', 'H1_Controls', 'H2_Cases', 'H2_Controls', 'Total_Compared', 'Chi2_Stat', 'Phi_Coefficient', 'P_Value']).to_csv(args.out_results, sep='\t', index=False)
         print(f"Empty results file with headers saved to: {args.out_results}")

    end_time_script = time.time()
    print(f"\n--- Haplotype Association Calculation Complete ---")
    print(f"  Total Duration: {end_time_script - start_time_script:.2f}s")

if __name__ == "__main__":
    main()
