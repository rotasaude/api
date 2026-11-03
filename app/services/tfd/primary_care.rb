# Procedimentos da atenção básica (config/tfd/primary_care_groups.yml): o TFD
# não os cobre (plano, Desvio 11: `primary_care_procedure`).
module Tfd
  module PrimaryCare
    PATH = Rails.root.join("config/tfd/primary_care_groups.yml")

    module_function

    def covers?(sigtap_code)
      return false unless sigtap_code.is_a?(String)

      table.fetch("codes").include?(sigtap_code) || table.fetch("prefixes").any? { |prefix| sigtap_code.start_with?(prefix) }
    end

    def table = (@table ||= YAML.safe_load_file(PATH).slice("prefixes", "codes").transform_values { |list| list.map(&:to_s).freeze }.freeze)
  end
end
