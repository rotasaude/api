# app/services/screenings/cbos.rb
# Quem pode fazer a escuta (ADR 0030; spec §3.2; Desvio 2): CBO dos grupos de
# config/scheduling/screening_cbos.yml E com ficha LEDI possível (tabela do
# MIAI ou técnico/auxiliar de enfermagem no MIP).
module Screenings
  module Cbos
    PATH = Rails.root.join("config/scheduling/screening_cbos.yml")

    module_function

    def prefixes = (@prefixes ||= YAML.load_file(PATH).map { |row| row.fetch("prefix").to_s }.freeze)

    def allowed?(cbo)
      cbo = cbo.to_s
      prefixes.any? { |prefix| cbo.start_with?(prefix) } && Ledi::ScreeningMapping.exportable_cbo?(cbo)
    end
  end
end
