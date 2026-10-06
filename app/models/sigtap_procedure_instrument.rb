# app/models/sigtap_procedure_instrument.rb
class SigtapProcedureInstrument < PlatformRecord
  belongs_to :release, class_name: "TerminologyRelease"
end
