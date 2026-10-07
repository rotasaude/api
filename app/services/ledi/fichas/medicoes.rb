# Sinais da revisão → MedicoesThrift (Task 1: nomes e tipos do IDL). Dor e
# IMC não têm campo no LEDI. Sem medida, nil (o campo é opcional).
module Ledi
  module Fichas
    module Medicoes
      INTEGER = %w[systolic diastolic heart_rate respiratory_rate spo2 capillary_glucose].freeze
      DOUBLE = %w[temperature_c weight_kg height_cm].freeze

      module_function

      def build(revision)
        Ledi::Version.load!
        attrs = {}
        INTEGER.each { |column| attrs[field(column)] = revision[column].to_i unless revision[column].nil? }
        DOUBLE.each { |column| attrs[field(column)] = revision[column].to_f unless revision[column].nil? }
        if revision.glucose_moment
          attrs[field("glucose_moment")] = Ledi::ScreeningMapping.glucose_code(revision.glucose_moment)
        end
        attrs.empty? ? nil : Br::Gov::Saude::Esusab::Ras::Common::MedicoesThrift.new(**attrs)
      end

      def field(column) = Ledi::ScreeningMapping.measurement_field(column).to_sym
    end
  end
end
