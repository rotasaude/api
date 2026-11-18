# Parâmetros técnicos do controle vetorial (módulo 35a; contrato §11). A
# coordenação grava por versão (vector_parameter_versions, só acréscimo;
# VectorControl::SaveParameters); a vigente é a maior. Sem linha (banco
# carregado do dump, cidade antes da primeira edição): versão 0 com o padrão de
# fábrica de config/vector_control/defaults.yml e created_at nil (A-4, Q13(8)).
#
# RANGES é a tabela do A-5 (mais a Q17: liraa_half_household_fraction como a
# liraa_household_fraction), na ordem do defaults.yml; o parameters_spec
# confere que as chaves são as mesmas. `validate` confere um PUT inteiro: as
# chaves exatas, os tipos (inteiro onde é inteiro; número com até duas casas
# nas frações), a faixa de cada chave e só depois as desigualdades entre
# chaves (o path é a chave de baixo). Só o primeiro erro. Em block_diseases,
# só o código novo em relação à versão vigente precisa estar na lista de
# doenças (Surveillance::Diseases). `current`/`at` sempre trazem as 20 chaves:
# a linha gravada antes de uma chave existir é completada pelo defaults.yml.
module VectorControl
  module Parameters
    DEFAULTS_PATH = Rails.root.join("config/vector_control/defaults.yml")

    Snapshot = Data.define(:version, :values, :created_at) do
      def initialize(version:, values:, created_at: nil) = super
    end

    FRACTION = (BigDecimal("0.01")..BigDecimal("1"))
    LIRAA_SIZE = (1..100_000)
    # Faixa de cada chave: Range de inteiros, FRACTION (até duas casas),
    # :diseases (lista não vazia de códigos de Surveillance::Diseases, sem
    # repetição) ou :bands (dois números crescentes entre 0 e 100).
    RANGES = {
      "default_days" => (7..365),
      "strategic_point_days" => (7..365),
      "block_radius_rings" => (0..5),
      "block_grouping_days" => (1..30),
      "block_diseases" => :diseases,
      "ubv_cycles_max" => (1..5),
      "ubv_cycle_days_min" => (1..15),
      "ubv_cycle_days_max" => (1..15),
      "ubv_cycle_interval_days" => (0..30),
      "ovitrap_collection_days_min" => (1..30),
      "ovitrap_collection_days_max" => (1..30),
      "ovitrap_alert_eggs" => (1..9999),
      "ovitrap_radius_rings" => (0..5),
      "liraa_standard_min" => LIRAA_SIZE,
      "liraa_standard_max" => LIRAA_SIZE,
      "liraa_half_min" => LIRAA_SIZE,
      "liraa_base_sample" => (1..10_000),
      "liraa_household_fraction" => FRACTION,
      "liraa_half_household_fraction" => FRACTION,
      "iip_bands" => :bands
    }.freeze
    # [de baixo, de cima]: NOT_ABOVE pede ≤; BELOW pede <.
    NOT_ABOVE = [ %w[ubv_cycle_days_min ubv_cycle_days_max], %w[ovitrap_collection_days_min ovitrap_collection_days_max] ].freeze
    BELOW = [ %w[liraa_half_min liraa_standard_min], %w[liraa_standard_min liraa_standard_max] ].freeze
    BANDS = (0..100)

    module_function

    def current
      snapshot(VectorParameterVersion.order(version: :desc).first)
    end

    # A versão gravada (o LIRAa lê a do sorteio); 0, nil ou sem linha → o padrão de fábrica.
    def at(version)
      snapshot(version.to_i.positive? && VectorParameterVersion.find_by(version: version))
    end

    def defaults = YAML.load_file(DEFAULTS_PATH)

    # nil | { path: } (a chave; nil quando `values` não é objeto).
    def validate(values)
      return { path: nil } unless values.is_a?(Hash)

      odd = (values.keys - RANGES.keys).first || (RANGES.keys - values.keys).first
      return { path: odd } if odd

      bad = RANGES.find { |key, range| !fits?(values[key], range) }
      return { path: bad.first } if bad

      bad = NOT_ABOVE.find { |low, high| values[low] > values[high] } || BELOW.find { |low, high| values[low] >= values[high] }
      bad && { path: bad.first }
    end

    # Os valores validados, na ordem de RANGES, com as frações e as faixas do
    # IIP como Float (o JSON 1 vira 1.0, como o defaults.yml).
    def normalize(values)
      RANGES.to_h do |key, range|
        value = values.fetch(key)
        value = BigDecimal(value.to_s).to_f if range == FRACTION
        value = value.map(&:to_f) if range == :bands
        [ key, value ]
      end
    end

    def fits?(value, range)
      # Comparação por igualdade, não `case` (Range#=== conferiria a faixa).
      if range == :diseases then diseases?(value)
      elsif range == :bands then bands?(value)
      elsif range.equal?(FRACTION) then fraction?(value)
      else value.is_a?(Integer) && range.cover?(value)
      end
    end

    def diseases?(value)
      return false unless value.is_a?(Array) && value.any? && value.all?(String) && value.uniq.size == value.size

      # Só os códigos novos em relação à versão vigente passam pela lista de
      # doenças: o PUT reenvia as 20 chaves, e um código já gravado (inclusive
      # o de fábrica, ou um que saiu da lista depois) não trava a edição.
      added = value - Array(current.values["block_diseases"])
      added.empty? || (added - Surveillance::Diseases.all.map(&:code)).empty?
    end

    def bands?(value)
      value.is_a?(Array) && value.size == 2 && value.all? { |band| number?(band) && BANDS.cover?(band) } && value.first < value.last
    end

    def fraction?(value)
      return false unless number?(value)

      decimal = BigDecimal(value.to_s)
      FRACTION.cover?(decimal) && decimal.round(2) == decimal
    end

    def number?(value) = (value.is_a?(Integer) || value.is_a?(Float)) && value.to_f.finite?

    def snapshot(row)
      return Snapshot.new(version: 0, values: defaults) unless row

      # Versão gravada antes de uma chave nova: o padrão de fábrica completa.
      Snapshot.new(version: row.version, values: defaults.merge(row.values), created_at: row.created_at)
    end
    private_class_method :fits?, :diseases?, :bands?, :fraction?, :number?, :snapshot
  end
end
