/*
 * Nextflow Module: EXTRACT_REGION
 * Extracts a specified genomic region from a VCF file using bcftools.
 */

nextflow.enable.dsl = 2

process EXTRACT_REGION {
    tag "Extract Region: ${local_vcf_file.baseName} | ${target_region_str}"
    label 'medium_resources'

    input:
    tuple path(local_vcf_file), path(local_tbi_file) // Local staged VCF and TBI files
    val target_region_str                            // Genomic region string

    output:
    tuple path("*.extracted.vcf.gz"), path("*.extracted.vcf.gz.tbi"), emit: extracted_region_files
    val target_region_str, emit: region_processed    // Pass region along for reference

    script:
    def output_filename_base = local_vcf_file.baseName.replaceAll(~/\.vcf\.gz$/, '') // Remove .vcf.gz for base
    def extracted_vcf_output = "${output_filename_base}.extracted.vcf.gz"
    """
    echo "[PROCESS EXTRACT_REGION] Input VCF: ${local_vcf_file}"
    echo "[PROCESS EXTRACT_REGION] Input TBI: ${local_tbi_file}"
    echo "[PROCESS EXTRACT_REGION] Region to extract: ${target_region_str}"
    echo "[PROCESS EXTRACT_REGION] Output extracted VCF: ${extracted_vcf_output}"

    # bcftools view requires the input VCF to be indexed for region extraction.
    # The STAGE_VCF process provides both VCF and TBI.
    bcftools view \\
        --regions "${target_region_str}" \\
        --output-type z \\
        --output-file "${extracted_vcf_output}" \\
        "${local_vcf_file}"

    echo "[PROCESS EXTRACT_REGION] Indexing the extracted VCF..."
    tabix -p vcf "${extracted_vcf_output}"

    echo "[PROCESS EXTRACT_REGION] Verification of extracted files:"
    ls -l "${extracted_vcf_output}"*
    """
}
