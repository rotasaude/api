# app/services/sncr/numbers.rb
# Número SNCR (Manual §2.3.2: "2602.6-53.0000001"): o bloco vem como início e
# fim no mesmo prefixo; o estoque guarda cada número.
module Sncr
  module Numbers
    PATTERN = /\A(\d{4}\.\d-\d{2}\.)(\d{7})\z/
    MAX = 1000

    module_function

    def expand(first, last, quantity)
      head = PATTERN.match(first.to_s)
      tail = PATTERN.match(last.to_s)
      return nil unless head && tail && head[1] == tail[1] && quantity.is_a?(Integer)

      from = head[2].to_i
      to = tail[2].to_i
      size = to - from + 1
      return nil unless size.between?(1, MAX) && size == quantity

      (from..to).map { |sequence| "#{head[1]}#{format('%07d', sequence)}" }
    end
  end
end
