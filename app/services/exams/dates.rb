# Data de liberação do laudo (contrato §3): AAAA-MM-DD estrito, ou um Date.
# Compartilhada pelo resultado do pedido e pelo resultado externo.
module Exams
  module Dates
    module_function

    def parse(raw)
      raw.is_a?(Date) ? raw : (raw.is_a?(String) && raw.match?(/\A\d{4}-\d{2}-\d{2}\z/) ? Date.iso8601(raw) : nil)
    rescue Date::Error
      nil
    end
  end
end
