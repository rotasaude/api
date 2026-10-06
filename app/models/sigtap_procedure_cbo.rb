# app/models/sigtap_procedure_cbo.rb
class SigtapProcedureCbo < PlatformRecord
  belongs_to :release, class_name: "TerminologyRelease"
end
