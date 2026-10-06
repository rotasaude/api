# app/models/sigtap_procedure_cid.rb
class SigtapProcedureCid < PlatformRecord
  belongs_to :release, class_name: "TerminologyRelease"
end
