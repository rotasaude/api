# app/models/sigtap_procedure.rb
class SigtapProcedure < PlatformRecord
  belongs_to :release, class_name: "TerminologyRelease"
end
