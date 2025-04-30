// modules/extract_consensus_dataproc.nf
// Extract target SNPs, calculate H1/H2 consensus using Hail on Google Dataproc, output TSV

nextflow.enable.dsl=2

process EXTRACT_CONSENSUS_DATAPROC {
    tag "Hail Extract & Consensus ${target_snps_list.size()} SNPs"
    label 'process_dataproc_heavy' // Label for Dataproc job

    // Executor and cluster configuration defined in nextflow.config profile 'google'

    // Define where the final output TSV should be stored Persistently in GCS
    def output_tsv_gcs_path = "${params.output_dir_gcs}/hail_extract/consensus_status.tsv"

    input:
    path participant_list          // File from DEFINE_COHORT
    val wgs_vds_path               // GCS path from params
    val target_snps_list           // List of strings from params
    val target_snp_alleles_json    // JSON string or path from params

    output:
    // Emit the path (string) to the successfully written consensus TSV file in GCS
    val output_tsv_gcs_path, emit: consensus_tsv

    script:
    def target_snps_str = target_snps_list.join(' ') // Convert list to space-separated string
    """
    echo "Starting Hail SNP extraction & consensus script on Dataproc..."
    echo "VDS Path: ${wgs_vds_path}"
    echo "Participant file (in work dir): ${participant_list}"
    echo "Target SNPs: ${target_snps_str}"
    echo "Allele Info JSON: '${target_snp_alleles_json}'" // Pass as string literal
    echo "Output TSV GCS Path: ${output_tsv_gcs_path}"

    # Execute the Hail script using spark-submit (or python3 directly if env is set up)
    python3 $baseDir/bin/extract_consensus_hail.py \\
        --vds-path "${wgs_vds_path}" \\
        --participant-file "${participant_list}" \\
        --target-snps ${target_snps_str} \\
        --allele-info-json '${target_snp_alleles_json}' \\
        --out-consensus-tsv "${output_tsv_gcs_path}"

    echo "Hail script execution finished."

    """

    stub: // Indicate the expected output path for dry run
    """
    echo "Dry run: Would write consensus TSV to ${output_tsv_gcs_path}"
    touch consensus_status.tsv // Create dummy local file for stub output if needed
    """
}
