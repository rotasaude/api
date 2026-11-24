# Parâmetros técnicos do centro de zoonoses (módulo 35b; contrato §9; molde do
# VectorControl::Parameters). A coordenação grava por versão
# (zoonoses_parameter_versions, só acréscimo); a vigente é a maior. Sem linha
# (banco carregado do dump, cidade antes da primeira edição): versão 0 com o
# padrão de fábrica de config/zoonoses/defaults.yml e created_at nil. A linha
# gravada antes de uma chave existir é completada pelo defaults.yml.
#
# RANGES é a tabela do §9 sem `leish_expected_prevalence` (Q18), na ordem do
# defaults.yml (o parameters_spec confere que as chaves são as mesmas).
# `validate` confere um PUT inteiro: as chaves exatas, o tipo e a faixa de cada
# uma; só o primeiro erro, com o `path` a chave. A tabela da amostra
# (`leish_sample_table`): lista não vazia de `{ population, sample }` inteiros,
# populações estritamente crescentes, `sample <= population`; a primeira linha
# pode levar `min_population` (inteiro > 0 e <= a população dela, Q32) e
# qualquer linha, `a_conferir` (booleano).
module Zoonoses
  module Parameters
    DEFAULTS_PATH = Rails.root.join("config/zoonoses/defaults.yml")

    Snapshot = Data.define(:version, :values, :created_at) do
      def initialize(version:, values:, created_at: nil) = super
    end

    FRACTION = (BigDecimal("0.1")..BigDecimal("1"))
    # Faixa de cada chave: Range de inteiros, FRACTION,
    # :table (leish_sample_table) ou :estimate (inteiro >= 0 ou null).
    RANGES = {
      "observation_days" => (10..30),
      "collar_months" => (1..12),
      "leish_sample_table" => :table,
      "leish_focus_min_dogs" => (10..1000),
      "dogs_per_block" => (1..100),
      "rabies_coverage_target" => FRACTION,
      "dog_population_estimate" => :estimate,
      "cat_population_estimate" => :estimate
    }.freeze
    ROW_KEYS = %w[population sample min_population a_conferir].freeze

    module_function

    def current
      snapshot(ZoonosesParameterVersion.order(version: :desc).first)
    end

    # A versão gravada (o inquérito lê a da sua criação); 0, nil ou sem linha
    # → o padrão de fábrica.
    def at(version)
      snapshot(version.to_i.positive? && ZoonosesParameterVersion.find_by(version: version))
    end

    def defaults = YAML.load_file(DEFAULTS_PATH)

    # nil | { path: } (a chave; nil quando `values` não é objeto).
    def validate(values)
      return { path: nil } unless values.is_a?(Hash)

      odd = (values.keys - RANGES.keys).first || (RANGES.keys - values.keys).first
      return { path: odd } if odd

      bad = RANGES.find { |key, range| !fits?(values[key], range) }
      bad && { path: bad.first }
    end

    # Os valores validados, na ordem de RANGES: a fração como Float (o JSON 1
    # vira 1.0, como o defaults.yml) e a tabela com chaves de texto.
    def normalize(values)
      RANGES.to_h do |key, range|
        value = values.fetch(key)
        value = BigDecimal(value.to_s).to_f if range.equal?(FRACTION)
        value = value.map { |row| row.to_h.stringify_keys.slice(*ROW_KEYS) } if range == :table
        [ key, value ]
      end
    end

    def fits?(value, range)
      # Comparação por igualdade, não `case` (Range#=== conferiria a faixa).
      if range == :table then table?(value)
      elsif range == :estimate then value.nil? || (value.is_a?(Integer) && value >= 0)
      elsif range.equal?(FRACTION) then fraction?(value)
      else value.is_a?(Integer) && range.cover?(value)
      end
    end

    def fraction?(value)
      return false unless (value.is_a?(Integer) || value.is_a?(Float)) && value.to_f.finite?

      decimal = BigDecimal(value.to_s)
      FRACTION.cover?(decimal)
    end

    def table?(rows)
      return false unless rows.is_a?(Array) && rows.any? && rows.all?(Hash)

      rows.each_with_index.all? { |row, index| row?(row, first: index.zero?) } &&
        rows.map { |row| row["population"] }.each_cons(2).all? { |low, high| low < high }
    end

    def row?(row, first:)
      return false unless row.keys.all?(String) && (row.keys - ROW_KEYS).empty?

      population = row["population"]
      return false unless positive_integer?(population) && positive_integer?(row["sample"]) && row["sample"] <= population
      return false if row.key?("a_conferir") && ![ true, false ].include?(row["a_conferir"])
      return true unless row.key?("min_population")

      minimum = row["min_population"]
      first && positive_integer?(minimum) && minimum <= population
    end

    def positive_integer?(value) = value.is_a?(Integer) && value.positive?

    def snapshot(row)
      return Snapshot.new(version: 0, values: defaults) unless row

      Snapshot.new(version: row.version, values: defaults.merge(row.values), created_at: row.created_at)
    end
    private_class_method :fits?, :fraction?, :table?, :row?, :positive_integer?, :snapshot
  end
end
