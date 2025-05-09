/*
 * Nextflow Module: CALCULATE_STATS
 * Calculates variant statistics using bcftools stats and generates plots.
 */

nextflow.enable.dsl = 2

process CALCULATE_STATS {
    tag "Calculate Stats: ${region_vcf_file.baseName}"
    label 'medium_resources'

    // Publishes results to a subdirectory within params.output_dir_local
    // The subdirectory is named based on the input VCF's base name (without .extracted.vcf.gz)
    publishDir "${params.output_dir_local}/${region_vcf_file.baseName.replaceAll(~/\.extracted\.vcf\.gz$/, '')}_qc_report",
               mode: 'copy',
               overwrite: true

    input:
    tuple path(region_vcf_file), path(region_tbi_file) // Region-extracted VCF and its index

    output:
    path "*.stats.txt", emit: stats_file // The bcftools stats output file
    path "plots/", emit: plots_directory // Directory containing generated plots

    script:
    def base_filename = region_vcf_file.baseName.replaceAll(~/\.extracted\.vcf\.gz$/, '')
    def stats_filename = "${base_filename}.stats.txt"
    """
    echo "[PROCESS CALCULATE_STATS] VCF for stats: ${region_vcf_file}"
    echo "[PROCESS CALCULATE_STATS] Output stats file: ${stats_filename}"
    echo "[PROCESS CALCULATE_STATS] Output plots directory: plots/"

    echo "[PROCESS CALCULATE_STATS] Running bcftools stats..."
    bcftools stats \\
        "${region_vcf_file}" > "${stats_filename}"

    echo "[PROCESS CALCULATE_STATS] Generating plots with plot-vcfstats..."
    # plot-vcfstats creates the output plots directory (-p option)
    plot-vcfstats -p plots/ "${stats_filename}"

    echo "[PROCESS CALCULATE_STATS] Verification of output:"
    ls -l "${stats_filename}"
    ls -lR plots/
    """
}
