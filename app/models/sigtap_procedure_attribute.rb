# app/models/sigtap_procedure_attribute.rb
# Atributo complementar do procedimento na SIGTAP (CO_DETALHE, 3 dígitos;
# módulo 31). Escrito só por Terminology::SigtapReader; imutável por trigger.
class SigtapProcedureAttribute < PlatformRecord
  belongs_to :release, class_name: "TerminologyRelease"
end
