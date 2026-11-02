# Rotas do razão do 27a que também carregam imunobiológico (ADR 0047, Desvio 5):
# entradas, transferências, ajustes, posição e extrato. A rota passa se
# `pharmacy` OU `vaccination` está utilizável (nenhum: 403 com `pharmacy`, o
# interruptor da família de rotas); cada ação, ao carregar o local, confere o
# interruptor do domínio dele (Stock::Domain.feature_for).
module StockGate
  private

  def require_stock_feature!
    return if Pharmacy::Gate.usable?(Current.city) || Vaccination::Gate.usable?(Current.city)

    render json: { error: "feature_disabled", feature: Pharmacy::Gate::KEY }, status: :forbidden
  end

  # true quando o interruptor do domínio do local está utilizável; senão
  # responde 403 feature_disabled com a `feature` do local e devolve false.
  def stock_feature_for!(location)
    return true if stock_domain_usable?(Stock::Domain.for(location))

    render json: { error: "feature_disabled", feature: Stock::Domain.feature_for(location) }, status: :forbidden
    false
  end

  # Memoizado por requisição (o interruptor é lido fora da transação da cidade).
  def stock_domain_usable?(domain)
    @stock_domain_usable ||= {}
    return @stock_domain_usable[domain] if @stock_domain_usable.key?(domain)

    @stock_domain_usable[domain] = Stock::Domain.usable?(Current.city, domain)
  end
end
