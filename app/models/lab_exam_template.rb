# Exame do catálogo-base da plataforma (ADR 0037; Divergências M1, M3, M7).
class LabExamTemplate < PlatformRecord
  SECTORS = %w[biochemistry hematology immunology urinalysis parasitology microbiology].freeze

  has_many :analytes, -> { order(:position, :key) }, class_name: "LabAnalyteTemplate", inverse_of: :lab_exam_template,
                                                      dependent: :restrict_with_error
end
