# Data ISO estrita (AAAA-MM-DD) dos corpos JSON do laboratório (D10): nil
# quando não é string nesse formato ou não é data válida.
module Lab
  module IsoDate
    module_function

    def parse(raw)
      raw.is_a?(String) && raw.match?(/\A\d{4}-\d{2}-\d{2}\z/) ? Date.iso8601(raw) : nil
    rescue Date::Error
      nil
    end
  end
end
