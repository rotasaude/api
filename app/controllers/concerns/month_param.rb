# Mês na query (painéis e rotas mensais): "YYYY-MM" (texto) -> Date (dia 1º)
# | nil. Compartilhado pelo CAPS (ADR 0049) e pela urgência (ADR 0050).
module MonthParam
  MONTH = /\A(\d{4})-(0[1-9]|1[0-2])\z/

  private

  def month_from(value)
    match = value.is_a?(String) ? value.match(MONTH) : nil
    match && Date.new(match[1].to_i, match[2].to_i, 1)
  end
end
