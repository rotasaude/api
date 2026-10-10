# Data ISO estrita (AAAA-MM-DD) das entradas dos documentos clínicos; nil se
# não for texto nesse formato ou não existir no calendário.
module ClinicalDocuments
  module IsoDate
    FORMAT = /\A\d{4}-\d{2}-\d{2}\z/

    module_function

    def parse(value)
      value.is_a?(String) && value.match?(FORMAT) ? Date.iso8601(value) : nil
    rescue Date::Error
      nil
    end
  end
end
