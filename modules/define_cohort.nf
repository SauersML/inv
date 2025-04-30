// modules/define_cohort.nf
// Define cohort using BigQuery

nextflow.enable.dsl=2

process DEFINE_COHORT {
    tag "BQ Cohort Def ${params.cdr_dataset_id}"
    label 'process_medium' // Label for resource allocation if using process selectors

    publishDir "${params.output_dir_gcs}/cohort_definition", mode: 'copy', overwrite: true

    // Container specified in nextflow.config profile
    // containerOptions = "--user $(id -u):$(id -g)"

    input:
    val cdr_dataset_id
    val disease_definitions_json
    val neuro_diseases_list // Passed as a Groovy list from config

    output:
    tuple path("participants.txt"), path("phenotypes.tsv"), emit: cohort_files

    script:
    // Convert Groovy list back to comma-separated string for python script argument
    def neuro_diseases_str = neuro_diseases_list.join(',')
    """
    echo "Starting BigQuery cohort definition..."
    python $baseDir/bin/define_cohort_bq.py \\
        --cdr-dataset-id ${cdr_dataset_id} \\
        --disease-definitions-json '${disease_definitions_json}' \\
        --neuro-diseases "${neuro_diseases_str}" \\
        --out-participants participants.txt \\
        --out-phenotypes phenotypes.tsv

    echo "BigQuery cohort definition finished."
    ls -l
    """

    stub: // Creates empty output files for dry runs
    """
    touch participants.txt
    touch phenotypes.tsv
    """
}
