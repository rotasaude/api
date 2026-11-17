# Rotas do razão do 27a que também carregam imunobiológico (ADR 0047, Desvio 5)
# e insumo de campo (35a, A-12): entradas, transferências, ajustes, posição e
# extrato. A rota passa se `pharmacy`, `vaccination` OU `vector_control` está
# utilizável (nenhum: 403 com `pharmacy`, o interruptor da família de rotas);
# cada ação, ao carregar o local, confere o interruptor do domínio dele
# (Stock::Domain.feature_for).
module StockGate
  private

  def require_stock_feature!
    return if Stock::Domain::FEATURES.keys.any? { |domain| stock_domain_usable?(domain) }

    render json: { error: "feature_disabled", feature: Pharmacy::Gate::KEY }, status: :forbidden
  end

  # true quando o interruptor do domínio do local está utilizável; senão
  # responde 403 feature_disabled com a `feature` do local e devolve false.
  def stock_feature_for!(location)
    return true if stock_domain_usable?(Stock::Domain.for(location))

    render json: { error: "feature_disabled", feature: Stock::Domain.feature_for(location) }, status: :forbidden
    false
  end

  # Módulo 35a (Q21): as telas de locais do 27a (admin, equipe e "meus
  # locais") conferem o interruptor do domínio do LOCAL: o vector_control vale
  # com `vector_control` mesmo sem `pharmacy`. -> tipos de local do 27a (central,
  # unit, vector_control) cujo domínio está utilizável.
  def usable_stock_location_kinds
    Pharmacy::Catalog::STOCK_LOCATION_KINDS.select { |kind| stock_domain_usable?(Stock::Domain.for(StockLocation.new(kind: kind))) }
  end

  # Nenhum tipo utilizável → 403 feature_disabled com `pharmacy` (o interruptor
  # da família de rotas). -> true | false (já respondeu)
  def require_stock_location_kinds!
    return true if usable_stock_location_kinds.any?

    render json: { error: "feature_disabled", feature: Pharmacy::Gate::KEY }, status: :forbidden
    false
  end

  # Memoizado por requisição (o interruptor é lido fora da transação da cidade).
  def stock_domain_usable?(domain)
    @stock_domain_usable ||= {}
    return @stock_domain_usable[domain] if @stock_domain_usable.key?(domain)

    @stock_domain_usable[domain] = Stock::Domain.usable?(Current.city, domain)
  end
end
