# Códigos SIGTAP das ajudas de custo do TFD (config/tfd/sigtap_codes.yml).
module Tfd
  module SigtapCodes
    PATH = Rails.root.join("config/tfd/sigtap_codes.yml")

    module_function

    # { "meal_overnight" => { "patient" => "0803010010", "companion" => "…" }, … }
    def table = (@table ||= YAML.safe_load_file(PATH).fetch("codes").transform_values(&:freeze).freeze)

    # Todos os códigos (10).
    def all = table.values.flat_map(&:values)

    # kind: de Tfd::Catalog::ALLOWANCE_KINDS; person: "patient" | "companion".
    def code(kind:, person:) = table.fetch(kind.to_s).fetch(person.to_s)

    # [ { code:, kind:, person: } ] na ordem do arquivo.
    def entries
      table.flat_map { |kind, by_person| by_person.map { |person, code| { code: code, kind: kind, person: person } } }
    end
  end
end
