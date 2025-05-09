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
// 'modulesDir' is set in nextflow.config to './modules'
include { STAGE_VCF         } from './modules/stage_vcf'
include { EXTRACT_REGION    } from './modules/extract_region'
include { CALCULATE_STATS   } from './modules/calculate_stats'

// --- Workflow Definition ---
workflow VCF_QC_PIPELINE {

    main:
        // Stage 1: Create a channel that emits the GCS paths for STAGE_VCF
        // This process expects a single emission: a tuple of [vcf_path_str, tbi_path_str]
        ch_gcs_input_paths = Channel.of( [ params.input_vcf_gcs, params.input_tbi_gcs ] )

        // Call STAGE_VCF to download VCF and TBI from GCS
        STAGE_VCF ( ch_gcs_input_paths )

        // Stage 2: Extract the specified genomic region
        // Create a channel for the region string parameter
        ch_target_region = Channel.of( params.region )

        // Call EXTRACT_REGION using the staged files and the target region
        EXTRACT_REGION ( STAGE_VCF.out.staged_files, ch_target_region )

        // Stage 3: Calculate variant statistics and generate plots
        // Call CALCULATE_STATS using the region-extracted VCF files
        CALCULATE_STATS ( EXTRACT_REGION.out.extracted_region_files )

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
    Work Directory : ${workflow.workDir}
    Launch Directory: ${workflow.launchDir}
    Final Results (local relative to Nextflow launch): ${params.output_dir_local}
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
