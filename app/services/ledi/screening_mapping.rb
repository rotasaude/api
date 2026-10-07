# app/services/ledi/screening_mapping.rb
# Mapeamento da escuta inicial para o LEDI (ADR 0030; spec §5, Tarefa 1). O
# YAML guarda valor e fonte de cada linha; quem monta ficha lê daqui, nunca de
# literal solto. Carregado uma vez por processo.
module Ledi
  module ScreeningMapping
    PATH = Rails.root.join("config/ledi/screening_mapping.yml")

    class Missing < StandardError; end

    module_function

    def data = (@data ||= YAML.load_file(PATH).freeze)

    def entry(key) = data.fetch("entries").fetch(key.to_s) { raise Missing, key.to_s }

    def value(key) = entry(key).fetch("value")

    def miai_cbos = data.fetch("miai_cbos").fetch("codes")

    def miai_cbo?(cbo) = miai_cbos.include?(cbo.to_s)

    def procedures_cbo?(cbo)
      data.fetch("procedures_cbo_prefixes").fetch("prefixes").any? { |prefix| cbo.to_s.start_with?(prefix) }
    end

    def exportable_cbo?(cbo) = miai_cbo?(cbo) || procedures_cbo?(cbo)

    def conduta(destination) = value("initial_listening.conduta.#{destination}")
    def sex_code(sex) = value("sex.#{sex}")
    def glucose_code(moment) = value("glucose_moment.#{moment}")
    def measurement_field(column) = value("measurement.#{column}")
    def procedure(kind) = value("procedure.#{kind}")

    # Turno no fuso da cidade (Time.zone dentro de CityConnection.with).
    def turno(time)
      hour = time.in_time_zone.hour
      value(if hour < 12 then "turno.morning" elsif hour < 18 then "turno.afternoon" else "turno.night" end)
    end
  end
end
