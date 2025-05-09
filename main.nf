#!/usr/bin/env nextflow
nextflow.enable.dsl = 2

// --- Log initial pipeline parameters ---
log.info """
    ====================================================
    AoU VCF Region QC Pipeline (Nextflow + dsub)
    ====================================================
    Input VCF (GCS)    : ${params.input_vcf_gcs}
    Input TBI (GCS)    : ${params.input_tbi_gcs}
    Target Region      : ${params.region}
    Local Output Base  : ${params.output_dir_local}
    Container Image    : ${workflow.containerEngine == 'docker' ? workflow.container : 'N/A'}
    ----------------------------------------------------
    """

// --- Module Imports ---
// Modules are expected to be in a 'modules' subdirectory.
// 'modulesDir' in nextflow.config points to './modules'.
include { STAGE_VCF         } from './modules/stage_vcf'
include { EXTRACT_REGION    } from './modules/extract_region'
include { CALCULATE_STATS   } from './modules/calculate_stats'

// --- Workflow Definition ---
// Unnamed workflow, will run by default
workflow {

    // Validate that essential GCS input paths (now defaulted in config) are indeed present
    // This is a sanity check; they should always be defined by nextflow.config
    if (!params.input_vcf_gcs) {
        error "Pipeline Error: input_vcf_gcs parameter is missing or null in configuration."
    }
    if (!params.input_tbi_gcs) {
        error "Pipeline Error: input_tbi_gcs parameter is missing or null in configuration."
    }

    main:
        // Stage 1: Create a channel that emits the GCS paths for STAGE_VCF
        ch_gcs_input_paths = Channel.of( [ params.input_vcf_gcs, params.input_tbi_gcs ] )

        // Call STAGE_VCF to download VCF and TBI from GCS
        STAGE_VCF ( ch_gcs_input_paths )

        // Stage 2: Extract the specified genomic region
        ch_target_region = Channel.of( params.region )
        EXTRACT_REGION ( STAGE_VCF.out.staged_files, ch_target_region )

        // Stage 3: Calculate variant statistics and generate plots
        CALCULATE_STATS ( EXTRACT_REGION.out.extracted_files )

    emit:
        // Make final outputs available as workflow results
        final_stats_file  = CALCULATE_STATS.out.stats_file
        final_plots_dir   = CALCULATE_STATS.out.plots_directory
}

// --- Workflow Completion & Error Handling ---
workflow.onComplete {
    def final_summary_message = """
    ====================================================
    Pipeline Execution Summary
    ====================================================
    Status         : ${workflow.success ? 'COMPLETED SUCCESSFULLY' : 'FAILED'}
    Started        : ${workflow.start}
    Completed at   : ${workflow.complete}
    Duration       : ${workflow.duration}
    Work Dir       : ${workflow.workDir}
    Launch Dir     : ${workflow.launchDir}
    Output (Local) : ${params.output_dir_local}
    Container Used : ${workflow.container}
    ----------------------------------------------------
    """
    if (workflow.success) {
        log.info final_summary_message + "Results published by Nextflow to local path '${params.output_dir_local}'.\ndsub is configured to copy this directory to GCS."
    } else {
        log.error final_summary_message + "Errors occurred during pipeline execution. See Nextflow and dsub logs."
        log.error "Failed task details: ${workflow.errorReport ?: 'Not available'}"
        log.error "Exit status: ${workflow.exitStatus}"
    }
}
