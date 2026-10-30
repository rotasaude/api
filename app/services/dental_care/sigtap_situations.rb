# Efeito de cada SIGTAP no odontograma (ADR 0046; Desvio 5): a tabela de
# config/dental/sigtap_situations.yml (carregada uma vez por processo).
# `effects(code, location)` devolve os eventos que o procedimento gera —
# `{ tooth:, part:, face:, situation: }`, com part crown ou root —: o efeito
# de arcada vira um evento de coroa por dente da arcada; situação que não vale
# no dente (decíduo, Situations) fica de fora; local fora dos do efeito ou
# código fora da tabela → []. O efeito com `only_on` (PPR, prótese
# temporária) só cai nos dentes cuja coroa está numa dessas situações e exige
# o odontograma (`chart:`, o de DentalCare::Chart).
module DentalCare
  module SigtapSituations
    PATH = Rails.root.join("config/dental/sigtap_situations.yml")

    module_function

    def data = (@data ||= YAML.load_file(PATH).fetch("procedures").freeze)

    def codes = data.keys

    # O local do efeito ([] fora da tabela).
    def locations(code) = data.dig(code.to_s, "locations") || []

    def effects(code, location, chart: nil)
      row = data[code.to_s]
      return [] unless row && row.fetch("locations").include?(location.fetch(:kind))

      row.fetch("effects").flat_map { |effect| expand(effect, location, chart) }
    end

    def expand(effect, location, chart)
      vocabulary = effect.fetch("part")
      situation = effect.fetch("situation")
      face = effect["on_face"] && location[:kind] == "face" ? location.fetch(:face) : nil
      teeth = Location.teeth(location).select { |tooth| Situations.valid?(situation, part: vocabulary, tooth: tooth, face: face) }
      teeth = teeth.select { |tooth| effect["only_on"].include?(crown_of(chart, tooth)) } if effect["only_on"]
      part = vocabulary == "arch" ? "crown" : vocabulary
      teeth.map { |tooth| { tooth: tooth, part: part, face: face, situation: situation } }
    end

    def crown_of(chart, tooth)
      raise ArgumentError, "SigtapSituations.effects: this procedure needs chart:" unless chart

      chart.fetch(:teeth).find { |t| t[:tooth] == tooth }&.fetch(:situation)
    end
    private_class_method :expand, :crown_of
  end
end
