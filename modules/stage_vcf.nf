/*
 * Nextflow Module: STAGE_VCF
 * Stages VCF and TBI files from GCS to the local process working directory.
 */

nextflow.enable.dsl = 2

process STAGE_VCF {
    tag "Stage VCF: ${vcf_gcs_path.tokenize('/')[-1]}"
    label 'low_resources' // Resource consumption is primarily network I/O

    input:
    val vcf_gcs_path // Full GCS path to the VCF.gz file
    val tbi_gcs_path // Full GCS path to the VCF.gz.tbi file

    output:
    tuple path("*.vcf.gz"), path("*.vcf.gz.tbi"), emit: staged_files

    script:
    def vcf_local_filename = vcf_gcs_path.tokenize('/')[-1]
    def tbi_local_filename = tbi_gcs_path.tokenize('/')[-1]
    """
    echo "[PROCESS STAGE_VCF] Target VCF (GCS): ${vcf_gcs_path}"
    echo "[PROCESS STAGE_VCF] Target TBI (GCS): ${tbi_gcs_path}"

    echo "[PROCESS STAGE_VCF] Copying VCF to local working directory..."
    gsutil -m cp "${vcf_gcs_path}" "./${vcf_local_filename}"
    echo "[PROCESS STAGE_VCF] VCF copy complete: ./${vcf_local_filename}"

    echo "[PROCESS STAGE_VCF] Copying TBI to local working directory..."
    gsutil -m cp "${tbi_gcs_path}" "./${tbi_local_filename}"
    echo "[PROCESS STAGE_VCF] TBI copy complete: ./${tbi_local_filename}"

    echo "[PROCESS STAGE_VCF] Verifying staged files:"
    ls -l ./${vcf_local_filename} ./${tbi_local_filename}
    """
}
