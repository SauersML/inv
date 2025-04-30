// modules/calculate_association.nf
// Calculate association tests using Python/Pandas/SciPy (CLS)

nextflow.enable.dsl=2

process CALCULATE_ASSOCIATION {
    tag "Assoc ${consensus_tsv.getBaseName()}" // Tag with input consensus file name
    label 'process_medium_cls' // Runs via CLS

    publishDir "${params.output_dir_gcs}/association_results", mode: 'copy', overwrite: true, pattern: "*.tsv"

    // Container specified in nextflow.config profile
    // Resource overrides from params
    memory params.assoc_calc_mem
    disk params.assoc_calc_disk
    time params.assoc_calc_time

    input:
    val consensus_tsv        // GCS path string from EXTRACT_CONSENSUS_DATAPROC
    path phenotype_file     // File from DEFINE_COHORT

    output:
    path "haplotype_association_results.tsv", emit: results_tsv

    script:
    // Need to make the consensus TSV available locally for the python script
    // The `google-cls` executor automatically stages `val` inputs if they look like GCS paths.
    // We reference the local staged path provided by Nextflow.
    // If consensus_tsv is guaranteed to be a GCS path string:
    def local_consensus_file = consensus_tsv.startsWith('gs://') ? consensus_tsv.split('/')[-1] : consensus_tsv

    """
    echo "Starting Haplotype Association Calculation (TSV Input)..."
    echo "Consensus TSV GCS Path: ${consensus_tsv}"
    echo "Local Consensus File (staged): ${local_consensus_file}" // This might just be the filename
    echo "Phenotype file: ${phenotype_file}"

    # Verify staged file exists
    ls -l ${local_consensus_file}
    ls -l ${phenotype_file}

    python $baseDir/bin/haplotype_assoc.py \\
        --consensus-file "${local_consensus_file}" \\
        --phenotype-file "${phenotype_file}" \\
        --out-results haplotype_association_results.tsv

    echo "Association calculation finished."
    ls -l haplotype_association_results.tsv
    """

    stub:
    """
    touch haplotype_association_results.tsv
    """
}
